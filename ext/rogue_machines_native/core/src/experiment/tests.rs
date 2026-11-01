use crate::{Experiment, Fault, Fraction, PER_MILLION};

fn fraction(millionths: u32) -> Fraction {
    Fraction::new(millionths).unwrap_or_else(|| unreachable!("{millionths} is a whole at most"))
}

#[test]
fn a_share_above_the_whole_is_refused() {
    assert_eq!(Fraction::new(PER_MILLION), Some(Fraction::ALL));
    assert!(Fraction::new(PER_MILLION + 1).is_none());
}

#[test]
fn the_extremes_cover_nothing_and_every_draw() {
    assert!(!Fraction::NONE.covers(0));
    assert!(!Fraction::NONE.covers(PER_MILLION - 1));
    assert!(Fraction::ALL.covers(0));
    assert!(Fraction::ALL.covers(PER_MILLION - 1));
}

#[test]
fn a_share_is_half_open_at_its_own_boundary() {
    let tenth = fraction(PER_MILLION / 10);

    assert!(tenth.covers(99_999));
    assert!(!tenth.covers(100_000));
}

#[test]
fn a_share_is_a_threshold_from_zero_and_not_an_interval() {
    let tenth = fraction(PER_MILLION / 10);
    let rest = fraction(PER_MILLION - PER_MILLION / 10);

    // Both claim a low draw: shares overlap rather than partition, so one
    // draw cannot be shared between two experiments.
    assert!(tenth.covers(0));
    assert!(rest.covers(0));
}

#[test]
fn a_draw_at_the_whole_is_outside_every_share() {
    assert!(!Fraction::ALL.covers(PER_MILLION));
}

#[test]
fn an_expiry_is_the_first_reading_it_no_longer_runs_at() {
    let experiment = Experiment::new(Fault::Raise, Fraction::ALL, 100);

    assert!(!experiment.spent(99));
    assert!(experiment.spent(100));
    assert!(experiment.spent(101));
}
