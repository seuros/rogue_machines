# rogue-machines

Fault injection: making a dependency fail, stall or lie on purpose.

A `Rogue` holds the experiments a process is running and answers one question
per call: inject a fault, or pass. Nothing here performs a fault. The caller
raises, sleeps and substitutes, and supplies both the clock and the draw.

Zero dependencies, integer arithmetic only, plain `no_std` with no features:
the same crate builds for a microcontroller, for wasm and for the Ruby binding.

## Disarmed is the default

A process that has armed nothing answers every call the same way, reading one
word to do it.

```rust
use core::time::Duration;
use rogue_machines::{Decision, Draw, Rogue, Slot};

let rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };
let Some(draw) = Draw::new(0) else { unreachable!() };

assert!(!rogue.any_armed());
assert_eq!(rogue.decide(slot, Duration::ZERO, draw), Decision::Pass);
```

## Arming one

An experiment is a fault, the share of calls it reaches, and the instant it
expires at. There is no constructor without the expiry.

```rust
use core::time::Duration;
use rogue_machines::{Arming, Decision, Draw, Experiment, Fault, Fraction, Rogue, Slot};

let second = Duration::from_secs(1);
let mut rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };
let Some(tenth) = Fraction::new(100_000) else { unreachable!() };
let (Some(low), Some(high)) = (Draw::new(0), Draw::new(500_000)) else { unreachable!() };

let experiment = Experiment::new(Fault::Raise, tenth, 60 * second);
assert_eq!(rogue.arm(slot, experiment), Arming::Armed);
// The identical experiment again is an honoured repeat that changes nothing.
assert_eq!(rogue.arm(slot, experiment), Arming::AlreadyArmed);

// The draw decides which calls it reaches, and the caller supplies it.
assert_eq!(rogue.decide(slot, second, low), Decision::Inject(Fault::Raise));
assert_eq!(rogue.decide(slot, second, high), Decision::Pass);
```

A share is in millionths of `PER_MILLION` and half open at its own boundary:
`Fraction::new(100_000)` covers draws 0 to 99_999. It is a threshold measured
from zero, not an interval, so two shares overlap rather than partition the
draw space and one draw cannot be split between two experiments.

A share is given in integer millionths and nothing is rounded here: rejecting
a share too small to express is the binding's job, since only it converts from
a fraction. `Fraction::new(0)` is a share that reaches nothing, same as
`Fraction::NONE`. A `Draw` is always below `PER_MILLION`; `Draw::new` answers
`None` for anything else, so a draw no share covers cannot reach a decision.

## It cannot outlive its expiry

Expiry is judged, not applied. `active`, `decide` and `live_count` compare the
experiment's expiry with the instant they are given and change nothing: an
expired experiment injects nothing, but keeps its slot, and `any_armed` keeps
answering `true` for it. `sweep(now)` is the one call that empties the slots of
experiments expired by `now`; once swept, a clock that steps backwards cannot
bring one back. A query records nothing, so an earlier instant passed to a
query before any sweep still finds the experiment live.

```rust
use core::time::Duration;
use rogue_machines::{Arming, Decision, Draw, Experiment, Fault, Fraction, Rogue, Slot};

let at = Duration::from_nanos;
let mut rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };
let Some(draw) = Draw::new(0) else { unreachable!() };
let garble = Experiment::new(Fault::Garble, Fraction::ALL, at(100));
assert_eq!(rogue.arm(slot, garble), Arming::Armed);

assert_eq!(rogue.decide(slot, at(99), draw), Decision::Inject(Fault::Garble));
assert_eq!(rogue.decide(slot, at(100), draw), Decision::Pass);
assert!(rogue.any_armed());

assert_eq!(rogue.sweep(at(100)), 1);
assert!(!rogue.any_armed());
assert_eq!(rogue.decide(slot, at(0), draw), Decision::Pass);
```

## Contract

