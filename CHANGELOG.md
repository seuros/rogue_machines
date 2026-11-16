# Changelog

## [0.5.0](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.4.0...rogue_machines/v0.5.0) (2026-11-16)


### ⚠ BREAKING CHANGES

* carry the runtime's garbled substitute in Replaced and Disarmed

### Features

* carry the runtime's garbled substitute in Replaced and Disarmed ([acece66](https://github.com/seuros/rogue_machines/commit/acece668aa14809616fc90c3eb7f2c9665325dad))


### Bug Fixes

* fix wrapped classes at load so building a value runs no Ruby ([39982ca](https://github.com/seuros/rogue_machines/commit/39982cace4de937ec30e83b9da15be38b0ed46b3))

## [0.4.0](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.3.1...rogue_machines/v0.4.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* adopt matryona 0.4 symbol_or_fields for faults, naming what was received

### Features

* adopt matryona 0.4 symbol_or_fields for faults, naming what was received ([29d07fe](https://github.com/seuros/rogue_machines/commit/29d07fe671cf3f00c8ff284f3a03dcaab0f0176e))

## [0.3.1](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.3.0...rogue_machines/v0.3.1) (2026-11-14)


### Bug Fixes

* **deps:** require matryona-machines &gt;= 0.3 ([b92985b](https://github.com/seuros/rogue_machines/commit/b92985b2ee76787772e6d6c1e5deeffa1a039d89))

## [0.3.0](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.2.0...rogue_machines/v0.3.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* adopt matryona-machines 0.2: struct-only field reads, caret rb-sys, missing_docs

### Features

* adopt matryona-machines 0.2: struct-only field reads, caret rb-sys, missing_docs ([af562d6](https://github.com/seuros/rogue_machines/commit/af562d60cde84679fc6b8bce9eedb4af3559a0b4))

## [0.2.0](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.1.3...rogue_machines/v0.2.0) (2026-11-14)


### ⚠ BREAKING CHANGES

* mirror the core Rogue with sealed validated values, garbled replacement answers Replaced, runtime hands out a frozen copy

### Features

* mirror the core Rogue with sealed validated values, garbled replacement answers Replaced, runtime hands out a frozen copy ([e805ae4](https://github.com/seuros/rogue_machines/commit/e805ae4792f25f5aeaa24b165192c14b80362067))

## [0.1.3](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.1.2...rogue_machines/v0.1.3) (2026-11-06)


### Bug Fixes

* extract arg_error and range error helpers in ffi ([ee6ccf4](https://github.com/seuros/rogue_machines/commit/ee6ccf4ef0caef9f5ef7b4496ee0ccdb633ddc1e))
* keep test modules out of the packaged crate ([425cf81](https://github.com/seuros/rogue_machines/commit/425cf81b4e94ea2abd8de21ec74426c71338c11c))

## [0.1.2](https://github.com/seuros/rogue_machines/compare/rogue_machines/v0.1.1...rogue_machines/v0.1.2) (2026-11-01)


### Bug Fixes

* a republished platform gem is skipped, not fatal ([1190768](https://github.com/seuros/rogue_machines/commit/119076835e9e41d77fee67e40e0cc1646a8f9354))
* enable the rb-sys compiled fallback so new Rubies can build ([c36ad72](https://github.com/seuros/rogue_machines/commit/c36ad72c622ee5c3b526776351968e18df83c722))

## [0.1.1](https://github.com/seuros/rogue_machines/compare/rogue_machines-v0.1.0...rogue_machines/v0.1.1) (2026-11-01)


### Features

* fault injection, disarmed by default, with an expiry it cannot outlive ([e6cfe89](https://github.com/seuros/rogue_machines/commit/e6cfe8999947dbfb048eaf15a13cb2d4dbb03943))
* pass a rubygems OTP through the environment ([4f60306](https://github.com/seuros/rogue_machines/commit/4f60306bf35aa8fc7336432c0cdd13b61004796b))


### Bug Fixes

* collect the built gems whatever depth the download puts them at ([a470d97](https://github.com/seuros/rogue_machines/commit/a470d97586dad75365425ff5fdde68a982863262))
* the release tag carries the gem name, and the gate uses the aggregate output ([1c980cd](https://github.com/seuros/rogue_machines/commit/1c980cd0a36bdce2913e1a74252f90987183f0f7))
