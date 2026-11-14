//! A randomized run against a model that keeps a plain list of experiments.

use core::time::Duration;

use matryona_machines::testing::{XorShift64, unchanged};

use crate::test_support::{at, draw, fraction, slot};
use crate::{Arming, Decision, Disarming, EXPERIMENTS, Experiment, Fault, PER_MILLION, Rogue};

/// Draws on matryona's xorshift: deterministic, so a failure replays.
struct Random(XorShift64);

impl Random {
    const fn below(&mut self, bound: u64) -> u64 {
        self.0.below(bound)
    }

    fn index(&mut self) -> usize {
        usize::try_from(self.below(EXPERIMENTS as u64)).expect("below the mask width")
    }

    fn millionths(&mut self, bound: u32) -> u32 {
        u32::try_from(self.below(u64::from(bound))).expect("below a u32 bound")
    }

    fn experiment(&mut self) -> Experiment {
        let fault = match self.below(3) {
            0 => Fault::Raise,
            1 => Fault::Delay(at(self.below(4))),
            _ => Fault::Garble,
        };
        let fraction = fraction(self.millionths(PER_MILLION + 1));
        // Few distinct values, so identical re-arms and expiries both happen.
        Experiment::new(fault, fraction, at(self.below(6) * 20))
    }
}

/// The reference: what each slot holds, and nothing else.
type Model = [Option<Experiment>; EXPERIMENTS];

fn live(model: &Model, index: usize, now: Duration) -> Option<Experiment> {
    model[index].filter(|experiment| now < experiment.expires_at)
}

fn agree(rogue: &Rogue, model: &Model, now: Duration, random: &mut Random) {
    let held = model.iter().flatten().count();
    assert_eq!(rogue.armed_count() as usize, held);
    assert_eq!(rogue.any_armed(), held > 0);
    let alive = (0..EXPERIMENTS).filter(|index| live(model, *index, now).is_some());
    assert_eq!(rogue.live_count(now) as usize, alive.count());
    assert_eq!(
        rogue.vacant().map(crate::Slot::index),
        model.iter().position(Option::is_none)
    );
    for (index, held) in model.iter().enumerate() {
        assert_eq!(rogue.experiment(slot(index)), *held);
        assert_eq!(rogue.active(slot(index), now), live(model, index, now));
        let drawn = draw(random.millionths(PER_MILLION));
        let expected = match live(model, index, now) {
            Some(experiment) if drawn.millionths() < experiment.fraction.millionths() => {
                Decision::Inject(experiment.fault)
            }
            Some(_) | None => Decision::Pass,
        };
        assert_eq!(rogue.decide(slot(index), now, drawn), expected);
    }
}

fn arm(rogue: &mut Rogue, model: &mut Model, random: &mut Random) {
    let (index, experiment) = (random.index(), random.experiment());
    let arming = |r: &mut Rogue| r.arm(slot(index), experiment);
    match model[index] {
        None => assert_eq!(arming(rogue), Arming::Armed),
        Some(previous) if previous == experiment => {
            assert_eq!(unchanged(rogue, arming), Arming::AlreadyArmed);
        }
        Some(previous) => assert_eq!(arming(rogue), Arming::Replaced(previous)),
    }
    model[index] = Some(experiment);
}

fn disarm(rogue: &mut Rogue, model: &mut Model, random: &mut Random) {
    let index = random.index();
    if let Some(previous) = model[index].take() {
        assert_eq!(rogue.disarm(slot(index)), Disarming::Disarmed(previous));
    } else {
        assert_eq!(
            unchanged(rogue, |r| r.disarm(slot(index))),
            Disarming::NotArmed
        );
    }
}

fn disarm_all(rogue: &mut Rogue, model: &mut Model) {
    let held = model.iter().flatten().count();
    if held == 0 {
        assert_eq!(unchanged(rogue, Rogue::disarm_all), 0);
    } else {
        assert_eq!(rogue.disarm_all() as usize, held);
    }
    *model = [None; EXPERIMENTS];
}

fn sweep(rogue: &mut Rogue, model: &mut Model, now: Duration) {
    let mut expired = 0;
    for held in model.iter_mut() {
        if held.is_some_and(|experiment| now >= experiment.expires_at) {
            *held = None;
            expired += 1;
        }
    }
    if expired == 0 {
        assert_eq!(unchanged(rogue, |r| r.sweep(now)), 0);
    } else {
        assert_eq!(rogue.sweep(now), expired);
    }
}

#[test]
fn a_random_run_matches_the_model_and_no_repeat_or_query_changes_anything() {
    for seed in 1..=24_u64 {
        let mut random = Random(XorShift64::new(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15)));
        let mut rogue = Rogue::new();
        let mut model: Model = [None; EXPERIMENTS];
        for _ in 0..4_000 {
            // Not monotonic on purpose: the core keeps no clock to regress.
            let now = at(random.below(130));
            match random.below(16) {
                0..=7 => arm(&mut rogue, &mut model, &mut random),
                8..=11 => disarm(&mut rogue, &mut model, &mut random),
                12 => disarm_all(&mut rogue, &mut model),
                _ => sweep(&mut rogue, &mut model, now),
            }
            // `agree` only asks `&self` queries: nothing can change.
            agree(&rogue, &model, now, &mut random);
        }
    }
}
