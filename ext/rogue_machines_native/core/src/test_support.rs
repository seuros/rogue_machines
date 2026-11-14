//! Fixtures the unit tests share.

use core::time::Duration;

use crate::{Draw, Experiment, Fault, Fraction, Slot};

/// An instant `nanoseconds` after the epoch.
pub const fn at(nanoseconds: u64) -> Duration {
    Duration::from_nanos(nanoseconds)
}

pub fn slot(index: usize) -> Slot {
    Slot::new(index).expect("the index is inside the mask")
}

pub fn fraction(millionths: u32) -> Fraction {
    Fraction::new(millionths).expect("the share is a whole at most")
}

pub fn draw(millionths: u32) -> Draw {
    Draw::new(millionths).expect("the draw is below a whole")
}

/// Raises on every call until `expires_at`.
pub const fn raising(expires_at: Duration) -> Experiment {
    Experiment::new(Fault::Raise, Fraction::ALL, expires_at)
}
