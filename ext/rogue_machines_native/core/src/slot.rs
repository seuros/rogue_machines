//! Which experiment a call is asking about.

use crate::EXPERIMENTS;

/// A slot index a [`Rogue`](crate::Rogue) can hold. The caller picks it; the
/// core issues none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
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

    /// The index this slot was built from.
    #[must_use]
    pub const fn index(self) -> usize {
        self.0
    }

    /// This slot's bit in the armed mask.
    pub(crate) const fn bit(self) -> u32 {
        1_u32 << self.0
    }
}

#[cfg(test)]
mod tests;
