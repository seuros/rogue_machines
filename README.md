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

MINUTE = 60 * 1_000_000_000 # Integer nanoseconds, like every time in this gem

RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 5 * MINUTE)

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
String name. The overhead is a couple of hundred nanoseconds, most of it the
name check rather than the native read. That is why this ships as a runtime dependency rather
than a test-only one. The interlock sits on every call to every protected
dependency, so it has to be cheap enough to leave in.

Nothing is armed by loading the gem, by an environment variable or by a config
file. Arming is an explicit call naming a target and a share of traffic.

---

## ⏱️ Every Experiment Self-Destructs

`expires_in:` is **required**, in Integer nanoseconds. There is no way to arm
an experiment that outlives the officer who armed it, and no constructor in the
Rust core that takes a fault without an instant it expires at.

```ruby
RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
RogueMachines.armed             # => [:payments]

# sixty seconds later, with nobody touching anything
RogueMachines.armed             # => []
RogueMachines.armed?            # => false
```

An expiry is **judged, not scheduled**. An expired experiment injects nothing
from its expiry on, but the core only empties its slot when told to sweep. The
runtime sweeps under its lock whenever `run`, `armed`, `armed?` or `arm` takes
a reading, and once swept a clock that steps backwards cannot bring the
experiment back.

An experiment lasts at most twenty-four hours. Past that it is configuration,
not an experiment, and it must be armed again deliberately.

---

## 💥 The Armory

```ruby
# Fail.
RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 5 * MINUTE)

# Be slow (two seconds, in nanoseconds), then make the real call.
RogueMachines.arm(:search, fault: RogueMachines::Delay.new(2_000_000_000), share: 0.5,
                           expires_in: 5 * MINUTE)

# Succeed, with a substitute.
RogueMachines.arm(:catalogue, fault: :garble, garbled: [], share: 0.1, expires_in: 5 * MINUTE)
```

A `:raise` raises `RogueMachines::Injected`. A `:garble` returns `garbled:`
without running the block, which defaults to `nil` so a forgotten substitute
cannot quietly return the real value.

**There is no weapon that holds a caller forever.** A dependency that times out
is a `Delay` longer than the caller's own budget, which leaves the caller's
timeout in charge of when it gives up. The delay is spent against the ambient
`deadline_machines` budget, so a stall inside a deadline trips that deadline
instead of sleeping past it. Because a deadline is opt-in per call site, a
delay is also capped at five minutes. That is not a substitute for a deadline;
it bounds what a mistyped argument can do to a caller that has none.

---

## 🎲 Targeting

`share:` is a fraction of calls between 0 and 1 (or a `Fraction` of
millionths), and the draw deciding each call comes from `RogueMachines.random`. Replace it to replay an exact run:

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
RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
RogueMachines.clock.now_ns += MINUTE
RogueMachines.armed?            # => false
```

This is the one place `RogueMachines` consumes a primitive from the fleet
rather than tripping it.

**Install the chronometer through `RogueMachines.clock=`.** Doing so disarms
everything first, because every armed expiry was computed against the outgoing
clock and an expiry is only meaningful against the clock it came from.

It is safe to do under load. A reading is taken before the runtime's lock, so
that a caller's clock never runs inside it, which means a call can be part way
through when the clock is replaced. Once the lock is held, the call checks that
the clock it read is still the one installed; if not, the reading is not acted
on and is taken again, up to `READINGS` times. After that, arming raises
`RogueMachines::Error` and nothing is armed, a decision makes the real call,
and a query reports nothing. A clock returning something that is not an Integer
raises `TypeError` naming the clock, and a negative reading `RangeError`.
`disarm` and `disarm_all` take no reading at all.

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
a clock change retires experiments that were just armed. For the same reason a
reading held across a backwards step of the *same* clock sweeps against
expiries it predates; replace clocks through `RogueMachines.clock=`.

---

## 🔩 The Native Extension Is Required

There is no pure-Ruby fallback and no switch to turn one on. `require
'rogue_machines'` loads the extension and fails if it is not there. The gem is
a binding to the `rogue-machines` crate in `ext/rogue_machines_native/core`,
which has zero dependencies, no features, and is plain `no_std`: the crate the
gem consumes is the one that builds for wasm and for a microcontroller.

---

## 🪞 The Core, Mirrored

Under the runtime sits a plain mirror of the core: `RogueMachines::Rogue` and
the Data values `Slot`, `Fraction`, `Draw`, `Delay`, `Experiment`, `Inject`,
`Replaced` and `Disarmed`, positional like the Rust constructors, with Integer
nanoseconds and symbols for unit variants (`:raise`, `:garble`, `:pass`,
`:armed`, `:already_armed`, `:not_armed`).

```ruby
include RogueMachines

rogue = Rogue.new
slot = Slot.new(0)
experiment = Experiment.new(:raise, Fraction::ALL, 100)

