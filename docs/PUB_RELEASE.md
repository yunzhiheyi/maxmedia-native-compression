# pub.dev release checklist (0.1.0)

Publish the three packages, not `apps/route_lab` or `tools/route_bench`.
Version 0.1.0 describes a limited initial plugin API; it is not a promise of
production coverage for every format, device, or HDR source.

## Current gate (2026-09-24)

The three dry runs report zero warnings. The contract package is clean; each
plugin reports one local `pubspec_overrides.yaml` hint, which must disappear
when it resolves the published contract before upload. Dart analysis, unit
tests, API documentation generation, 14 Android real-device integration tests,
30 macOS native integration tests, and 30 iOS simulator integration tests pass.
The new default color guards have been exercised with a tagged HLG/Main10 video
and Display P3 image on Android 13, macOS, and the iOS simulator, including
when an older native request omits the HDR policy: HDR output is refused before
encoding and the input is unchanged; Apple WebP refuses the P3 profile while
ImageIO JPEG retains it;
the tested Android WebP output retains an ICC chunk. These checks do not prove
perceptual equivalence for all lossy outputs or all codecs and devices.

iPhone physical-device integration tests are still **unverified**: the iOS debug
build and install succeed, but the Flutter debug service WebSocket resets before any
assertion, including after unlocking and reconnecting the phone. An iOS
release build compiled successfully; prior release install and launch confirm
packaging and startup, not the new color guards' behavior on iPhone.
The available iPad is wirelessly tethered and this Flutter test command cannot
start it without a published port. This is a test-transport failure, not
evidence that iOS compression passed or failed. Resolve the device connection
and rerun iOS image/video integration before claiming full platform sign-off.

## Package order

1. `packages/media_route_contracts` — shared Dart models, no native code.
2. `plugins/maxmedia_image_native` — depends on hosted `media_route_contracts: ^0.1.0`.
3. `plugins/maxmedia_video_native` — same hosted dependency.

The plugin pubspecs intentionally use a hosted dependency. For local checkout
development, run `bash tools/setup_local_pub_overrides.sh` from the repository
root; this writes ignored `pubspec_overrides.yaml` files for plugins and their
examples. Route Lab has its own local dependency override and plugin path
dependencies because it is an unpublished application.

## Before the first upload

- The user confirmed `MaxMedia contributors` as the intended BSD-3-Clause
  copyright notice. Confirm rights to release all plugin source.
- Review the Apple `libwebp` dependency and the resulting app's third-party
  notices. The plugin's BSD license does not replace dependency licenses.
- Publish a public source repository if available, then add its real URL to
  each package's `repository:` field. The current `homepage:` points to the
  live MaxMedia website; a repository link is recommended for issue reports
  and source review but is not required by pub's validator.
- Recheck all three package names on pub.dev immediately before upload. They
  were not found through the pub.dev package API during this review, but names
  can be claimed at any time.
- Run `flutter analyze`, `flutter test`, and the platform integration tests on
  representative Android and Apple devices. In particular, verify short and
  long videos, rotation, HDR policy, unsupported codec behavior, cancellation,
  larger-output rejection, metadata warnings, and batch image memory usage.
- Keep HDR and wide-gamut source protection enabled by default. The explicit
  color-conversion options are opt-in and must not be described as lossless.
- Check `flutter pub publish --dry-run` from each package directory. Review
  every archived file for private assets, logs, generated output, and secrets.

The public APIs use local file paths. Apple video output currently requires
`removeAudio: true`; Android can keep audio. The video source picker methods
are implemented only on iOS. Callers need a different picker on Android and
macOS. Encoding may produce no size reduction; that output is deleted and the
caller receives `NO_SIZE_REDUCTION`. These boundaries are documented in the
plugin READMEs and must remain true in the published version.

## Upload sequence

Do not use `--force` or `--skip-validation` to bypass release checks.

```bash
cd packages/media_route_contracts
dart pub publish --dry-run
dart pub publish
```

Wait until `media_route_contracts` 0.1.0 is visible on pub.dev. Then, for each
plugin in the order above, temporarily move its ignored
`pubspec_overrides.yaml` outside the package, resolve from pub.dev, run tests,
and inspect the dry-run archive before publishing:

```bash
cd plugins/maxmedia_image_native
mv pubspec_overrides.yaml /tmp/maxmedia_image_pubspec_overrides.yaml
flutter pub get
flutter analyze
flutter test
flutter pub publish --dry-run
flutter pub publish
```

Repeat for `plugins/maxmedia_video_native` with a distinct temporary filename.
Restore local overrides afterward with `bash tools/setup_local_pub_overrides.sh`
if continuing monorepo development. Uploads are public and normally cannot be
undone, so the actual `pub publish` commands require an explicit final review.
