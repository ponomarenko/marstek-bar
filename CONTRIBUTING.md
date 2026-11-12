# Contributing to MarstekBar

Thanks for your interest. Bug reports, fixes and translations are welcome.

## Reporting a bug

Open an issue and include:

- battery model and firmware version (shown in the Marstek app),
- macOS version,
- what you expected and what you saw, with the error text from the app if there is one.

## Making a change

```sh
swift build                 # quick compile check
./scripts/build-app.sh      # build the .app bundle
open build/MarstekBar.app
```

- Keep the app small: no third-party dependencies, no features that write to the battery
  without a discussion in an issue first.
- Keep polling gentle. The Local API becomes unstable under load, so do not add requests
  to the one-minute poll without a reason.
- User-facing text is English in the code. Add the Ukrainian translation to
  `Resources/uk.lproj/Localizable.strings` in the same pull request.
- Say in the pull request which battery model and firmware you tested on.

## Adding a language

Copy `Resources/uk.lproj` to `Resources/<code>.lproj` and translate the values. The keys
are the English strings used in the code.
