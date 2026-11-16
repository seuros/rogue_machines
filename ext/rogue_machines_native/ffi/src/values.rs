//! The `Data` values mirroring the core's types: validated on the way in
//! through the core's own constructors, built on the way out from what the
//! core returned.
//!
//! The classes are defined in Ruby before the extension loads; each one's
//! `initialize` calls a private hook here, so a hand-built value is held to
//! the same rule as one the binding returns.

use magnus::{Error, RArray, RModule, Ruby, Value, function, prelude::*};
use matryona_machines::ruby::{
    Bounded, Choice, Class, Refused, SymbolNames, class_name, duration, exact_fields, integer,
    nanoseconds, symbol_or_fields_why,
};
use rogue_machines::{Draw, Experiment, Fault, Fraction, Slot};

/// The `Data` classes, looked up once at load and pinned, so that nothing
/// after a core call has a lookup left that could raise.
pub struct Classes {
    slot: Class,
    fraction: Class,
    draw: Class,
    delay: Class,
    experiment: Class,
    inject: Class,
    replaced: Class,
    disarmed: Class,
}

matryona_machines::registry! {
    static CLASSES: Classes = "rogue_machines";
    /// The classes, or a `NameError` when the extension was loaded without
    /// `rogue_machines.rb` defining them first.
    pub fn classes;
}

fn range_error(ruby: &Ruby, message: String) -> Error {
    Error::new(ruby.exception_range_error(), message)
}

/// The `N` fields of `value` when it is an instance of exactly `class`,
/// `TypeError` with `message` otherwise: a subclass's constant leaks past the
/// seal, so `is_a?` is not enough, and an opened singleton class changes
/// nothing. The fields are read from the struct itself, so a redefined reader
/// is never called, then rebuilt through the core's constructors, which
/// `Marshal.load` skipped.
fn fields<const N: usize>(
    ruby: &Ruby,
    value: Value,
    class: Class,
    message: &'static str,
) -> Result<[Value; N], Error> {
    exact_fields(ruby, value, class.get(ruby), message)
}

/// An Integer the core's constructor `build` accepts: `TypeError` for a
/// non-Integer, `RangeError` naming `rule` for anything `build` rejects.
fn constructed<N: Bounded, T>(
    ruby: &Ruby,
    name: &str,
    value: Value,
    build: impl FnOnce(N) -> Option<T>,
    rule: impl FnOnce() -> String,
) -> Result<T, Error> {
    build(integer::<N>(value, name)?).ok_or_else(|| range_error(ruby, rule()))
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
    let [index] = fields(
        ruby,
        value,
        classes(ruby)?.slot,
        "expected a RogueMachines::Slot",
    )?;
    slot_index(ruby, index)
}

/// The core `Draw` of a `RogueMachines::Draw`.
pub fn draw(ruby: &Ruby, value: Value) -> Result<Draw, Error> {
    let [millionths] = fields(
        ruby,
        value,
        classes(ruby)?.draw,
        "expected a RogueMachines::Draw",
    )?;
    draw_millionths(ruby, millionths)
}

fn fraction(ruby: &Ruby, value: Value) -> Result<Fraction, Error> {
    let message = "expected a RogueMachines::Fraction";
    let [millionths] = fields(ruby, value, classes(ruby)?.fraction, message)?;
    fraction_millionths(ruby, millionths)
}

matryona_machines::symbols! {
    /// A fault as Ruby holds it: `:raise`, `:garble`, or a `Delay`.
    Faults for Fault as "a fault" => names_only {
        Raise => "raise",
        Delay(..) => "delay",
        Garble => "garble",
    }
}

/// `:raise`, `:garble` or a `RogueMachines::Delay`: `RangeError` for any
/// other Symbol, `TypeError` for anything else, each naming what it got.
fn fault(ruby: &Ruby, value: Value) -> Result<Fault, Error> {
    let delay = classes(ruby)?.delay.get(ruby);
    let read = symbol_or_fields_why(ruby, value, Faults, &[delay], |why| {
        let got = match why {
            Refused::UnknownSymbol(symbol) => symbol.inspect(),
            _ => class_name(value),
        };
        format!("a fault is :raise, :garble or a Delay, got {got}")
    })?;
    match read {
        Choice::Symbol(fault) => Ok(fault),
        Choice::Struct(_, [span]) => Ok(Fault::Delay(duration(span, "duration")?)),
    }
}

/// The core `Experiment` of a `RogueMachines::Experiment`.
pub fn experiment(ruby: &Ruby, value: Value) -> Result<Experiment, Error> {
    let message = "expected a RogueMachines::Experiment";
    let [given_fault, given_fraction, expires_at] =
        fields(ruby, value, classes(ruby)?.experiment, message)?;
    Ok(Experiment::new(
        fault(ruby, given_fault)?,
        fraction(ruby, given_fraction)?,
        duration(expires_at, "expires_at")?,
    ))
}

