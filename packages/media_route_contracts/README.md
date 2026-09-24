# media_route_contracts

Shared, versioned request and result types for the MaxMedia image and video
compression plugins. This is a Dart-only package; it does not encode media.

Most applications can import these types directly from
`maxmedia_image_native` or `maxmedia_video_native`, which re-export this package.

## Contracts

- `ImageCompressionRequest`: format, quality, optional size limits, resize
  policy, color-space policy, and optional two-pass size target.
- `VideoCompressionRequest`: codec, container, average bitrate, optional
  short-side limit, audio choice, and HDR policy. The default keeps detected
  HDR sources unchanged when color-preserving transcoding is unverified.
- `CapabilityReport`: formats, codecs, features, and platform warnings reported
  by the active native executor.
- `CompressionResult`: terminal status, byte counts, actual settings, elapsed
  time, and warnings. `compressionRatio` is output bytes divided by input bytes.

Requests serialize with `schemaVersion: 1`. A reader rejects an unknown request
schema rather than guessing its meaning. `ImageCompressionRequest.fromJson`
accepts older V1 payloads without the newer optional resize fields.

```dart
import 'package:media_route_contracts/media_route_contracts.dart';

final request = ImageCompressionRequest(
  inputPath: '/absolute/input.jpg',
  outputPath: '/absolute/output.webp',
  format: ImageFormat.webp,
  quality: 0.8,
  resizePolicy: ImageResizePolicy.social,
);

final payload = request.toJson();
final restored = ImageCompressionRequest.fromJson(payload);
```

Input and output paths must refer to different local files. Platform support
and codec availability are determined at runtime through the native plugins'
`capabilities()` calls.
