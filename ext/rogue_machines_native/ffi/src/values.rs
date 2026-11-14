//! The `Data` values mirroring the core's types: validated on the way in
//! through the core's own constructors, built on the way out from what the
//! core returned.
//!
//! The classes are defined in Ruby before the extension loads; each one's
//! `initialize` calls a private hook here, so a hand-built value is held to
//! the same rule as one the binding returns.

use std::sync::OnceLock;
use std::time::Duration;

use magnus::rb_sys::AsRawValue;
use magnus::value::Opaque;
use magnus::{
    Error, Integer, RArray, RClass, RModule, Ruby, Symbol, TryConvert, Value, function, prelude::*,
};
use rogue_machines::{Draw, Experiment, Fault, Fraction, Slot};

use crate::setup_error;

/// The `Data` classes, looked up once at load so that nothing after a core
/// call has a lookup left that could raise.
pub struct Classes {
    slot: Opaque<RClass>,
    fraction: Opaque<RClass>,
    draw: Opaque<RClass>,
    delay: Opaque<RClass>,
    experiment: Opaque<RClass>,
    inject: Opaque<RClass>,
    replaced: Opaque<RClass>,
    disarmed: Opaque<RClass>,
}

static CLASSES: OnceLock<Classes> = OnceLock::new();

/// The classes, or a `RuntimeError` when the extension was loaded without
/// `rogue_machines.rb` defining them first.
pub fn classes(ruby: &Ruby) -> Result<&'static Classes, Error> {
    CLASSES
        .get()
        .ok_or_else(|| setup_error(ruby, "load rogue_machines, not the extension alone"))
}

fn type_error(ruby: &Ruby, message: String) -> Error {
    Error::new(ruby.exception_type_error(), message)
}

fn range_error(ruby: &Ruby, message: String) -> Error {
    Error::new(ruby.exception_range_error(), message)
}

/// An Integer as `T`: `TypeError` for anything else, `RangeError` outside
/// what `T` holds.
fn integer<T: TryConvert>(ruby: &Ruby, name: &str, value: Value) -> Result<T, Error> {
    if Integer::from_value(value).is_none() {
        return Err(type_error(ruby, format!("{name} must be an Integer")));
    }
    T::try_convert(value).map_err(|_| range_error(ruby, format!("{name} is out of range")))
}

/// Integer nanoseconds as a `Duration`, `0..=2**64-1`.
pub fn nanos(ruby: &Ruby, name: &str, value: Value) -> Result<Duration, Error> {
    integer::<u64>(ruby, name, value).map(Duration::from_nanos)
}

/// `value` when its class is exactly `class`, `TypeError` otherwise: a
/// subclass's constant leaks past the seal, so `is_a?` is not enough. The
/// classes are compared by identity, which no Ruby method can fake; the
/// fields are then rebuilt through the core's constructors, which
/// `Marshal.load` skipped.
fn instance(ruby: &Ruby, value: Value, class: Opaque<RClass>, name: &str) -> Result<Value, Error> {
    if value.class().as_raw() == ruby.get_inner(class).as_raw() {
        Ok(value)
    } else {
        Err(type_error(
            ruby,
            format!("expected a RogueMachines::{name}"),
        ))
    }
}

/// An Integer the core's constructor `build` accepts: `TypeError` for a
/// non-Integer, `RangeError` naming `rule` for anything `build` rejects.
fn constructed<N: TryConvert, T>(
    ruby: &Ruby,
    name: &str,
    value: Value,
    build: impl FnOnce(N) -> Option<T>,
    rule: impl FnOnce() -> String,
) -> Result<T, Error> {
    build(integer::<N>(ruby, name, value)?).ok_or_else(|| range_error(ruby, rule()))
}

fn slot_index(ruby: &Ruby, index: Value) -> Result<Slot, Error> {
    constructed(ruby, "index", index, Slot::new, || {
        format!("a slot is below {}", rogue_machines::EXPERIMENTS)
    })
}

fn fraction_millionths(ruby: &Ruby, millionths: Value) -> Result<Fraction, Error> {
    constructed(ruby, "millionths", millionths, Fraction::new, || {
        format!("a fraction is at most {}", rogue_machines::PER_MILLION)
    })
}

