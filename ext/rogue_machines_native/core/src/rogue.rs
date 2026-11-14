//! The experiments a process is running.

use core::time::Duration;

use crate::{Draw, EXPERIMENTS, Experiment, Fault, Slot};

/// What to do with one call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Make the real call.
    Pass,
    /// Do this instead.
    Inject(Fault),
}

/// What an honoured [`Rogue::arm`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arming {
    /// The slot was empty and now holds the experiment.
    Armed,
    /// The slot held this other experiment, which the new one replaced.
    Replaced(Experiment),
    /// The slot already holds exactly this experiment. Nothing changed.
    AlreadyArmed,
}

/// What a [`Rogue::disarm`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disarming {
    /// The slot held this experiment and is now empty.
    Disarmed(Experiment),
    /// The slot was already empty. Nothing changed.
    NotArmed,
}

/// A slot table and the mask over it.
///
/// A slot is *armed* while it holds an experiment, and that experiment is
/// *live* at an instant before its expiry. Expiry is never applied behind the
/// caller's back: [`active`](Self::active), [`decide`](Self::decide) and
/// [`live_count`](Self::live_count) judge it against the instant they are
/// given and change nothing, and only [`sweep`](Self::sweep) empties the slots
/// of experiments that have expired.
///
/// ```
/// use core::time::Duration;
/// use rogue_machines::{Arming, Decision, Draw, Experiment, Fault, Fraction, Rogue, Slot};
///
/// let Some(slot) = Slot::new(0) else { unreachable!() };
/// let Some(draw) = Draw::new(0) else { unreachable!() };
/// let second = Duration::from_secs(1);
/// let mut rogue = Rogue::new();
///
/// // Disarmed, which is where every process starts.
/// assert_eq!(rogue.decide(slot, Duration::ZERO, draw), Decision::Pass);
///
/// let experiment = Experiment::new(Fault::Raise, Fraction::ALL, 5 * second);
/// assert_eq!(rogue.arm(slot, experiment), Arming::Armed);
/// assert_eq!(rogue.decide(slot, second, draw), Decision::Inject(Fault::Raise));
///
/// // Past its expiry it injects nothing, and a sweep gives the slot back.
/// assert_eq!(rogue.decide(slot, 5 * second, draw), Decision::Pass);
/// assert!(rogue.any_armed());
/// assert_eq!(rogue.sweep(5 * second), 1);
/// assert!(!rogue.any_armed());
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rogue {
    /// One bit per slot, set exactly while `experiments` holds one there.
    armed: u32,
    experiments: [Option<Experiment>; EXPERIMENTS],
}

impl Default for Rogue {
    fn default() -> Self {
        Self::new()
    }
}

impl Rogue {
    /// Nothing armed.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            armed: 0,
            experiments: [None; EXPERIMENTS],
        }
    }

    /// Arms `slot` with `experiment`, replacing whatever it held, expired or
    /// not. Never refuses: the slot is the caller's to pick, and an
    /// experiment already spent is armed and injects nothing.
    ///
    /// Arming the identical experiment again is an honoured repeat: the slot
    /// already holds exactly that value, so [`Arming::AlreadyArmed`] is
    /// provable and nothing changes.
    pub fn arm(&mut self, slot: Slot, experiment: Experiment) -> Arming {
        let held = &mut self.experiments[slot.index()];
        let arming = match *held {
            None => Arming::Armed,
            Some(previous) if previous == experiment => return Arming::AlreadyArmed,
            Some(previous) => Arming::Replaced(previous),
        };
        *held = Some(experiment);
        self.armed |= slot.bit();
        arming
    }

    /// Empties `slot`, whether or not what it held had expired. Never refuses.
    pub const fn disarm(&mut self, slot: Slot) -> Disarming {
        match self.experiments[slot.index()].take() {
            Some(experiment) => {
                self.armed &= !slot.bit();
                Disarming::Disarmed(experiment)
            }
            None => Disarming::NotArmed,
        }
    }

    /// Empties every slot and answers how many held an experiment, expired or
    /// not. Never refuses; zero means nothing was armed and nothing changed.
    pub const fn disarm_all(&mut self) -> u32 {
        let held = self.armed.count_ones();
        self.experiments = [None; EXPERIMENTS];
        self.armed = 0;
        held
    }

    /// Empties every slot whose experiment has expired by `now` and answers
    /// how many. Never refuses; zero means nothing changed.
    ///
    /// The only call that applies an expiry. Without it an expired experiment
    /// injects nothing but keeps its slot, and keeps
    /// [`any_armed`](Self::any_armed) answering `true`.
    pub fn sweep(&mut self, now: Duration) -> u32 {
        let mut retired = 0;
        for (index, held) in self.experiments.iter_mut().enumerate() {
            if held.is_some_and(|experiment| experiment.spent(now)) {
                *held = None;
                self.armed &= !(1_u32 << index);
                retired += 1;
            }
        }
        retired
    }

    /// Whether any slot holds an experiment, expired or not: the one word a
    /// call reads when nothing is armed. `false` means every decision passes.
    #[must_use]
    pub const fn any_armed(&self) -> bool {
        self.armed != 0
    }

    /// How many slots hold an experiment, expired or not.
    #[must_use]
    pub const fn armed_count(&self) -> u32 {
        self.armed.count_ones()
    }

    /// How many slots hold an experiment that is live at `now`.
    #[must_use]
    pub fn live_count(&self, now: Duration) -> u32 {
        let mut live = 0;
        for experiment in self.experiments.iter().flatten() {
            if !experiment.spent(now) {
                live += 1;
            }
        }
        live
    }

    /// The lowest slot holding nothing, or `None` when every slot is armed.
    #[must_use]
    pub const fn vacant(&self) -> Option<Slot> {
        Slot::new(self.armed.trailing_ones() as usize)
    }

    /// The experiment `slot` holds, expired or not.
    #[must_use]
    pub const fn experiment(&self, slot: Slot) -> Option<Experiment> {
        self.experiments[slot.index()]
    }

    /// The experiment `slot` holds, if it is live at `now`.
    #[must_use]
    pub fn active(&self, slot: Slot, now: Duration) -> Option<Experiment> {
        self.experiments[slot.index()].filter(|experiment| !experiment.spent(now))
    }

    /// What to do with one call: inject when `slot` holds an experiment that
    /// is live at `now` and `draw` falls in the share it covers.
    #[must_use]
    pub fn decide(&self, slot: Slot, now: Duration, draw: Draw) -> Decision {
        match self.active(slot, now) {
            Some(experiment) if experiment.fraction.covers(draw) => {
                Decision::Inject(experiment.fault)
            }
            Some(_) | None => Decision::Pass,
        }
    }
}

#[cfg(test)]
mod tests;
