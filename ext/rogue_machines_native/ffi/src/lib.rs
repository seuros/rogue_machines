//! Ruby bindings for the `rogue-machines` fault injector.
//!
//! A plain mirror of the core: `RogueMachines::Rogue` wraps one `Rogue`, and
//! the `Data` values `Slot`, `Fraction`, `Draw`, `Delay`, `Experiment`,
//! `Inject`, `Replaced` and `Disarmed` (defined in Ruby, validated here) carry
//! the core's types. Time is Integer nanoseconds in and out. The process-wide
//! runtime (`RogueMachines.arm`, `RogueMachines.run`) is Ruby, on top of this.

mod init;
mod rogue;
mod values;

use magnus::{Error, RModule, Ruby, prelude::*};

pub(crate) fn define_errors(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let base = module.define_error("Error", ruby.exception_standard_error())?;
    module.define_error("Injected", base)?;
    Ok(())
}