- **No refusals.** Nothing here can refuse, so there is no `Refusal`. A `Slot`
  is the caller's own number in `0..EXPERIMENTS`, not an issued handle: the
  core issues no ids, and arming any slot is always honoured.
- **Answers say what held before.** `arm` answers `Armed` (the slot was empty),
  `Replaced(previous)` (it held another experiment, expired or not, which is
  now gone) or `AlreadyArmed`. `disarm` answers `Disarmed(previous)` or
  `NotArmed`. `disarm_all` and `sweep` answer how many slots they emptied.
- **Honoured repeats.** Re-arming a slot with the identical experiment
  (`AlreadyArmed`) and disarming an empty slot (`NotArmed`) are provable from
  the slot itself, so they are honoured and change nothing; so are
  `disarm_all` and `sweep` answering zero.
- **Queries are pure.** Every `&self` method is a function of the state and
  the instant it is given. Only `arm`, `disarm`, `disarm_all` and `sweep`
  change anything.
- **Time** is `core::time::Duration` since an epoch the caller picks, for the
  expiry, the delay and every `now`. The core keeps no clock and no call
  records one, so there is no regression to detect: an instant earlier than a
  previous one is answered against the state as it stands. Expiry is half
  open: `spent(now)` is `now >= expires_at`, and there is no instant meaning
  "never" (`Duration::MAX` expires at `Duration::MAX`).
- **Restarts.** A fresh `Rogue` is empty; nothing is issued, so nothing needs
  resuming.

## Every answer

No answer records the clock: the core keeps none.

| Call | Answers |
|:--|:--|
| `Slot::new(index)` | `Some(Slot)`, or `None` at or above `EXPERIMENTS` |
| `Fraction::new(millionths)` | `Some(Fraction)`, or `None` above `PER_MILLION` |
| `Draw::new(millionths)` | `Some(Draw)`, or `None` at or above `PER_MILLION` |
| `Experiment::new(fault, fraction, expires_at)` | always an `Experiment` |
| `arm(slot, experiment)` | `Armed`, `Replaced(previous)`, `AlreadyArmed` (unchanged) |
| `disarm(slot)` | `Disarmed(previous)`, `NotArmed` (unchanged) |
| `disarm_all()` | slots emptied, expired or not; `0` is unchanged |
| `sweep(now)` | slots emptied because expired by `now`; `0` is unchanged |
| `any_armed()` | whether any slot holds an experiment, expired or not |
| `armed_count()` | slots holding an experiment, expired or not |
| `live_count(now)` | slots holding an experiment live at `now` |
| `vacant()` | the lowest empty slot, or `None` when all are held |
| `experiment(slot)` | what `slot` holds, expired or not, or `None` |
| `active(slot, now)` | what `slot` holds if live at `now`, or `None` |
| `decide(slot, now, draw)` | `Inject(fault)` when live and the share covers `draw`, else `Pass` |

## The three faults

| Fault | What the caller does |
|:--|:--|
| `Raise` | Fails. |
| `Delay(duration)` | Waits that long, then makes the real call. |
| `Garble` | Succeeds, with a substitute value. |

There is no fault that blocks forever. A dependency that times out is a
`Delay` longer than the caller's own budget, which leaves the caller's timeout
in charge of when it gives up. The core sets no ceiling; the Ruby runtime caps
a delay at five minutes so a caller with no deadline cannot be stalled
indefinitely by a mistyped one.

## What it is not

- It is not a breaker, a limiter, a retry or a budget. It trips those; it does
  not contain them.
- It does not read a clock. Every instant is a `Duration` the caller passes
  in, which is why the crate builds for a microcontroller.
- It does not generate randomness. The draw is the caller's, so a test can
  replay an exact sequence.
- An expiry is only meaningful against the clock it was computed on, and
  nothing here infers which clock an instant came from. With several threads
  each taking their own reading, an instant older than the arming is ordinary
  interleaving rather than evidence of anything. Deciding that a reading
  belongs to a different clock is the caller's job, not this crate's.

## License

MIT
