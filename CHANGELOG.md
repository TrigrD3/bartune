# Changelog

## [0.4.0](https://github.com/TrigrD3/bartune/compare/v0.3.0...v0.4.0) (2026-11-21)


### Features

* **app:** add confirmation dialog to Clear Cache button in Settings ([91096fb](https://github.com/TrigrD3/bartune/commit/91096fbf8661e88f581535b0e8793464f34794a3))
* **app:** confirm per-song cache deletion and enforce destructive-action rule ([9f00444](https://github.com/TrigrD3/bartune/commit/9f004443df990a429e600d903e594f4da9bf9487))
* **app:** expand Appearance settings with live preview, highlight palettes, glow, and corner radius ([#44](https://github.com/TrigrD3/bartune/issues/44)) ([d4f2953](https://github.com/TrigrD3/bartune/commit/d4f29532865b6b94b4754d1e6200c8b9bd2d2b93))


### Bug Fixes

* **app:** address CodeRabbit boundary and fallback monotonicity findings ([ef59faa](https://github.com/TrigrD3/bartune/commit/ef59faaa8419c061ae83ded1f81985b7918eb3c4))
* **app:** address CodeRabbit findings on PR 41 ([d134c9d](https://github.com/TrigrD3/bartune/commit/d134c9d707ceef3688946910556e1e66a7c20af1))
* **app:** clamp fallback line start against previousLineEnd ([60f36fc](https://github.com/TrigrD3/bartune/commit/60f36fc34a133b4cdc614ad1961eb2f3abd68576))
* **app:** guard median offset, validate cached sync quality, add Whisper model picker, and fix marquee width ([#42](https://github.com/TrigrD3/bartune/issues/42)) ([4d25733](https://github.com/TrigrD3/bartune/commit/4d25733e14b694fef6f53363559f61290f17c9fc))
* **app:** isolate player audio via excludingApplications, compact green Synced checkmark, and continuous 30fps marquee ([4deb882](https://github.com/TrigrD3/bartune/commit/4deb88203ffcad250d7746a2de6f2d19be2e43a4))
* **app:** prevent cross-line word bleed and overlapping line timestamps in audio aligner ([372cb97](https://github.com/TrigrD3/bartune/commit/372cb9778805daadf358d70a0d5dc6220f4d9490))
* **app:** refresh cache counts immediately before showing Clear Cache alert ([8dc97be](https://github.com/TrigrD3/bartune/commit/8dc97bea230f3677eae6c0420c57283ee2bdb081))
* **app:** run Clear Cache disk deletion off the main thread ([f5ff607](https://github.com/TrigrD3/bartune/commit/f5ff6074d1459588816f41a0d1fbb203586965d3))
* **app:** serialize SystemAudioCapture lifecycle on MainActor ([d6b1688](https://github.com/TrigrD3/bartune/commit/d6b168862e367403cc1d19756c31a054c3631b1f))
* **app:** track max transcript word end, post-floor emitted end, and fallback line end ([72c214c](https://github.com/TrigrD3/bartune/commit/72c214c61200de4aca0e19b8706b8fb8bd3f7e4b))
* **ci:** grant contents:write to publish-release-assets caller job ([#47](https://github.com/TrigrD3/bartune/issues/47)) ([7549119](https://github.com/TrigrD3/bartune/commit/75491196b702ea6905a980e83d77ea9bda0b9609))


### Documentation

* **docs:** add release, security, and CodeRabbit badges to README ([f96471e](https://github.com/TrigrD3/bartune/commit/f96471e891da3768d8998de9ebf745dc52be2182))
