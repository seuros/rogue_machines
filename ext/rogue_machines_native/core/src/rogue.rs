//! The experiments a process is running.

use crate::{Armed, EXPERIMENTS, Experiment, Fault, PER_MILLION, Slot};

/// What to do with one call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Make the real call.
    Pass,
    /// Do this instead.
    Inject(Fault),
}

/// A slot table and the mask over it.
///
/// ```
/// use rogue_machines::{Decision, Experiment, Fault, Fraction, Rogue, Slot};
///
/// const SECOND: u64 = 1_000_000_000;
/// let Some(slot) = Slot::new(0) else { unreachable!() };
/// let mut rogue = Rogue::new();
///
/// // Disarmed, which is where every process starts.
/// assert_eq!(rogue.decide(slot, 0, 0), Decision::Pass);
///
/// rogue.arm(slot, Experiment::new(Fault::Raise, Fraction::ALL, 5 * SECOND));
/// assert_eq!(rogue.decide(slot, SECOND, 0), Decision::Inject(Fault::Raise));
///
/// // Past its expiry it disarms itself, and stays disarmed.
/// assert_eq!(rogue.decide(slot, 5 * SECOND, 0), Decision::Pass);
/// assert!(!rogue.any_armed());
/// ```
#[derive(Debug)]
pub struct Rogue {
    armed: Armed,
    experiments: [Option<Experiment>; EXPERIMENTS],
}

impl Default for Rogue {
    fn default() -> Self {
        Self::new()
    }
}

impl Rogue {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            armed: Armed::new(),
            experiments: [None; EXPERIMENTS],
        }
    }

    /// Arms `slot`, replacing whatever it held.
    pub fn arm(&mut self, slot: Slot, experiment: Experiment) {
        self.experiments[slot.index()] = Some(experiment);
        self.armed.hold(slot);
    }

    pub fn disarm(&mut self, slot: Slot) {
        self.experiments[slot.index()] = None;
        self.armed.release(slot);
    }

    pub fn disarm_all(&mut self) {
        self.experiments = [None; EXPERIMENTS];
        self.armed.release_all();
    }

    /// Whether any experiment is armed as of the last [`sweep`](Self::sweep),
    /// which is the only read a call runs when none is.
    #[must_use]
    pub fn any_armed(&self) -> bool {
        self.armed.any()
    }

    /// How many experiments are armed as of the last [`sweep`](Self::sweep).
    #[must_use]
    pub fn armed_count(&self) -> u32 {
        self.armed.count()
    }

    /// Releases every slot whose experiment has expired by `now_ns`.
    ///
    /// [`any_armed`](Self::any_armed) is a bare mask read, so without this an
    /// experiment that expired on a slot nothing decides on again would hold
    /// the gate open for the life of the process. Both readers below sweep
    /// first, so the next call of either restores the disarmed fast path.
    pub fn sweep(&self, now_ns: u64) {
        if !self.armed.any() {
            return;
        }
        for index in 0..EXPERIMENTS {
            let Some(slot) = Slot::new(index) else {
                continue;
            };
            if self.armed.holds(slot) && self.spent(slot, now_ns) {
                self.armed.release(slot);
            }
        }
    }

    /// The experiment arming `slot` at `now_ns`.
    #[must_use]
    pub fn active(&self, slot: Slot, now_ns: u64) -> Option<&Experiment> {
        self.sweep(now_ns);
        if !self.armed.holds(slot) {
            return None;
        }
        self.experiments[slot.index()].as_ref()
    }

    /// What to do with one call: retires anything expired by `now_ns`, then
    /// injects if `slot` is armed and `draw`, which is below
    /// [`PER_MILLION`](crate::PER_MILLION), falls in the share it covers.
    #[must_use]
    pub fn decide(&self, slot: Slot, now_ns: u64, draw: u32) -> Decision {
        debug_assert!(draw < PER_MILLION, "a draw must be below PER_MILLION");
        match self.active(slot, now_ns) {
            Some(experiment) if experiment.fraction.covers(draw) => {
                Decision::Inject(experiment.fault)
            }
            _ => Decision::Pass,
        }
    }

    /// Whether `slot` holds nothing, or holds something already expired. An
    /// empty slot counts as spent so a bit can never outlive its experiment.
    fn spent(&self, slot: Slot, now_ns: u64) -> bool {
        self.experiments[slot.index()].is_none_or(|experiment| experiment.spent(now_ns))
    }
}

#[cfg(test)]
mod tests;
