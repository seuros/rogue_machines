//! Ruby bindings for the `rogue-machines` fault injector.
//!
//! A plain mirror of the core: `RogueMachines::Rogue` wraps one `Rogue`, and
//! the `Data` values `Slot`, `Fraction`, `Draw`, `Delay`, `Experiment`,
//! `Inject`, `Replaced` and `Disarmed` (defined in Ruby, validated here) carry
//! the core's types. Time is Integer nanoseconds in and out. The process-wide
//! runtime (`RogueMachines.arm`, `RogueMachines.run`) is Ruby, on top of this.

mod rogue;
mod values;

use magnus::{Error, RModule, Ruby, prelude::*};
use rogue_machines::PER_MILLION;

/// A `RuntimeError` naming a binding that was set up twice or not at all.
pub(crate) fn setup_error(ruby: &Ruby, message: &'static str) -> Error {
    Error::new(ruby.exception_runtime_error(), message)
}

fn define_errors(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let base = module.define_error("Error", ruby.exception_standard_error())?;
    module.define_error("Injected", base)?;
    Ok(())
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("RogueMachines")?;
    module.const_set("PER_MILLION", PER_MILLION)?;
    module.const_set("EXPERIMENTS", rogue_machines::EXPERIMENTS)?;
    define_errors(ruby, module)?;
    values::define(ruby, module)?;
    rogue::define(ruby, module)
}
