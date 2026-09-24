# maxmedia_video_native

Native video compression for Flutter. Android uses Media3 Transformer; iOS
and macOS use AVAssetReader and AVAssetWriter. The package re-exports its
versioned request and result types from `media_route_contracts`.

| Platform | Output | Audio | Source picker |
| --- | --- | --- | --- |
| Android | MP4, H.264 or HEVC | Keep or remove | Use an app-level file picker |
| iOS | MP4 or MOV, H.264 or HEVC | Remove only | `pickVideoSource(s)` available |
| macOS | MP4 or MOV, H.264 or HEVC | Remove only | Use an app-level file picker |

Use `capabilities()` to inspect codecs and features on the current device.
All platforms support `maxShortSide` to reduce display dimensions without
changing aspect ratio or enlarging smaller sources. Frame-rate reduction is
not supported. The native executor accepts one export at a time; the exported
`VideoBatchController` can queue multiple requests serially.

## Usage

```dart
import 'package:maxmedia_video_native/maxmedia_video_native.dart';

final plugin = MaxmediaVideoNative();
final capability = await plugin.capabilities();
if (!capability.codecs.contains('h264')) {
  throw UnsupportedError('H.264 encoding is unavailable');
}

final subscription = plugin.progress.listen((event) {
  print('${event.percent}%');
});
try {
  final result = await plugin.compress(VideoCompressionRequest(
    inputPath: '/absolute/input.mp4',
    outputPath: '/absolute/output.mp4',
    codec: VideoCodec.h264,
    container: ContainerFormat.mp4,
    averageBitrate: 1000000,
    maxShortSide: 720,
    removeAudio: true, // Required on iOS and macOS.
  ));
  print('${result.outputBytes} bytes at ${result.outputPath}');
  for (final warning in result.warnings) {
    print(warning);
  }
} finally {
  await subscription.cancel();
}
```

Input and output must be distinct local files. The output directory must be
writable. If the encoded file is not smaller than the source, the plugin
removes it and reports `NO_SIZE_REDUCTION`; handle that as a normal outcome
for short or already efficient sources. `cancel()` stops the active export.

## Color and format limits

`VideoHdrPolicy.keepOriginal` is the default. When HDR is detected, the plugin
returns `HDR_COLOR_PRESERVATION` before encoding and leaves the source intact.
On Apple platforms detection uses the track HDR characteristic and color
metadata; on Android it uses the video track's color transfer, primaries, HDR
metadata, and codec profile. An untagged HEVC track is treated as uncertain and
kept unchanged. Source files with missing or incorrect color metadata cannot
be classified with certainty.

`allowWithWarning` explicitly permits the existing color-risk route.
`toneMapToSdr` explicitly converts Apple HDR to SDR BT.709 for H.264 output;
this changes the HDR appearance. `rejectH264` refuses that Apple H.264 path.
Android rejects `toneMapToSdr` and `rejectH264` rather than silently changing
the request. Apple HEVC re-encoding is currently also an 8-bit route; choosing
HEVC alone does not guarantee HDR preservation.

Apple output reports probed codec, dimensions, frame rate, and estimated data
rate. Encoder settings and visual quality can vary by hardware and input; use
independent probing and visual comparisons for production acceptance. The
plugin does not support background resume or an Apple audio-preserving path.
