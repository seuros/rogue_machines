//! `RogueMachines::Rogue`: the experiments a process is running, by name.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use magnus::scan_args::{get_kwargs, scan_args};
use magnus::{Error, RArray, RHash, RModule, Ruby, Value, function, method, prelude::*};
use rogue_machines::{Decision, EXPERIMENTS, Experiment, Fault, Rogue, Slot};

use crate::injection::injection;
use crate::{LONGEST_DELAY, LONGEST_EXPERIMENT, counted, draw, duration, error, reading, share};

/// The core registry, and the names standing in for its slot indices.
#[magnus::wrap(class = "RogueMachines::Rogue", free_immediately, size)]
struct Wrapper {
    rogue: RefCell<Rogue>,
    slots: RefCell<HashMap<String, Slot>>,
    /// Which clock the armed expiries were computed against.
    ///
    /// Every reading is only meaningful for one of these. A caller samples a
    /// reading before it synchronises, so a reading that arrives after the
    /// clock was replaced would otherwise be compared against expiries it has
    /// no relation to, and `sweep` is destructive.
    generation: Cell<u32>,
}

impl Wrapper {
    fn new() -> Self {
        Self {
            rogue: RefCell::new(Rogue::new()),
            slots: RefCell::new(HashMap::new()),
            generation: Cell::new(0),
        }
    }

    /// Whether any experiment is armed, which is the whole of the decision a
    /// disarmed process takes.
    fn any_armed(&self) -> bool {
        self.rogue.borrow().any_armed()
    }

    const fn generation(&self) -> u32 {
        self.generation.get()
    }

    /// Disarms everything and starts a generation, so readings taken against
    /// the outgoing clock are refused rather than acted on.
    fn invalidate(&self) -> u32 {
        self.slots.borrow_mut().clear();
        self.rogue.borrow_mut().disarm_all();
        let next = self.generation.get().wrapping_add(1);
        self.generation.set(next);
        next
    }

    const fn current(&self, generation: u32) -> bool {
        self.generation.get() == generation
    }

    fn armed_count(
        ruby: &Ruby,
        rb_self: &Self,
        given_now: Value,
        given_age: Value,
    ) -> Result<u32, Error> {
        let generation = counted(ruby, "generation", given_age)?;
        if !rb_self.current(generation) {
            return Ok(0);
        }
        let now_ns = reading(ruby, "now_ns", given_now)?;
        let rogue = rb_self.rogue.borrow();
        rogue.sweep(now_ns);
        Ok(rogue.armed_count())
    }

    /// Arms `name`, replacing any experiment already under it.
    ///
    /// `fault:` is `:raise`, `:delay` or `:garble`, `share:` is the fraction of
    /// calls it reaches, and `expires_in:` is how long it runs for from
    /// `now_ns:`. A `:delay` also takes `delay:`, in seconds.
    fn arm(ruby: &Ruby, rb_self: &Self, args: &[Value]) -> Result<(), Error> {
        let args = scan_args::<(String,), (), (), (), RHash, ()>(args)?;
        let (name,) = args.required;
        let keywords = get_kwargs::<_, (String, f64, f64, Value, Value), (Option<f64>,), ()>(
            args.keywords,
            &["fault", "share", "expires_in", "now_ns", "generation"],
            &["delay"],
        )?;
        let (named, given_share, expires_in, given_now, given_age) = keywords.required;
        let generation = counted(ruby, "generation", given_age)?;
        if !rb_self.current(generation) {
            return Err(error(
                ruby,
                "the clock was replaced while arming; nothing was armed".to_owned(),
            ));
        }
        let now_ns = reading(ruby, "now_ns", given_now)?;
        let (delay,) = keywords.optional;

        let expires_at_ns = now_ns
            .checked_add(duration(
                ruby,
                "expires_in",
                expires_in,
                LONGEST_EXPERIMENT,
            )?)
            .ok_or_else(|| {
                Error::new(
                    ruby.exception_arg_error(),
                    "expires_in puts the expiry past the end of the clock",
                )
            })?;
        let fraction = share(ruby, given_share)?;
        let fault = fault(ruby, &named, delay)?;
        let slot = rb_self.slot_for(ruby, name, now_ns)?;

        rb_self
            .rogue
            .borrow_mut()
            .arm(slot, Experiment::new(fault, fraction, expires_at_ns));
        Ok(())
    }

    /// Disarms `name`, freeing its slot. Reports whether it was still running,
    /// which an experiment that expired on its own is not.
    fn disarm(
        ruby: &Ruby,
        rb_self: &Self,
        name: String,
        given_now: Value,
        given_age: Value,
    ) -> Result<bool, Error> {
        let generation = counted(ruby, "generation", given_age)?;
        if !rb_self.current(generation) {
            return Ok(false);
        }
        let now_ns = reading(ruby, "now_ns", given_now)?;
        let Some(slot) = rb_self.slots.borrow_mut().remove(&name) else {
            return Ok(false);
        };
        let was_running = rb_self.rogue.borrow().active(slot, now_ns).is_some();
        rb_self.rogue.borrow_mut().disarm(slot);
        Ok(was_running)
    }

    fn disarm_all(&self) {
        self.slots.borrow_mut().clear();
        self.rogue.borrow_mut().disarm_all();
    }