rogue.arm(slot, experiment)                  # => :armed
rogue.arm(slot, experiment)                  # => :already_armed
rogue.decide(slot, 99, Draw.new(0))          # => #<data Inject fault=:raise>
rogue.decide(slot, 100, Draw.new(0))         # => :pass
rogue.any_armed?                             # => true: expired, still held
rogue.sweep(100)                             # => 1
rogue.disarm(slot)                           # => :not_armed
```

Every Data value validates through the core when it is built, by the gem or by
hand: `TypeError` for the wrong type, `RangeError` for a value the core's
constructor rejects (`Slot.new(32)`, `Fraction.new(1_000_001)`,
`Draw.new(1_000_000)`, `Delay.new(-1)`, `Experiment.new(:nope, ...)`).
The value classes, and `Rogue`, are sealed: subclassing one raises
`TypeError` and `allocate` is undefined. Sealing stops accidents, not
reflection (a named subclass's constant is bound before `inherited` raises,
and `Marshal.load` skips `initialize`), so the binding is the authority: every
value it reads must be an instance of exactly the gem's class (`TypeError`
otherwise, a subclass included) and is rebuilt through the core's constructors
(`RangeError` for a forged one), before the core sees it.

## 📜 Contract

- **Refusals.** The core has none: a `Slot` is the caller's own number, not an
  issued id, and every slot can always be armed. The runtime has one,
  `RogueMachines.arm` answering `:full` when every slot holds a live
  experiment under another name; it changes nothing and never raises.
- **Answers say what held before.** Arming answers `:armed`, a `Replaced`
  holding the experiment it displaced (expired or not), or `:already_armed`;
  disarming answers a `Disarmed` holding what was there, or `:not_armed`.
- **Honoured repeats.** Re-arming a slot with the identical experiment and
  disarming an empty slot are provable from the slot itself, so they are
  honoured and change nothing. In the runtime a `:garble` substitute is part
  of what is armed: `RogueMachines.arm` answers `:already_armed` only when the
  stored substitute is equal (`==`) too; a differing one replaces it and
  answers a `Replaced` holding the experiment, as a differing experiment
  does.
- **Queries are pure.** In the core and in `Rogue`, every query judges expiry
  against the instant it is given and changes nothing; only `sweep` empties
  expired slots. The runtime's `armed`, `armed?`, `run` and `arm` sweep on
  purpose, under the lock, with a reading against the installed clock.
- **Time** is Integer nanoseconds in and out: `expires_at`, `Delay#duration`,
  every `now`, `expires_in:`. Non-Integer is `TypeError`; negative or past
  `2**64 - 1` is `RangeError`.
- **Scopes and restarts.** Nothing is issued, so there is no scope. A fresh
  process starts disarmed.
- **Exceptions.** Malformed input raises `TypeError` or `RangeError` before
  anything changes. `Injected` is the fault itself; `Error` is a clock replaced
  faster than it can be read.
- **Never loses work.** `Rogue#arm` and `#disarm` answer with values built by
  Ruby, so each decides on a copy and keeps it only once the answer exists: a
  raise while building it (a redefined `new`) applies nothing, freezing the
  Rogue meanwhile raises `FrozenError` and changing it `RuntimeError`, with the
  outer call not applied. No call holds the Rogue while Ruby code runs, so a
  re-entrant call is an ordinary one, never a `fatal`.
- **The runtime's Rogue is not yours.** `RogueMachines.rogue` answers a frozen
  copy taken under the lock: changing the runtime's own Rogue behind the names
  would leave a name on an empty slot that the next arm hands to another name.
  `Rogue#dup` is an unfrozen copy to experiment on.

## Every answer

No answer records the clock: the core keeps none.

| Call | Honoured | Refused |
|:--|:--|:--|
| `Rogue#arm(slot, experiment)` | `:armed`, `Replaced`, `:already_armed` (unchanged) | never |
| `Rogue#disarm(slot)` | `Disarmed`, `:not_armed` (unchanged) | never |
| `Rogue#disarm_all` | slots emptied; `0` is unchanged | never |
| `Rogue#sweep(now)` | slots emptied because expired; `0` is unchanged | never |
| `Rogue#any_armed?` / `armed_count` | held slots, expired or not | query |
| `Rogue#live_count(now)` | slots live at `now` | query |
| `Rogue#vacant` | the lowest empty `Slot`, or `nil` | query |
| `Rogue#experiment(slot)` | what it holds, or `nil` | query |
| `Rogue#active(slot, now)` | what it holds if live at `now`, or `nil` | query |
| `Rogue#decide(slot, now, draw)` | `Inject`, `:pass` | query |
| `Rogue#dup` / `clone` | a copy holding the same experiments | query |
| `RogueMachines.rogue` | a frozen copy of the runtime's Rogue | query |
| `RogueMachines.arm(name, ...)` | `:armed`, `Replaced` (also for a new `garbled:`), `:already_armed` (unchanged) | `:full` (unchanged) |
| `RogueMachines.disarm(name)` | `Disarmed`, `:not_armed` (unchanged) | never |
| `RogueMachines.disarm_all` | experiments emptied; `0` is unchanged | never |
| `RogueMachines.armed` / `armed?` | names live now | never |
| `RogueMachines.run(name) { }` | the block's value, the substitute, or raises `Injected` | never |

---

## 🚫 Rules of Engagement

- **No breaker, limiter, retry or budget.** It trips those. `breaker_machines`,
  `throttle_machines`, `chrono_machines` and `shed_machines` own them.
- **No clock of its own.** Every instant is a `Duration` the caller passes in
  (Integer nanoseconds in Ruby), which is why the core builds for bare metal.
- **No randomness of its own.** The draw is the caller's.
- **No capacity beyond 32 experiments**, because the armed set is one 32-bit
  word and the interlock on the hot path is a single read of it.

---

## 📡 Credits

**AMS Gray**, NCC-0401, *Gray*-class raider.

Named for Jim Gray's *Why Do Computers Stop and What Can Be Done About It?*
(1985), which argued that the way to find out whether a system tolerates
faults is to give it some.

---

## License

MIT