impl Classes {
    /// `Data.new` with positional fields, which `initialize` validates.
    fn build(ruby: &Ruby, class: Class, fields: impl magnus::ArgList) -> Result<Value, Error> {
        class.get(ruby).funcall("new", fields)
    }

    pub fn slot(&self, ruby: &Ruby, slot: Slot) -> Result<Value, Error> {
        Self::build(ruby, self.slot, (slot.index(),))
    }

    pub fn fault(&self, ruby: &Ruby, fault: Fault) -> Result<Value, Error> {
        match fault {
            Fault::Raise | Fault::Garble => Ok(Faults::symbol(ruby, &fault).as_value()),
            Fault::Delay(span) => Self::build(ruby, self.delay, (nanoseconds(ruby, span),)),
        }
    }

    pub fn experiment(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        let fraction = Self::build(ruby, self.fraction, (experiment.fraction.millionths(),))?;
        let fault = self.fault(ruby, experiment.fault)?;
        let expires_at = nanoseconds(ruby, experiment.expires_at);
        Self::build(ruby, self.experiment, (fault, fraction, expires_at))
    }

    pub fn inject(&self, ruby: &Ruby, fault: Fault) -> Result<Value, Error> {
        Self::build(ruby, self.inject, (self.fault(ruby, fault)?,))
    }

    pub fn replaced(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        self.held(ruby, self.replaced, experiment)
    }

    pub fn disarmed(&self, ruby: &Ruby, experiment: Experiment) -> Result<Value, Error> {
        self.held(ruby, self.disarmed, experiment)
    }

    /// A `Replaced` or `Disarmed`: the experiment, and `garbled` nil. The
    /// core keeps no substitute; the one these carry is the runtime's.
    fn held(&self, ruby: &Ruby, class: Class, experiment: Experiment) -> Result<Value, Error> {
        let garbled = ruby.qnil().as_value();
        Self::build(ruby, class, (self.experiment(ruby, experiment)?, garbled))
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
    duration(value, name).map(|span| nanoseconds(ruby, span).as_value())
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

/// `__delay_of`: what the runtime's `arm` bounds before it arms, read as
/// every fault is read (`fault`'s errors, a `Delay` by exact class from the
/// struct): nil for `:raise` and `:garble`, a `Delay`'s Integer nanoseconds.
fn delay_of(ruby: &Ruby, given: Value) -> Result<Option<Value>, Error> {
    Ok(match fault(ruby, given)? {
        Fault::Delay(span) => Some(nanoseconds(ruby, span).as_value()),
        Fault::Raise | Fault::Garble => None,
    })
}

/// `Replaced.new` and `Disarmed.new`: an `Experiment` (their `garbled` is
/// any object and is not read here).
fn checked_held(ruby: &Ruby, given: Value) -> Result<Value, Error> {
    experiment(ruby, given).map(|_| given)
}

/// `Experiment#spent?`: the core's `Experiment::spent`.
fn spent(ruby: &Ruby, given: Value, now: Value) -> Result<bool, Error> {
    Ok(experiment(ruby, given)?.spent(duration(now, "now")?))
}

/// `Fraction#covers?`: the core's `Fraction::covers`.
fn covers(ruby: &Ruby, given: Value, given_draw: Value) -> Result<bool, Error> {
    Ok(fraction(ruby, given)?.covers(draw(ruby, given_draw)?))
}

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let class = |name| Class::resolve(ruby, module, name);
    let classes = Classes {
        slot: class("Slot")?,
        fraction: class("Fraction")?,
        draw: class("Draw")?,
        delay: class("Delay")?,
        experiment: class("Experiment")?,
        inject: class("Inject")?,
        replaced: class("Replaced")?,
        disarmed: class("Disarmed")?,
    };
    CLASSES.set(ruby, classes)?;
    module.define_singleton_method("__slot", function!(checked_slot, 1))?;
    module.define_singleton_method("__fraction", function!(checked_fraction, 1))?;
    module.define_singleton_method("__draw", function!(checked_draw, 1))?;
    module.define_singleton_method("__delay", function!(checked_delay, 1))?;
    module.define_singleton_method("__experiment", function!(checked_experiment, 3))?;
    module.define_singleton_method("__fault", function!(checked_fault, 1))?;
    module.define_singleton_method("__delay_of", function!(delay_of, 1))?;
    module.define_singleton_method("__held", function!(checked_held, 1))?;
    module.define_singleton_method("__spent", function!(spent, 2))?;
    module.define_singleton_method("__covers", function!(covers, 2))?;
    Ok(())
}
