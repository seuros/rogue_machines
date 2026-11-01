//! Ruby bindings for the `rogue-machines` fault injector.
//!
//! The core decides; this layer names the experiments and converts seconds to
//! the nanoseconds the core counts in. The clock and the draw come from the
//! caller, so `RogueMachines.clock` and `RogueMachines.random` are swappable
//! and an experiment replays exactly.

#![allow(clippy::needless_pass_by_value)]

mod injection;
mod registry;

use std::sync::OnceLock;

use magnus::value::Opaque;
use magnus::{Error, ExceptionClass, Integer, RModule, Ruby, Value, prelude::*};
use rogue_machines::{Fraction, PER_MILLION};

static ERROR: OnceLock<Opaque<ExceptionClass>> = OnceLock::new();
static INJECTED: OnceLock<Opaque<ExceptionClass>> = OnceLock::new();

/// Nanoseconds in a second.
pub(crate) const NS_PER_SECOND: u32 = 1_000_000_000;

/// Longest an experiment may run for. An experiment is something a person is
/// waiting on, so a day is already generous; past that it is configuration,
/// and it must be re-armed deliberately.
pub(crate) const LONGEST_EXPERIMENT: f64 = 24.0 * 60.0 * 60.0;

/// Longest a single delay may wait. Bounds how long a stall can hold a caller
/// that has no deadline of its own.
pub(crate) const LONGEST_DELAY: f64 = 5.0 * 60.0;

/// Seconds as nanoseconds, rejecting a duration no experiment should run for.
///
/// An unbounded duration is not merely untidy: `as u64` saturates rather than
/// wrapping, so without `longest` a large `delay` becomes a stall of centuries.
#[expect(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn duration(ruby: &Ruby, name: &str, seconds: f64, longest: f64) -> Result<u64, Error> {
    if !seconds.is_finite() || seconds <= 0.0 || seconds > longest {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("{name} must be above 0 and at most {longest} seconds, got {seconds}"),
        ));
    }
    let nanoseconds = seconds * f64::from(NS_PER_SECOND);
    if nanoseconds < 1.0 {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("{name} of {seconds} is below the one nanosecond resolution"),
        ));
    }
    Ok(nanoseconds.round() as u64)
}

/// A reading in nanoseconds.
///
/// A Float is refused rather than truncated, and so is a value outside the
/// range: magnus would reject that with its own `RangeError`, which would
/// leak out of a protected call site as something the gem never documents.
pub(crate) fn reading(ruby: &Ruby, name: &str, value: Value) -> Result<u64, Error> {
    whole(ruby, name, value)?.to_u64().map_err(|_| {
        Error::new(
            ruby.exception_arg_error(),
            format!(
                "{name} must be a non-negative Integer of at most {}",
                u64::MAX
            ),
        )
    })
}

/// A draw below [`PER_MILLION`].
///
/// A truncated draw becomes 0, which every share covers, so a caller whose
/// `rand` returns a Float would inject on every call instead of none.
pub(crate) fn draw(ruby: &Ruby, value: Value) -> Result<u32, Error> {
    let drawn = whole(ruby, "draw", value)?.to_u32().map_err(|_| {
        Error::new(
            ruby.exception_arg_error(),
            format!("draw must be a non-negative Integer below {PER_MILLION}"),
        )
    })?;
    if drawn >= PER_MILLION {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("draw must be below {PER_MILLION}, got {drawn}"),
        ));
    }
    Ok(drawn)
}

/// A generation tag.
pub(crate) fn counted(ruby: &Ruby, name: &str, value: Value) -> Result<u32, Error> {
    whole(ruby, name, value)?.to_u32().map_err(|_| {
        Error::new(
            ruby.exception_arg_error(),
            format!(
                "{name} must be a non-negative Integer of at most {}",
                u32::MAX
            ),
        )
    })
}

fn whole(ruby: &Ruby, name: &str, value: Value) -> Result<Integer, Error> {
    Integer::from_value(value).ok_or_else(|| {
        Error::new(
            ruby.exception_arg_error(),
            format!("{name} must be an Integer"),
        )
    })
}

/// A share of calls, rejecting one outside a whole or too small to express.
#[expect(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn share(ruby: &Ruby, given: f64) -> Result<Fraction, Error> {
    if !given.is_finite() || !(0.0..=1.0).contains(&given) {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("share must be between 0 and 1, got {given}"),
        ));
    }
    let millionths = given * f64::from(PER_MILLION);
    if given > 0.0 && millionths < 1.0 {
        return Err(Error::new(
            ruby.exception_arg_error(),
            format!("share of {given} is below the one millionth resolution"),
        ));
    }
    let millionths = millionths.round() as u32;
    Fraction::new(millionths).ok_or_else(|| {
        Error::new(
            ruby.exception_arg_error(),
            format!("share of {millionths} millionths is not a whole"),
        )
    })
}

pub(crate) fn error(ruby: &Ruby, message: String) -> Error {
    ERROR.get().map_or_else(
        || {
            Error::new(
                ruby.exception_runtime_error(),
                "RogueMachines was not initialised",
            )
        },
        |class| Error::new(ruby.get_inner(*class), message),
    )
}

fn define_errors(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let base = module.define_error("Error", ruby.exception_standard_error())?;
    ERROR
        .set(base.into())
        .map_err(|_| error(ruby, "Error was defined twice".to_owned()))?;

    let injected = module.define_error("Injected", base)?;
    INJECTED
        .set(injected.into())
        .map_err(|_| error(ruby, "Injected was defined twice".to_owned()))
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("RogueMachines")?;
    module.const_set("NS_PER_SECOND", NS_PER_SECOND)?;
    module.const_set("PER_MILLION", PER_MILLION)?;
    module.const_set("EXPERIMENTS", rogue_machines::EXPERIMENTS)?;
    define_errors(ruby, module)?;
    injection::define(ruby, module)?;
    registry::define(ruby, module)
}
