//! Which slots are armed, in one word.

use core::sync::atomic::{AtomicU32, Ordering};

use crate::EXPERIMENTS;

/// A slot index a [`Rogue`](crate::Rogue) can hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Slot(usize);

impl Slot {
    /// Rejects an index at or above [`EXPERIMENTS`].
    #[must_use]
    pub const fn new(index: usize) -> Option<Self> {
        if index < EXPERIMENTS {
            Some(Self(index))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn index(self) -> usize {
        self.0
    }

    const fn bit(self) -> u32 {
        1_u32 << self.0
    }
}

/// One bit per slot, read on every protected call and written only when an
/// experiment is armed, disarmed or found expired.
///
/// Every operation is `Relaxed`. That is sufficient only because the
/// experiment table is written behind `&mut self`, so the mask never has to
/// publish it. Giving `Rogue::arm` interior mutability would break that.
#[derive(Debug, Default)]
pub struct Armed(AtomicU32);

impl Armed {
    #[must_use]
    pub const fn new() -> Self {
        Self(AtomicU32::new(0))
    }

    /// Whether any slot is armed.
    #[must_use]
    pub fn any(&self) -> bool {
        self.0.load(Ordering::Relaxed) != 0
    }

    #[must_use]
    pub fn holds(&self, slot: Slot) -> bool {
        self.0.load(Ordering::Relaxed) & slot.bit() != 0
    }

    pub fn hold(&self, slot: Slot) {
        self.0.fetch_or(slot.bit(), Ordering::Relaxed);
    }

    pub fn release(&self, slot: Slot) {
        self.0.fetch_and(!slot.bit(), Ordering::Relaxed);
    }

    pub fn release_all(&self) {
        self.0.store(0, Ordering::Relaxed);
    }

    /// How many slots are armed.
    #[must_use]
    pub fn count(&self) -> u32 {
        self.0.load(Ordering::Relaxed).count_ones()
    }
}

#[cfg(test)]
mod tests;
