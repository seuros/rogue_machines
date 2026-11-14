use crate::{EXPERIMENTS, Slot};

#[test]
fn an_index_inside_the_mask_is_a_slot_with_its_own_bit() {
    assert_eq!(Slot::new(EXPERIMENTS), None);
    assert_eq!(Slot::new(usize::MAX), None);
    let mut seen = 0_u32;
    for index in 0..EXPERIMENTS {
        let slot = crate::test_support::slot(index);
        assert_eq!(slot.index(), index);
        assert_eq!(seen & slot.bit(), 0);
        seen |= slot.bit();
    }
    assert_eq!(seen, u32::MAX);
}
