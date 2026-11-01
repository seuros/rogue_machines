#![cfg_attr(not(feature = "std"), no_std)]

//! Fault injection: making a dependency fail, stall or lie on purpose.
//!
//! A [`Rogue`] holds the experiments a process is running and answers one
//! question per call: inject a fault, or pass.
//!
//! Nothing here performs a fault. The caller raises, sleeps and substitutes,
//! and supplies both the clock and the draw. Disarmed is the default and the
//! fast path: with nothing armed a decision is one relaxed load.

/// Compiles and runs the README's examples as doctests.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct ReadmeDoctests;

mod armed;
pub mod experiment;
pub mod rogue;

pub(crate) use armed::Armed;
pub use armed::Slot;
pub use experiment::{Experiment, Fault, Fraction};
pub use rogue::{Decision, Rogue};

/// Slots a [`Rogue`] holds, which is the width of the mask tracking them.
pub const EXPERIMENTS: usize = u32::BITS as usize;

/// Millionths in a whole, the unit a [`Fraction`] is given in.
pub const PER_MILLION: u32 = 1_000_000;
