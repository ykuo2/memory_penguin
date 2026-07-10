# Project Instructions

## Version Records

- Update `CHANGELOG.md` in the same change as every user-facing feature,
  behavioral change, bug fix, safety improvement, deprecation, or removal.
- Add work-in-progress entries under `Unreleased`. When preparing a release,
  move those entries into a `MAJOR.MINOR.PATCH` section dated `YYYY-MM-DD`.
- Keep changelog entries concise and describe observable behavior rather than
  implementation trivia or routine generated build artifacts.
- Keep the release heading in `CHANGELOG.md` aligned with
  `CFBundleShortVersionString` in `Resources/Info.plist`.
- Record meaningful release verification, including the relevant tests and
  release build result.
