# rogue-machines

Fault injection: making a dependency fail, stall or lie on purpose.

A `Rogue` holds the experiments a process is running and answers one question
per call: inject a fault, or pass. Nothing here performs a fault. The caller
raises, sleeps and substitutes, and supplies both the clock and the draw.

Zero dependencies, integer arithmetic only, and builds `no_std` for a
microcontroller or for wasm under `--no-default-features`. The default feature
is `std`, because the Ruby binding needs it.

## Disarmed is the default

A process that has armed nothing answers every call the same way, reading one
word to do it.

```rust
use rogue_machines::{Decision, Rogue, Slot};

let rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };

assert!(!rogue.any_armed());
assert_eq!(rogue.decide(slot, 0, 0), Decision::Pass);
```

## Arming one

An experiment is a fault, the share of calls it reaches, and the reading it
expires at. There is no constructor without the expiry.

```rust
use rogue_machines::{Decision, Experiment, Fault, Fraction, Rogue, Slot};

const SECOND: u64 = 1_000_000_000;

let mut rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };
let Some(tenth) = Fraction::new(100_000) else { unreachable!() };

rogue.arm(slot, Experiment::new(Fault::Raise, tenth, 60 * SECOND));

// The draw decides which calls it reaches, and the caller supplies it.
assert_eq!(rogue.decide(slot, SECOND, 0), Decision::Inject(Fault::Raise));
assert_eq!(rogue.decide(slot, SECOND, 500_000), Decision::Pass);
```

A share is in millionths of `PER_MILLION` and half open at its own boundary:
`Fraction::new(100_000)` covers draws 0 to 99_999. It is a threshold measured
from zero, not an interval, so two shares overlap rather than partition the
draw space and one draw cannot be split between two experiments.

## It cannot outlive its expiry

A share is given in integer millionths and nothing is rounded here: rejecting
a share too small to express is the binding's job, since only it converts from
a fraction. `Fraction::new(0)` is a share that reaches nothing, same as
`Fraction::NONE`.

An expiry is observed, not scheduled. The first decision taken at or after the
expiry retires the experiment, and once retired a clock that steps backwards
cannot bring it back. Nothing retires it before that reading is taken.

```rust
use rogue_machines::{Decision, Experiment, Fault, Fraction, Rogue, Slot};

let mut rogue = Rogue::new();
let Some(slot) = Slot::new(0) else { unreachable!() };
rogue.arm(slot, Experiment::new(Fault::Garble, Fraction::ALL, 100));

assert_eq!(rogue.decide(slot, 99, 0), Decision::Inject(Fault::Garble));
assert_eq!(rogue.decide(slot, 100, 0), Decision::Pass);
assert!(!rogue.any_armed());
assert_eq!(rogue.decide(slot, 0, 0), Decision::Pass);
```

## The three faults

| Fault | What the caller does |
|:--|:--|
| `Raise` | Fails. |
| `Delay { ns }` | Waits that long, then makes the real call. |
| `Garble` | Succeeds, with a substitute value. |

There is no fault that blocks forever. A dependency that times out is a
`Delay` longer than the caller's own budget, which leaves the caller's timeout
in charge of when it gives up. The core counts nanoseconds and sets no ceiling;
the Ruby binding caps a delay at five minutes so a caller with no deadline
cannot be stalled indefinitely by a mistyped one.

## What it is not

- It is not a breaker, a limiter, a retry or a budget. It trips those; it does
  not contain them.
- It does not read a clock. Every reading is a `u64` of nanoseconds the caller
  passes in, which is why the crate builds for a microcontroller.
- It does not generate randomness. The draw is the caller's, so a test can
  replay an exact sequence.
- There is no reading that means "never expire". `Experiment::spent` is
  `now_ns >= expires_at_ns`, so even `u64::MAX` expires at `u64::MAX`.
- An expiry is only meaningful against the clock it was computed on, and
  nothing here infers which clock a reading came from. With several threads
  each taking their own reading, a reading older than the arming is ordinary
  interleaving rather than evidence of anything, and treating it as evidence
  retires experiments that were just armed. Deciding that a reading belongs to
  a different clock is the caller's job, not this crate's.

## License

MIT
