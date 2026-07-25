# Personal Repository Instructions

Before changing this repository, read
[`docs/personal-workflow.md`](docs/personal-workflow.md).

- `author/main` mirrors the original author's `upstream/main`. Keep personal
  signing, fixes, and experiments out of it.
- `personal/stable` is the user's build and test branch. Put personal fixes
  here and preserve its signing configuration.
- The personal app uses Apple Team `CHK3SLQ5JM` and Bundle ID
  `com.sunyiting.mimiremote`.
- `ios/MimiRemote/project.yml` is the source of truth for generated Xcode
  signing and Bundle ID settings.
- Xcode may mark unchanged localization entries as `extractionState: stale`
  after a build. Do not commit that mechanical churn unless localization
  behavior was intentionally changed.
