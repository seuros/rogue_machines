use core::time::Duration;

use crate::test_support::{at, draw, fraction, raising, slot};
use crate::{
    Arming, Decision, Disarming, EXPERIMENTS, Experiment, Fault, Fraction, PER_MILLION, Rogue,
};

mod model;

/// Past every instant these tests evaluate at.
const LONG_AFTER: Duration = Duration::from_secs(1 << 40);

#[test]
fn a_fresh_rogue_injects_nothing_whatever_the_draw() {
    let rogue = Rogue::new();

    assert!(!rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), at(0), draw(0)), Decision::Pass);
    assert_eq!(
        rogue.decide(slot(31), LONG_AFTER, draw(PER_MILLION - 1)),
        Decision::Pass
    );
    assert_eq!(rogue.vacant(), Some(slot(0)));
}

#[test]
fn arming_says_what_the_slot_held_before_expired_or_not() {
    let mut rogue = Rogue::new();
    let first = raising(at(100));
    let second = Experiment::new(Fault::Delay(at(5)), Fraction::ALL, LONG_AFTER);

    assert_eq!(rogue.arm(slot(0), first), Arming::Armed);
    // Arming takes no instant, so `first` may well have expired by now.
    assert_eq!(rogue.arm(slot(0), second), Arming::Replaced(first));
    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(
        rogue.decide(slot(0), at(150), draw(0)),
        Decision::Inject(Fault::Delay(at(5)))
    );
}

#[test]
fn arming_the_identical_experiment_again_is_an_honoured_repeat_that_changes_nothing() {
    let mut rogue = Rogue::new();
    assert_eq!(rogue.arm(slot(3), raising(at(100))), Arming::Armed);
    let before = rogue.clone();

    assert_eq!(rogue.arm(slot(3), raising(at(100))), Arming::AlreadyArmed);
    assert_eq!(rogue, before);
}

#[test]
fn an_experiment_already_spent_is_armed_and_injects_nothing() {
    let mut rogue = Rogue::new();

    // Arming takes no instant, so it has nothing to judge expiry against.
    assert_eq!(rogue.arm(slot(0), raising(at(10))), Arming::Armed);

    assert_eq!(rogue.decide(slot(0), at(10), draw(0)), Decision::Pass);
    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(rogue.sweep(at(10)), 1);
    assert_eq!(rogue, Rogue::new());
}

#[test]
fn a_draw_outside_the_share_makes_the_real_call() {
    let mut rogue = Rogue::new();
    let tenth = Experiment::new(Fault::Garble, fraction(PER_MILLION / 10), LONG_AFTER);
    let none = Experiment::new(Fault::Raise, Fraction::NONE, LONG_AFTER);
    assert_eq!(rogue.arm(slot(0), tenth), Arming::Armed);
    assert_eq!(rogue.arm(slot(1), none), Arming::Armed);

    let garbled = Decision::Inject(Fault::Garble);
    assert_eq!(rogue.decide(slot(0), at(0), draw(0)), garbled);
    assert_eq!(rogue.decide(slot(0), at(0), draw(99_999)), garbled);
    assert_eq!(rogue.decide(slot(0), at(0), draw(100_000)), Decision::Pass);
    // A share of none is armed and live, and still reaches nothing.
    assert_eq!(rogue.active(slot(1), at(0)), Some(none));
    assert_eq!(rogue.decide(slot(1), at(0), draw(0)), Decision::Pass);
}

#[test]
fn one_slots_fault_does_not_reach_another() {
    let mut rogue = Rogue::new();
    let last = slot(EXPERIMENTS - 1);
    let garble = Experiment::new(Fault::Garble, Fraction::ALL, LONG_AFTER);
    assert_eq!(rogue.arm(slot(0), raising(LONG_AFTER)), Arming::Armed);
    assert_eq!(rogue.arm(last, garble), Arming::Armed);

    assert_eq!(
        rogue.decide(slot(0), at(0), draw(0)),
        Decision::Inject(Fault::Raise)
    );
    assert_eq!(rogue.decide(slot(16), at(0), draw(0)), Decision::Pass);
    assert_eq!(
        rogue.decide(last, at(0), draw(0)),
        Decision::Inject(Fault::Garble)
    );
    assert_eq!(rogue.vacant(), Some(slot(1)));
}

