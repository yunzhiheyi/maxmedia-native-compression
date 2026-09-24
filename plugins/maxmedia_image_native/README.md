# maxmedia_image_native

Native image compression for Flutter on Android, iOS, and macOS. Requests and
results use the versioned `media_route_contracts` types, re-exported by this
package.

| Platform | Encoder | Output formats |
| --- | --- | --- |
| Android | BitmapFactory + Bitmap.compress | JPEG, PNG, WebP |
| iOS / macOS | ImageIO + CoreGraphics + libwebp | JPEG, PNG, WebP; HEIC if the device encoder supports it |

The plugin accepts local file paths, keeps the original aspect ratio when
resizing, and can avoid upscaling through `ImageResizePolicy.social`. Probe
`capabilities()` before requesting a format. PNG ignores `quality` on Android.

## Usage

```dart
import 'package:maxmedia_image_native/maxmedia_image_native.dart';

final plugin = MaxmediaImageNative();
final capability = await plugin.capabilities();
if (!capability.formats.contains('webp')) {
  throw UnsupportedError('WebP encoding is unavailable');
}

final result = await plugin.compress(ImageCompressionRequest(
  inputPath: '/absolute/input.jpg',
  outputPath: '/absolute/output.webp',
  format: ImageFormat.webp,
  quality: 0.8,
  resizePolicy: ImageResizePolicy.social,
));

if (result.terminal == CompressionTerminal.succeeded) {
  print('${result.outputBytes} bytes at ${result.outputPath}');
}
for (final warning in result.warnings) {
  print(warning);
}
```

Use a distinct output path in a writable directory. The plugin does not pick
files or manage temporary-file retention for the application.

`compressBatch()` submits one native batch and returns one result per input in
input order. `batchProgress()` emits an event whenever an item settles. One
item failing does not fail the entire batch. Batch concurrency can be set from
1 to 8, with 4 as the default; the native worker pool runs at most four tasks
at once. Peak memory depends on source dimensions and concurrency, so lower
this value for large images.

`cancelImageCompression()` cancels all queued or running image work. Pass
`operationIds` to cancel particular operations; IDs for a batch are
`$batchId#$index`. Cancelled operations return
`CompressionTerminal.cancelled` and partial outputs are removed.

Image format conversion can make a file larger. Compare `inputBytes` and
`outputBytes` before replacing the original; no size reduction is guaranteed
unless the optional target-ratio policy rejects an oversized result.

The default `ImageColorPolicy.keepOriginal` checks the decoded output color
space on Android 8+ and refuses an output that differs from the source. Older
Android versions cannot perform this check and keep the original by default.
Apple's WebP encoder writes sRGB pixels without the source ICC profile, so a
source with a known non-sRGB profile is kept unchanged by default. ImageIO
outputs with such a profile are checked after encoding; an unverified output
is deleted. Callers may explicitly choose `allowConversion` if a color-space
change is acceptable. This checks color-space identity, not pixel-for-pixel
equality or perceptual quality after lossy encoding.

EXIF and other non-color metadata remain best effort: Android Bitmap and Apple
WebP do not preserve the source EXIF metadata. An Android WebP encoder may
retain ICC, as verified on one Android 13 device; callers should still inspect
each result. The optional two-pass quality target may miss its size goal.
