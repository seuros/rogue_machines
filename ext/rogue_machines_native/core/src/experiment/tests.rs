use core::time::Duration;

use crate::test_support::{at, draw, fraction, raising};
use crate::{Draw, Fraction, PER_MILLION};

#[test]
fn a_share_is_at_most_a_whole_and_a_draw_below_one() {
    assert_eq!(Fraction::new(PER_MILLION), Some(Fraction::ALL));
    assert_eq!(Fraction::new(PER_MILLION + 1), None);
    for (millionths, held) in [
        (0, true),
        (PER_MILLION - 1, true),
        (PER_MILLION, false),
        (u32::MAX, false),
    ] {
        assert_eq!(
            Draw::new(millionths).map(Draw::millionths),
            held.then_some(millionths)
        );
    }
}

#[test]
fn a_share_is_a_half_open_threshold_from_zero() {
    let tenth = fraction(PER_MILLION / 10);
    // Shares overlap rather than partition: both claim a low draw, so one
    // draw cannot be shared between two experiments.
    let rest = fraction(PER_MILLION - PER_MILLION / 10);
    for (share, millionths, covered) in [
        (Fraction::NONE, 0, false),
        (Fraction::NONE, PER_MILLION - 1, false),
        (Fraction::ALL, 0, true),
        (Fraction::ALL, PER_MILLION - 1, true),
        (tenth, 99_999, true),
        (tenth, 100_000, false),
        (tenth, 0, true),
        (rest, 0, true),
    ] {
        assert_eq!(
            share.covers(draw(millionths)),
            covered,
            "{share:?} {millionths}"
        );
    }
}

#[test]
fn an_expiry_is_the_first_instant_it_no_longer_runs_at_and_none_means_never() {
    for (expires_at, now, spent) in [
        (at(100), at(99), false),
        (at(100), at(100), true),
        (at(100), at(101), true),
        (Duration::MAX, Duration::new(u64::MAX, 999_999_998), false),
        (Duration::MAX, Duration::MAX, true),
    ] {
        assert_eq!(
            raising(expires_at).spent(now),
            spent,
            "{expires_at:?} at {now:?}"
        );
    }
}