fn draw_millionths(ruby: &Ruby, millionths: Value) -> Result<Draw, Error> {
    constructed(ruby, "millionths", millionths, Draw::new, || {
        format!("a draw is below {}", rogue_machines::PER_MILLION)
    })
}

/// The core `Slot` of a `RogueMachines::Slot`.
pub fn slot(ruby: &Ruby, value: Value) -> Result<Slot, Error> {
    let value = instance(ruby, value, classes(ruby)?.slot, "Slot")?;
    slot_index(ruby, value.funcall("index", ())?)
}

/// The core `Draw` of a `RogueMachines::Draw`.
pub fn draw(ruby: &Ruby, value: Value) -> Result<Draw, Error> {
    let value = instance(ruby, value, classes(ruby)?.draw, "Draw")?;
    draw_millionths(ruby, value.funcall("millionths", ())?)
}

fn fraction(ruby: &Ruby, value: Value) -> Result<Fraction, Error> {
    let value = instance(ruby, value, classes(ruby)?.fraction, "Fraction")?;
    fraction_millionths(ruby, value.funcall("millionths", ())?)
}

/// `:raise`, `:garble` or a `RogueMachines::Delay`.
fn fault(ruby: &Ruby, value: Value) -> Result<Fault, Error> {
    if let Some(named) = Symbol::from_value(value) {
        return match named.name()?.as_ref() {
            "raise" => Ok(Fault::Raise),
            "garble" => Ok(Fault::Garble),
            other => Err(range_error(
                ruby,
                format!("a fault is :raise, :garble or a Delay, got :{other}"),
            )),
        };
    }
    let value = instance(ruby, value, classes(ruby)?.delay, "Delay")?;
    Ok(Fault::Delay(nanos(
        ruby,
        "duration",
        value.funcall("duration", ())?,
    )?))
}

/// The core `Experiment` of a `RogueMachines::Experiment`.
pub fn experiment(ruby: &Ruby, value: Value) -> Result<Experiment, Error> {
    let value = instance(ruby, value, classes(ruby)?.experiment, "Experiment")?;
    Ok(Experiment::new(
        fault(ruby, value.funcall("fault", ())?)?,
        fraction(ruby, value.funcall("fraction", ())?)?,
        nanos(ruby, "expires_at", value.funcall("expires_at", ())?)?,
    ))
}

/// A `Duration` the core returned, as Integer nanoseconds.
pub fn nanos_value(ruby: &Ruby, duration: Duration) -> Value {
    ruby.integer_from_u128(duration.as_nanos()).as_value()
}

impl Classes {
    /// `Data.new` with positional fields, which `initialize` validates.
    fn build(
        ruby: &Ruby,
        class: Opaque<RClass>,
        fields: impl magnus::ArgList,
    ) -> Result<Value, Error> {
        ruby.get_inner(class).funcall("new", fields)
    }

    pub fn slot(&self, ruby: &Ruby, slot: Slot) -> Result<Value, Error> {
        Self::build(ruby, self.slot, (slot.index(),))
    }

    pub fn fault(&self, ruby: &Ruby, fault: Fault) -> Result<Value, Error> {
        match fault {
            Fault::Raise => Ok(ruby.to_symbol("raise").as_value()),
            Fault::Garble => Ok(ruby.to_symbol("garble").as_value()),
            Fault::Delay(duration) => Self::build(ruby, self.delay, (nanos_value(ruby, duration),)),
        }
    }

    pub fn experiment(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        let fraction = Self::build(ruby, self.fraction, (experiment.fraction.millionths(),))?;
        let fault = self.fault(ruby, experiment.fault)?;
        let expires_at = nanos_value(ruby, experiment.expires_at);
        Self::build(ruby, self.experiment, (fault, fraction, expires_at))
    }

    pub fn inject(&self, ruby: &Ruby, fault: Fault) -> Result<Value, Error> {
        Self::build(ruby, self.inject, (self.fault(ruby, fault)?,))
    }

    pub fn replaced(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        Self::build(ruby, self.replaced, (self.experiment(ruby, experiment)?,))
    }

    pub fn disarmed(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        Self::build(ruby, self.disarmed, (self.experiment(ruby, experiment)?,))
    }
}

