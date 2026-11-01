//! The frozen `Data` object a decision hands back when it injects.

use std::sync::OnceLock;

use magnus::value::Opaque;
use magnus::{Error, RClass, RModule, RStruct, Ruby, Value, prelude::*};
use rogue_machines::Fault;

use crate::error;

static INJECTION: OnceLock<Opaque<RClass>> = OnceLock::new();

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let injection = ruby.define_data(None, ("fault", "delay_ns"))?;
    module.const_set("Injection", injection)?;
    INJECTION
        .set(injection.into())
        .map_err(|_| error(ruby, "Injection was defined twice".to_owned()))
}

/// The fault to perform, and how long to wait when it is a delay.
pub fn injection(ruby: &Ruby, fault: Fault) -> Result<Value, Error> {
    let class = INJECTION
        .get()
        .map(|class| ruby.get_inner(*class))
        .ok_or_else(|| error(ruby, "Injection was not defined".to_owned()))?;
    let instance = RStruct::try_convert(class.obj_alloc()?)?;
    let (name, delay_ns) = match fault {
        Fault::Raise => ("raise", 0),
        Fault::Delay { ns } => ("delay", ns),
        Fault::Garble => ("garble", 0),
    };
    for (index, member) in [
        ruby.into_value(ruby.to_symbol(name)),
        ruby.into_value(delay_ns),
    ]
    .into_iter()
    .enumerate()
    {
        instance.aset(index, member)?;
    }
    instance.freeze();
    Ok(instance.as_value())
}
