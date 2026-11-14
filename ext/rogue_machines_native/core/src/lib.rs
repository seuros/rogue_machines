#![no_std]

//! Fault injection: making a dependency fail, stall or lie on purpose.
//!
//! A [`Rogue`] holds the experiments a process is running and answers one
//! question per call: inject a fault, or pass.
//!
//! Nothing here performs a fault. The caller raises, sleeps and substitutes,
//! and supplies both the clock and the draw. Disarmed is the default and the
//! fast path: with nothing armed, [`Rogue::any_armed`] is one word compared
//! with zero.
//!
//! Time is [`core::time::Duration`] since an epoch the caller picks. The core
//! keeps no clock of its own: an expiry is judged against the instant each
//! call supplies, and no call records one.
//!
//! Nothing here refuses, so the crate has no `Refusal`: a [`Slot`] is the
//! caller's to pick, every slot can always be armed, and the answers to
//! [`Rogue::arm`], [`Rogue::disarm`] and [`Rogue::disarm_all`] say what the
//! slots held before.

/// Compiles and runs the README's examples as doctests.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct ReadmeDoctests;

pub mod experiment;
pub mod rogue;
pub mod slot;

#[cfg(test)]
mod test_support;

pub use experiment::{Draw, Experiment, Fault, Fraction};
pub use rogue::{Arming, Decision, Disarming, Rogue};
pub use slot::Slot;

/// Slots a [`Rogue`] holds, which is the width of the mask tracking them.
pub const EXPERIMENTS: usize = u32::BITS as usize;

/// Millionths in a whole, the unit a [`Fraction`] and a [`Draw`] are given in.
pub const PER_MILLION: u32 = 1_000_000;
