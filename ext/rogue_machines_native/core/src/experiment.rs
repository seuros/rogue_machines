//! What a fault is, who gets it, and when it stops.

use crate::PER_MILLION;

/// What the caller does instead of the real call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// Fail.
    Raise,
    /// Take this many nanoseconds longer, then make the real call.
    Delay { ns: u64 },
    /// Succeed, with a substitute value.
    Garble,
}

/// The share of calls a fault reaches, in millionths.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Fraction(u32);

impl Fraction {
    /// Reaches nothing.
    pub const NONE: Self = Self(0);

    /// Reaches every call.
    pub const ALL: Self = Self(PER_MILLION);

    /// Rejects a share above [`PER_MILLION`].
    #[must_use]
    pub const fn new(millionths: u32) -> Option<Self> {
        if millionths > PER_MILLION {
            None
        } else {
            Some(Self(millionths))
        }
    }

    #[must_use]
    pub const fn millionths(self) -> u32 {
        self.0
    }

    /// Whether `draw`, which is below [`PER_MILLION`], falls in this share.
    #[must_use]
    pub const fn covers(self, draw: u32) -> bool {
        draw < self.0
    }
}

/// An armed fault.
///
/// The expiry is what keeps an experiment from outliving the person who armed
/// it, so there is no way to build one without a reading it expires at.
///
/// An expiry is only meaningful against the clock it was computed on. This
/// does not try to infer that a reading came from a different clock: with
/// several threads taking their own readings, a reading older than the arming
/// is ordinary interleaving rather than evidence of anything, and treating it
/// as evidence retires experiments that were just armed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Experiment {
    pub fault: Fault,
    pub fraction: Fraction,
    /// The first reading at which this is no longer armed.
    pub expires_at_ns: u64,
}

impl Experiment {
    #[must_use]
    pub const fn new(fault: Fault, fraction: Fraction, expires_at_ns: u64) -> Self {
        Self {
            fault,
            fraction,
            expires_at_ns,
        }
    }

    #[must_use]
    pub const fn spent(&self, now_ns: u64) -> bool {
        now_ns >= self.expires_at_ns
    }
}

#[cfg(test)]
mod tests;
