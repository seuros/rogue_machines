//! What a fault is, who gets it, and when it stops.

use core::time::Duration;

use crate::PER_MILLION;

/// What the caller does instead of the real call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// Fail.
    Raise,
    /// Take this much longer, then make the real call.
    Delay(Duration),
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

    /// The share, in millionths.
    #[must_use]
    pub const fn millionths(self) -> u32 {
        self.0
    }

    /// Whether `draw` falls in this share.
    #[must_use]
    pub const fn covers(self, draw: Draw) -> bool {
        draw.0 < self.0
    }
}

/// One call's random draw, in millionths: always below [`PER_MILLION`].
///
/// A type rather than a bare integer so a draw at or above the whole, which
/// no share covers and which would bias every decision to pass, cannot reach
/// a decision at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Draw(u32);

impl Draw {
    /// Rejects a draw at or above [`PER_MILLION`].
    #[must_use]
    pub const fn new(millionths: u32) -> Option<Self> {
        if millionths < PER_MILLION {
            Some(Self(millionths))
        } else {
            None
        }
    }

    /// The draw, in millionths.
    #[must_use]
    pub const fn millionths(self) -> u32 {
        self.0
    }
}

/// An armed fault.
///
/// The expiry is what keeps an experiment from outliving the person who armed
/// it, so there is no way to build one without an instant it expires at.
/// Every combination of fields is a valid experiment.
///
/// An expiry is only meaningful against the clock it was computed on. This
/// does not try to infer that an instant came from a different clock: with
/// several threads taking their own readings, an instant older than the
/// arming is ordinary interleaving rather than evidence of anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Experiment {
    /// What an injected call does.
    pub fault: Fault,
    /// The share of calls it reaches.
    pub fraction: Fraction,
    /// The first instant at which this is no longer live.
    pub expires_at: Duration,
}

impl Experiment {
    /// An experiment that injects `fault` into `fraction` of calls until
    /// `expires_at`.
    #[must_use]
    pub const fn new(fault: Fault, fraction: Fraction, expires_at: Duration) -> Self {
        Self {
            fault,
            fraction,
            expires_at,
        }
    }

    /// Whether this has expired by `now`: `now >= expires_at`.
    #[must_use]
    pub fn spent(&self, now: Duration) -> bool {
        now >= self.expires_at
    }
}

#[cfg(test)]
mod tests;
