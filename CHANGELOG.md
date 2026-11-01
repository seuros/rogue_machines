# Changelog

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
