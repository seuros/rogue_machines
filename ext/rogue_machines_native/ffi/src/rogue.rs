//! `RogueMachines::Rogue`: one core `Rogue`, method for method.
//!
//! Every mutating method converts and checks everything it was given, and
//! looks up every class it will build, before it calls the core. `arm` and
//! `disarm` answer with values built by Ruby (`Replaced`, `Disarmed`), so they
//! are clone-then-keep: the core decides on a copy, the answer is built, and
//! the copy is stored only if the Rogue is neither frozen (`FrozenError`) nor
//! changed (`RuntimeError`) meanwhile; a raise while building applies
//! nothing. No `RefCell` borrow is held while Ruby code runs: arguments are
//! converted first, the core value is copied out under a short borrow, and
//! only then is an answer built.

use std::cell::RefCell;

use magnus::typed_data::Obj;
use magnus::{Error, RModule, Ruby, Value, function, method, prelude::*};
use rogue_machines::{Arming, Decision, Disarming, Rogue};

use crate::values::{classes, draw, experiment, nanos, slot};

#[magnus::wrap(class = "RogueMachines::Rogue", free_immediately, size)]
struct Wrapper(RefCell<Rogue>);

/// Stores `after` once the answer for it exists, if the Rogue is still
/// unfrozen and still holds `before`.
fn keep(ruby: &Ruby, this: Obj<Wrapper>, before: &Rogue, after: Rogue) -> Result<(), Error> {
    this.check_frozen()?;
    let mut held = this.0.borrow_mut();
    if *held != *before {
        return Err(Error::new(
            ruby.exception_runtime_error(),
            "the rogue changed while the answer was built; the call was not applied",
        ));
    }
    *held = after;
    Ok(())
}

impl Wrapper {
    const fn new() -> Self {
        Self(RefCell::new(Rogue::new()))
    }

    /// An unfrozen copy holding the same experiments.
    fn dup(&self) -> Self {
        Self(RefCell::new(self.0.borrow().clone()))
    }

    /// `:armed`, a `Replaced` holding what the slot held, or `:already_armed`.
    fn arm(ruby: &Ruby, this: Obj<Self>, given_slot: Value, given: Value) -> Result<Value, Error> {
        let (slot, experiment) = (slot(ruby, given_slot)?, experiment(ruby, given)?);
        let classes = classes(ruby)?;
        this.check_frozen()?;
        let before = this.0.borrow().clone();
        let mut after = before.clone();
        let answer = match after.arm(slot, experiment) {
            Arming::Armed => ruby.to_symbol("armed").as_value(),
            Arming::Replaced(previous) => classes.replaced(ruby, previous)?,
            Arming::AlreadyArmed => ruby.to_symbol("already_armed").as_value(),
        };
        keep(ruby, this, &before, after)?;
        Ok(answer)
    }

    /// A `Disarmed` holding what the slot held, or `:not_armed`.
    fn disarm(ruby: &Ruby, this: Obj<Self>, given_slot: Value) -> Result<Value, Error> {
        let slot = slot(ruby, given_slot)?;
        let classes = classes(ruby)?;
        this.check_frozen()?;
        let before = this.0.borrow().clone();
        let mut after = before.clone();
        let answer = match after.disarm(slot) {
            Disarming::Disarmed(previous) => classes.disarmed(ruby, previous)?,
            Disarming::NotArmed => ruby.to_symbol("not_armed").as_value(),
        };
        keep(ruby, this, &before, after)?;
        Ok(answer)
    }

    fn disarm_all(this: Obj<Self>) -> Result<u32, Error> {
        this.check_frozen()?;
        Ok(this.0.borrow_mut().disarm_all())
    }

    fn sweep(ruby: &Ruby, this: Obj<Self>, now: Value) -> Result<u32, Error> {
        let now = nanos(ruby, "now", now)?;
        this.check_frozen()?;
        Ok(this.0.borrow_mut().sweep(now))
    }

    fn any_armed(&self) -> bool {
        self.0.borrow().any_armed()
    }

    fn armed_count(&self) -> u32 {
        self.0.borrow().armed_count()
    }

    fn live_count(ruby: &Ruby, this: &Self, now: Value) -> Result<u32, Error> {
        let now = nanos(ruby, "now", now)?;
        Ok(this.0.borrow().live_count(now))
    }

    fn vacant(ruby: &Ruby, this: &Self) -> Result<Option<Value>, Error> {
        let vacant = this.0.borrow().vacant();
        vacant
            .map(|slot| classes(ruby)?.slot(ruby, slot))
            .transpose()
    }

    fn experiment(ruby: &Ruby, this: &Self, given_slot: Value) -> Result<Option<Value>, Error> {
        let slot = slot(ruby, given_slot)?;
        let held = this.0.borrow().experiment(slot);
        held.map(|held| classes(ruby)?.experiment(ruby, held))
            .transpose()
    }

    fn active(
        ruby: &Ruby,
        this: &Self,
        given_slot: Value,
        now: Value,
    ) -> Result<Option<Value>, Error> {
        let (slot, now) = (slot(ruby, given_slot)?, nanos(ruby, "now", now)?);
        let live = this.0.borrow().active(slot, now);
        live.map(|live| classes(ruby)?.experiment(ruby, live))
            .transpose()
    }

    /// `:pass`, or an `Inject` naming the fault.
    fn decide(
        ruby: &Ruby,
        this: &Self,
        given_slot: Value,
        now: Value,
        given_draw: Value,
    ) -> Result<Value, Error> {
        let (slot, now) = (slot(ruby, given_slot)?, nanos(ruby, "now", now)?);
        let drawn = draw(ruby, given_draw)?;
        let decision = this.0.borrow().decide(slot, now, drawn);
        match decision {
            Decision::Pass => Ok(ruby.to_symbol("pass").as_value()),
            Decision::Inject(fault) => classes(ruby)?.inject(ruby, fault),
        }
    }

    fn inspect(&self) -> String {
        let rogue = self.0.borrow();
        format!(
            "#<RogueMachines::Rogue armed={} of {}>",
            rogue.armed_count(),
            rogue_machines::EXPERIMENTS
        )
    }
}

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let class = module.define_class("Rogue", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", function!(Wrapper::new, 0))?;
    class.define_method("dup", method!(Wrapper::dup, 0))?;
    class.define_method("arm", method!(Wrapper::arm, 2))?;
    class.define_method("disarm", method!(Wrapper::disarm, 1))?;
    class.define_method("disarm_all", method!(Wrapper::disarm_all, 0))?;
    class.define_method("sweep", method!(Wrapper::sweep, 1))?;
    class.define_method("any_armed?", method!(Wrapper::any_armed, 0))?;
    class.define_method("armed_count", method!(Wrapper::armed_count, 0))?;
    class.define_method("live_count", method!(Wrapper::live_count, 1))?;
    class.define_method("vacant", method!(Wrapper::vacant, 0))?;
    class.define_method("experiment", method!(Wrapper::experiment, 1))?;
    class.define_method("active", method!(Wrapper::active, 2))?;
    class.define_method("decide", method!(Wrapper::decide, 3))?;
    class.define_method("inspect", method!(Wrapper::inspect, 0))?;
    Ok(())
}
