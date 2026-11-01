# RogueMachines 💥

> **Controlled sabotage for the fleet.** The ship that breaks your systems on
> purpose, so the void doesn't get to do it first.

Every other vessel in this fleet exists to survive a failure. None of them can
produce one. A breaker that has never opened, a retry budget that has never
been spent and a deadline that has never been hit are three untested claims
flying in formation. **AMS Gray** arms the failure that tests them.

---

## 🚀 Launch Sequence

```bash
# Add to your ship's Gemfile
gem 'rogue_machines'
```

Requires **Ruby 4.0+** and a Rust toolchain, or a platform gem.

---

## 🎯 Mission Brief

```ruby
require 'rogue_machines'

RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 300)

RogueMachines.run(:payments) do
  Payments.charge(order)
end
```

One call in a hundred now fails for the next five minutes, and the breaker
wrapped around it finally gets to prove it works.

---

## 🛡️ Safety Interlocks

**Weapons are cold until you arm them.** A process that has armed nothing
injects nothing, and `run` says so by validating the name and reading one word
through one native call.

```ruby
RogueMachines.armed?                                      # => false
RogueMachines.run(:payments) { Payments.charge(order) }   # the real call
```

It allocates nothing: zero objects per call for a Symbol, a String or a frozen
String name. The overhead is about 160 ns, most of it the name check rather
than the native read. That is why this ships as a runtime dependency rather
than a test-only one. The interlock sits on every call to every protected
dependency, so it has to be cheap enough to leave in.

Nothing is armed by loading the gem, by an environment variable or by a config
file. Arming is an explicit call naming a target and a share of traffic.

---

## ⏱️ Every Experiment Self-Destructs

`expires_in:` is **required**. There is no way to arm an experiment that
outlives the officer who armed it, and no constructor in the Rust core that
takes a fault without a reading it expires at.

```ruby
RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
RogueMachines.armed             # => [:payments]

# sixty seconds later, with nobody touching anything
RogueMachines.armed             # => []
RogueMachines.armed?            # => false
```

An expiry is **observed, not scheduled**: nothing retires an experiment until
something takes a reading. The first `run`, `armed` or `armed?` at or after the
expiry retires it, and once retired a clock that steps backwards cannot bring
it back.

An experiment lasts at most twenty-four hours. Past that it is configuration,
not an experiment, and it must be armed again deliberately.

---

## 💥 The Armory

```ruby
# Fail.
RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 300)

# Be slow, then make the real call.
RogueMachines.arm(:search, fault: :delay, delay: 2, share: 0.5, expires_in: 300)

# Succeed, with a substitute.
RogueMachines.arm(:catalogue, fault: :garble, garbled: [], share: 0.1, expires_in: 300)
```

A `:raise` raises `RogueMachines::Injected`. A `:garble` returns `garbled:`
without running the block, which defaults to `nil` so a forgotten substitute
cannot quietly return the real value.

**There is no weapon that holds a caller forever.** A dependency that times out
is a `:delay` longer than the caller's own budget, which leaves the caller's
timeout in charge of when it gives up. The delay is spent against the ambient
`deadline_machines` budget, so a stall inside a deadline trips that deadline
instead of sleeping past it. Because a deadline is opt-in per call site, a
delay is also capped at five minutes. That is not a substitute for a deadline;
it bounds what a mistyped argument can do to a caller that has none.

---

## 🎲 Targeting

`share:` is a fraction of calls between 0 and 1, and the draw deciding each
call comes from `RogueMachines.random`. Replace it to replay an exact run:

```ruby
RogueMachines.random = Random.new(1234)
```

A share is half open at its own boundary and expressed in millionths, so 0.0
reaches nothing and 1.0 reaches everything. It is a threshold from zero rather
than an interval: 0.1 and 0.9 both cover a low draw, so two experiments cannot
divide one stream of calls between them. A share below one millionth is
refused rather than armed as a silent no-op.

---

## 🕰️ The Ship's Chronometer

`RogueMachines.clock` delegates to `DeadlineMachines.clock`, so a test can
expire an experiment without sleeping:

```ruby
RogueMachines.clock = DeadlineMachines::TestClock.new
RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
RogueMachines.clock.advance(60)
RogueMachines.armed?            # => false
```

This is the one place `RogueMachines` consumes a primitive from the fleet
rather than tripping it.

**Install the chronometer through `RogueMachines.clock=`.** Doing so disarms
everything first, because every armed expiry was computed against the outgoing
clock and an expiry is only meaningful against the clock it came from.

It is safe to do under load. A reading is taken before any lock, so that a
caller's clock never runs inside one, which means a call can be part way
through when the clock is replaced. Each reading therefore carries the
generation it belongs to, and a call arriving with a superseded one is refused
rather than acted on: arming raises and nothing is armed, a decision makes the
real call, and a query reports nothing. A clock being replaced faster than a
reading can be taken is answered the same way rather than retried forever, and
a clock returning something that is not a non-negative Integer of nanoseconds
raises an error naming the clock.

Replacing `DeadlineMachines.clock` underneath is reflected, since the
delegation is not memoised, but it cannot disarm anything. A clock whose epoch
is lower than the old one then makes an armed experiment look as though its
expiry is still far away. Set `RogueMachines.clock` and the question does not
arise.

A reading is also taken before the lock when arming, so the expiry of a new
experiment is measured from slightly before it is armed. With a real monotonic
clock that is microseconds. Nothing infers that a reading came from a
different clock: with several threads taking their own readings, a reading
older than the arming is ordinary interleaving, and treating it as evidence of
a clock change retires experiments that were just armed.

---

## 🔩 The Native Extension Is Required

There is no pure-Ruby fallback and no switch to turn one on. `require
'rogue_machines'` loads the extension and fails if it is not there. The gem is
a binding to the `rogue-machines` crate in `ext/rogue_machines_native/core`,
which has zero dependencies and builds `no_std` for wasm and for a
microcontroller. The binding asks for its `std` feature, so the crate as this
gem consumes it is not `no_std`.

---

## 🚫 Rules of Engagement

- **No breaker, limiter, retry or budget.** It trips those. `breaker_machines`,
  `throttle_machines`, `chrono_machines` and `shed_machines` own them.
- **No clock of its own.** Every reading is nanoseconds the caller passes in,
  which is why the core builds for bare metal.
- **No randomness of its own.** The draw is the caller's.
- **No capacity beyond 32 experiments**, because the armed set is one 32-bit
  word and the interlock on the hot path is a single load of it.

---

## 📡 Credits

**AMS Gray**, NCC-0401, *Gray*-class raider.

Named for Jim Gray's *Why Do Computers Stop and What Can Be Done About It?*
(1985), which argued that the way to find out whether a system tolerates
faults is to give it some.

---

## License

MIT