#[test]
fn disarming_says_what_the_slot_held_and_a_repeat_changes_nothing() {
    let mut rogue = Rogue::new();
    let garble = Experiment::new(Fault::Garble, Fraction::ALL, LONG_AFTER);
    assert_eq!(rogue.arm(slot(0), raising(LONG_AFTER)), Arming::Armed);
    assert_eq!(rogue.arm(slot(1), garble), Arming::Armed);

    assert_eq!(
        rogue.disarm(slot(0)),
        Disarming::Disarmed(raising(LONG_AFTER))
    );
    assert_eq!(rogue.decide(slot(0), at(0), draw(0)), Decision::Pass);
    assert_eq!(
        rogue.decide(slot(1), at(0), draw(0)),
        Decision::Inject(Fault::Garble)
    );
    assert_eq!(rogue.armed_count(), 1);

    let before = rogue.clone();
    assert_eq!(rogue.disarm(slot(0)), Disarming::NotArmed);
    assert_eq!(rogue, before);

    // No instant is taken: the slot is emptied whatever the clock says, and
    // the caller judges the experiment it gets back, expired or not.
    assert_eq!(rogue.arm(slot(0), raising(at(100))), Arming::Armed);
    assert_eq!(rogue.disarm(slot(0)), Disarming::Disarmed(raising(at(100))));
}

#[test]
fn disarming_everything_clears_every_slot_and_counts_them() {
    let mut rogue = Rogue::new();
    for index in 0..EXPERIMENTS {
        assert_eq!(rogue.arm(slot(index), raising(LONG_AFTER)), Arming::Armed);
    }
    assert_eq!(rogue.armed_count(), u32::BITS);
    assert_eq!(rogue.vacant(), None);

    assert_eq!(rogue.disarm_all(), u32::BITS);

    assert!(!rogue.any_armed());
    assert_eq!(rogue.decide(slot(0), at(0), draw(0)), Decision::Pass);
    assert_eq!(rogue, Rogue::new());
    assert_eq!(rogue.disarm_all(), 0);
    assert_eq!(rogue, Rogue::new());
}

#[test]
fn a_query_judges_expiry_against_its_own_instant_and_changes_nothing() {
    let mut rogue = Rogue::new();
    assert_eq!(rogue.arm(slot(7), raising(at(100))), Arming::Armed);
    let before = rogue.clone();

    assert_eq!(rogue.decide(slot(7), at(100), draw(0)), Decision::Pass);
    assert_eq!(rogue.active(slot(7), at(100)), None);
    assert_eq!(rogue.live_count(at(100)), 0);
    // Expired, and still holding its slot: only a sweep gives it back.
    assert_eq!(rogue, before);
    assert!(rogue.any_armed());
    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(rogue.experiment(slot(7)), Some(raising(at(100))));
    // Nothing was recorded, so an earlier instant still finds it live.
    assert_eq!(
        rogue.decide(slot(7), at(99), draw(0)),
        Decision::Inject(Fault::Raise)
    );
    assert_eq!(rogue.live_count(at(99)), 1);
}

#[test]
fn a_sweep_retires_what_expired_and_a_backwards_clock_cannot_revive_it() {
    let mut rogue = Rogue::new();
    assert_eq!(rogue.arm(slot(7), raising(at(100))), Arming::Armed);
    assert_eq!(rogue.arm(slot(8), raising(at(200))), Arming::Armed);
    let before = rogue.clone();
    assert_eq!(rogue.sweep(at(99)), 0);
    assert_eq!(rogue, before);

    assert_eq!(rogue.sweep(at(100)), 1);

    assert_eq!(rogue.armed_count(), 1);
    assert_eq!(rogue.decide(slot(7), at(0), draw(0)), Decision::Pass);
    assert_eq!(
        rogue.decide(slot(8), at(100), draw(0)),
        Decision::Inject(Fault::Raise)
    );
    assert_eq!(rogue.vacant(), Some(slot(0)));
}
