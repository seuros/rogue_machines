use crate::{Armed, EXPERIMENTS, Slot};

fn slot(index: usize) -> Slot {
    Slot::new(index).unwrap_or_else(|| unreachable!("{index} is inside the mask"))
}

#[test]
fn a_slot_outside_the_mask_is_refused() {
    assert!(Slot::new(EXPERIMENTS - 1).is_some());
    assert!(Slot::new(EXPERIMENTS).is_none());
}

#[test]
fn the_highest_slot_is_one_slot_and_not_a_sign() {
    let armed = Armed::new();
    armed.hold(slot(EXPERIMENTS - 1));

    assert!(armed.holds(slot(EXPERIMENTS - 1)));
    assert!(!armed.holds(slot(0)));
    assert_eq!(armed.count(), 1);
}

#[test]
fn releasing_one_slot_leaves_its_neighbours_armed() {
    let armed = Armed::new();
    for index in 0..EXPERIMENTS {
        armed.hold(slot(index));
    }
    assert_eq!(armed.count(), u32::BITS);

    armed.release(slot(7));

    assert!(!armed.holds(slot(7)));
    assert!(armed.holds(slot(6)));
    assert!(armed.holds(slot(8)));
    assert_eq!(armed.count(), u32::BITS - 1);
}

#[test]
fn releasing_everything_leaves_nothing_armed() {
    let armed = Armed::new();
    armed.hold(slot(0));
    armed.hold(slot(31));
    armed.release_all();

    assert!(!armed.any());
    assert_eq!(armed.count(), 0);
}