/// `Slot.new` validates through this: the index as `Slot::new` holds it.
fn checked_slot(ruby: &Ruby, index: Value) -> Result<usize, Error> {
    slot_index(ruby, index).map(Slot::index)
}

/// `Fraction.new`: the millionths as `Fraction::new` holds them.
fn checked_fraction(ruby: &Ruby, millionths: Value) -> Result<u32, Error> {
    fraction_millionths(ruby, millionths).map(Fraction::millionths)
}

/// `Draw.new`: the millionths as `Draw::new` holds them.
fn checked_draw(ruby: &Ruby, millionths: Value) -> Result<u32, Error> {
    draw_millionths(ruby, millionths).map(Draw::millionths)
}

/// Integer nanoseconds as a `Duration` holds them.
fn checked_nanos(ruby: &Ruby, name: &str, value: Value) -> Result<Value, Error> {
    nanos(ruby, name, value).map(|duration| nanos_value(ruby, duration))
}

/// `Delay.new`: its duration.
fn checked_delay(ruby: &Ruby, duration: Value) -> Result<Value, Error> {
    checked_nanos(ruby, "duration", duration)
}

/// `Experiment.new`: the fields unchanged once each is the core's own type.
fn checked_experiment(
    ruby: &Ruby,
    given_fault: Value,
    given_fraction: Value,
    expires_at: Value,
) -> Result<RArray, Error> {
    fault(ruby, given_fault)?;
    fraction(ruby, given_fraction)?;
    let expires_at = checked_nanos(ruby, "expires_at", expires_at)?;
    Ok(ruby.ary_new_from_values(&[given_fault, given_fraction, expires_at]))
}

/// `Inject.new`: a fault.
fn checked_fault(ruby: &Ruby, given: Value) -> Result<Value, Error> {
    fault(ruby, given).map(|_| given)
}

/// `Replaced.new` and `Disarmed.new`: an `Experiment`.
fn checked_held(ruby: &Ruby, given: Value) -> Result<Value, Error> {
    experiment(ruby, given).map(|_| given)
}

/// `Experiment#spent?`: the core's `Experiment::spent`.
fn spent(ruby: &Ruby, given: Value, now: Value) -> Result<bool, Error> {
    Ok(experiment(ruby, given)?.spent(nanos(ruby, "now", now)?))
}

/// `Fraction#covers?`: the core's `Fraction::covers`.
fn covers(ruby: &Ruby, given: Value, given_draw: Value) -> Result<bool, Error> {
    Ok(fraction(ruby, given)?.covers(draw(ruby, given_draw)?))
}

fn class(ruby: &Ruby, module: RModule, name: &str) -> Result<Opaque<RClass>, Error> {
    let class: RClass = module
        .const_get(name)
        .map_err(|_| setup_error(ruby, "load rogue_machines, not the extension alone"))?;
    // Held past this call: pinned so GC compaction cannot move it.
    ruby.gc_register_mark_object(class);
    Ok(class.into())
}

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let classes = Classes {
        slot: class(ruby, module, "Slot")?,
        fraction: class(ruby, module, "Fraction")?,
        draw: class(ruby, module, "Draw")?,
        delay: class(ruby, module, "Delay")?,
        experiment: class(ruby, module, "Experiment")?,
        inject: class(ruby, module, "Inject")?,
        replaced: class(ruby, module, "Replaced")?,
        disarmed: class(ruby, module, "Disarmed")?,
    };
    CLASSES
        .set(classes)
        .map_err(|_| setup_error(ruby, "the extension was loaded twice"))?;
    module.define_singleton_method("__slot", function!(checked_slot, 1))?;
    module.define_singleton_method("__fraction", function!(checked_fraction, 1))?;
    module.define_singleton_method("__draw", function!(checked_draw, 1))?;
    module.define_singleton_method("__delay", function!(checked_delay, 1))?;
    module.define_singleton_method("__experiment", function!(checked_experiment, 3))?;
    module.define_singleton_method("__fault", function!(checked_fault, 1))?;
    module.define_singleton_method("__held", function!(checked_held, 1))?;
    module.define_singleton_method("__spent", function!(spent, 2))?;
    module.define_singleton_method("__covers", function!(covers, 2))?;
    Ok(())
}
