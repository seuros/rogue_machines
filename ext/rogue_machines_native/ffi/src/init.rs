//! Private native entry point.
use magnus::{Error, Ruby, prelude::*};
use rogue_machines::PER_MILLION;

use crate::{define_errors, rogue, values};

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("RogueMachines")?;
    module.const_set("PER_MILLION", PER_MILLION)?;
    module.const_set("EXPERIMENTS", rogue_machines::EXPERIMENTS)?;
    define_errors(ruby, module)?;
    values::define(ruby, module)?;
    rogue::define(ruby, module)
}