    /// The names still running at `now_ns`, in no particular order.
    fn armed(
        ruby: &Ruby,
        rb_self: &Self,
        given_now: Value,
        given_age: Value,
    ) -> Result<RArray, Error> {
        let generation = counted(ruby, "generation", given_age)?;
        if !rb_self.current(generation) {
            return Ok(ruby.ary_new());
        }
        let now_ns = reading(ruby, "now_ns", given_now)?;
        let running: Vec<String> = {
            let rogue = rb_self.rogue.borrow();
            rb_self
                .slots
                .borrow()
                .iter()
                .filter(|(_, slot)| rogue.active(**slot, now_ns).is_some())
                .map(|(name, _)| name.clone())
                .collect()
        };
        Ok(ruby.ary_from_iter(running))
    }

    /// The fault to perform for one call, or `nil` to make the real one.
    ///
    /// `draw` is the caller's, below `PER_MILLION`, and decides which calls an
    /// experiment reaches.
    fn decide(
        ruby: &Ruby,
        rb_self: &Self,
        name: String,
        given_now: Value,
        given_draw: Value,
        given_age: Value,
    ) -> Result<Option<Value>, Error> {
        let generation = counted(ruby, "generation", given_age)?;
        if !rb_self.current(generation) {
            return Ok(None);
        }
        let now_ns = reading(ruby, "now_ns", given_now)?;
        let drawn = draw(ruby, given_draw)?;
        let decision = {
            let rogue = rb_self.rogue.borrow();
            if !rogue.any_armed() {
                return Ok(None);
            }
            rogue.sweep(now_ns);
            let Some(slot) = rb_self.slots.borrow().get(&name).copied() else {
                return Ok(None);
            };
            rogue.decide(slot, now_ns, drawn)
        };
        match decision {
            Decision::Pass => Ok(None),
            Decision::Inject(fault) => injection(ruby, fault).map(Some),
        }
    }

    /// The slot already standing for `name`, or the lowest free one.
    ///
    /// An expired experiment releases its bit in the core but not its name, so
    /// the names of everything no longer armed are dropped first; otherwise a
    /// run of short experiments exhausts the slots.
    fn slot_for(&self, ruby: &Ruby, name: String, now_ns: u64) -> Result<Slot, Error> {
        let existing = {
            let rogue = self.rogue.borrow();
            let mut slots = self.slots.borrow_mut();
            slots.retain(|held, slot| *held == name || rogue.active(*slot, now_ns).is_some());
            slots.get(&name).copied()
        };
        if let Some(slot) = existing {
            return Ok(slot);
        }
        let mut slots = self.slots.borrow_mut();
        let taken: Vec<usize> = slots.values().map(|slot| slot.index()).collect();
        let free = (0..EXPERIMENTS)
            .find(|index| !taken.contains(index))
            .and_then(Slot::new)
            .ok_or_else(|| {
                error(
                    ruby,
                    format!("all {EXPERIMENTS} experiment slots are taken; disarm one first"),
                )
            })?;
        slots.insert(name, free);
        Ok(free)
    }

    /// Reports the mask as it stood at the last decision, since `inspect`
    /// takes no reading and so cannot retire an expired experiment itself.
    fn inspect(&self) -> String {
        format!(
            "#<RogueMachines::Rogue armed={} of {EXPERIMENTS} at the last decision>",
            self.rogue.borrow().armed_count()
        )
    }
}

/// The fault a `fault:` keyword names.
fn fault(ruby: &Ruby, named: &str, delay: Option<f64>) -> Result<Fault, Error> {
    match named {
        "raise" => Ok(Fault::Raise),
        "garble" => Ok(Fault::Garble),
        "delay" => {
            let seconds = delay.ok_or_else(|| {
                Error::new(
                    ruby.exception_arg_error(),
                    "a :delay fault needs delay: in seconds",
                )
            })?;
            Ok(Fault::Delay {
                ns: duration(ruby, "delay", seconds, LONGEST_DELAY)?,
            })
        }
        other => Err(Error::new(
            ruby.exception_arg_error(),
            format!("fault must be :raise, :delay or :garble, got {other:?}"),
        )),
    }
}

pub fn define(ruby: &Ruby, module: RModule) -> Result<(), Error> {
    let class = module.define_class("Rogue", ruby.class_object())?;
    class.define_singleton_method("new", function!(Wrapper::new, 0))?;
    class.define_method("any_armed?", method!(Wrapper::any_armed, 0))?;
    class.define_method("armed_count", method!(Wrapper::armed_count, 2))?;
    class.define_method("arm", method!(Wrapper::arm, -1))?;
    class.define_method("disarm", method!(Wrapper::disarm, 3))?;
    class.define_method("disarm_all", method!(Wrapper::disarm_all, 0))?;
    class.define_method("generation", method!(Wrapper::generation, 0))?;
    class.define_method("invalidate", method!(Wrapper::invalidate, 0))?;
    class.define_method("armed", method!(Wrapper::armed, 2))?;
    class.define_method("decide", method!(Wrapper::decide, 4))?;
    class.define_method("inspect", method!(Wrapper::inspect, 0))?;
    Ok(())
}
