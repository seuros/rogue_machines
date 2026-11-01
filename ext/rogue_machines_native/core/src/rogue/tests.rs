use crate::{Decision, EXPERIMENTS, Experiment, Fault, Fraction, PER_MILLION, Rogue, Slot};

/// Past every reading these tests evaluate at. There is no value meaning
/// "never": `spent` is `now_ns >= expires_at_ns`, so even `u64::MAX` expires
/// at `u64::MAX`, which `an_expiry_at_the_end_of_the_clock_still_expires` pins.
const LONG_AFTER: u64 = 1 << 62;

fn slot(index: usize) -> Slot {
    Slot::new(index).unwrap_or_else(|| unreachable!("{index} is inside the mask"))
}

fn fraction(millionths: u32) -> Fraction {
    Fraction::new(millionths).unwrap_or_else(|| unreachable!("{millionths} is a whole at most"))
}

#[test]
fn a_fresh_rogue_injects_nothing_whatever_the_draw() {
    let rogue = Rogue::new();

    assert!(!rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Pass);
    assert_eq!(
        rogue.decide(slot(31), LONG_AFTER, PER_MILLION - 1),
        Decision::Pass
    );
}

#[test]
fn an_expired_experiment_disarms_itself_and_a_backwards_clock_cannot_revive_it() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(0), Experiment::new(Fault::Raise, Fraction::ALL, 100));

    assert_eq!(rogue.decide(slot(0), 99, 0), Decision::Inject(Fault::Raise));
    assert_eq!(rogue.decide(slot(0), 100, 0), Decision::Pass);
    assert!(!rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Pass);
}

#[test]
fn a_draw_outside_the_share_makes_the_real_call() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Garble, fraction(PER_MILLION / 10), LONG_AFTER),
    );

    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Inject(Fault::Garble));
    assert_eq!(
        rogue.decide(slot(0), 0, 99_999),
        Decision::Inject(Fault::Garble)
    );
    assert_eq!(rogue.decide(slot(0), 0, 100_000), Decision::Pass);
}

#[test]
fn a_share_of_none_is_armed_and_still_reaches_nothing() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Raise, Fraction::NONE, LONG_AFTER),
    );

    assert!(rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Pass);
}

#[test]
fn arming_a_slot_again_replaces_what_it_held() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Raise, Fraction::ALL, LONG_AFTER),
    );
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Delay { ns: 5 }, Fraction::ALL, LONG_AFTER),
    );

    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(
        rogue.decide(slot(0), 0, 0),
        Decision::Inject(Fault::Delay { ns: 5 })
    );
}

#[test]
fn one_slots_fault_does_not_reach_another() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Raise, Fraction::ALL, LONG_AFTER),
    );
    rogue.arm(
        slot(EXPERIMENTS - 1),
        Experiment::new(Fault::Garble, Fraction::ALL, LONG_AFTER),
    );

    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Inject(Fault::Raise));
    assert_eq!(rogue.decide(slot(16), 0, 0), Decision::Pass);
    assert_eq!(
        rogue.decide(slot(EXPERIMENTS - 1), 0, 0),
        Decision::Inject(Fault::Garble)
    );
}

#[test]
fn disarming_one_slot_leaves_the_others_running() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Raise, Fraction::ALL, LONG_AFTER),
    );
    rogue.arm(
        slot(1),
        Experiment::new(Fault::Garble, Fraction::ALL, LONG_AFTER),
    );

    rogue.disarm(slot(0));

    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Pass);
    assert_eq!(rogue.decide(slot(1), 0, 0), Decision::Inject(Fault::Garble));
    assert_eq!(rogue.armed_count(), 1);
}

#[test]
fn disarming_everything_clears_every_slot() {
    let mut rogue = Rogue::new();
    for index in 0..EXPERIMENTS {
        rogue.arm(
            slot(index),
            Experiment::new(Fault::Raise, Fraction::ALL, LONG_AFTER),
        );
    }
    assert_eq!(rogue.armed_count(), u32::BITS);

    rogue.disarm_all();

    assert!(!rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), 0, 0), Decision::Pass);
}

#[test]
fn an_expiry_at_the_end_of_the_clock_still_expires() {
    let mut rogue = Rogue::new();
    rogue.arm(
        slot(0),
        Experiment::new(Fault::Raise, Fraction::ALL, u64::MAX),
    );

    assert_eq!(
        rogue.decide(slot(0), u64::MAX - 1, 0),
        Decision::Inject(Fault::Raise)
    );
    assert_eq!(rogue.decide(slot(0), u64::MAX, 0), Decision::Pass);
}

#[test]
fn an_experiment_expiring_on_an_untouched_slot_still_releases_the_fast_path() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(7), Experiment::new(Fault::Raise, Fraction::ALL, 100));

    // Nothing ever decides on slot 7 again, so only a sweep can clear it.
    assert_eq!(rogue.decide(slot(0), 100, 0), Decision::Pass);
    assert!(!rogue.any_armed());
    assert_eq!(rogue.armed_count(), 0);
}

#[test]
fn a_sweep_leaves_an_experiment_that_has_not_expired_alone() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(7), Experiment::new(Fault::Raise, Fraction::ALL, 100));

    rogue.sweep(99);

    assert!(rogue.any_armed());
    assert_eq!(rogue.decide(slot(7), 99, 0), Decision::Inject(Fault::Raise));
}

#[test]
fn a_slot_can_be_armed_again_after_it_expired() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(0), Experiment::new(Fault::Raise, Fraction::ALL, 100));
    assert_eq!(rogue.decide(slot(0), 100, 0), Decision::Pass);

    rogue.arm(slot(0), Experiment::new(Fault::Garble, Fraction::ALL, 200));

    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(
        rogue.decide(slot(0), 150, 0),
        Decision::Inject(Fault::Garble)
    );
}

#[test]
fn a_rogue_can_be_shared_across_threads() {
    const fn assert_shareable<T: Send + Sync>() {}
    assert_shareable::<Rogue>();
}

#[cfg(feature = "std")]
#[test]
fn concurrent_decisions_agree_on_one_armed_experiment() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(0), Experiment::new(Fault::Raise, Fraction::ALL, 100));
    let rogue = &rogue;

    std::thread::scope(|scope| {
        let readers: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| {
                    (0..1_000)
                        .filter(|_| rogue.decide(slot(0), 50, 0) == Decision::Inject(Fault::Raise))
                        .count()
                })
            })
            .collect();
        for reader in readers {
            assert_eq!(reader.join().map_err(|_| "a reader panicked"), Ok(1_000));
        }
    });
}

#[cfg(feature = "std")]
#[test]
fn a_concurrent_expiry_disarms_exactly_once_and_never_injects_after() {
    let mut rogue = Rogue::new();
    rogue.arm(slot(0), Experiment::new(Fault::Raise, Fraction::ALL, 100));
    let rogue = &rogue;

    std::thread::scope(|scope| {
        let readers: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| (0..1_000).all(|_| rogue.decide(slot(0), 100, 0) == Decision::Pass))
            })
            .collect();
        for reader in readers {
            assert_eq!(reader.join().map_err(|_| "a reader panicked"), Ok(true));
        }
    });

    assert!(!rogue.any_armed());
}
