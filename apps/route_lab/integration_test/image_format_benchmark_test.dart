import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:path_provider/path_provider.dart';

/// Benchmarks every image format reported by the native plugin on a real
/// device without Route Lab's adaptive-quality retries.
///
/// Push the source after the first test install (an install from another build
/// lineage can replace the app data container):
///
///   xcrun devicectl device copy to --device UDID \
///     --domain-type appDataContainer \
///     --domain-identifier cc.maxmax.maxmediaRouteLab \
///     --source input.png --destination Documents/benchmark-input.png
///
/// When the test install replaces the data container, run with
/// `--dart-define=IMAGE_BENCHMARK_INPUT_WAIT_SECONDS=120`, then push the file
/// while the test waits. `IMAGE_BENCHMARK_HOLD_OPEN=true` keeps the app alive
/// for 60 seconds after reporting so outputs can be copied back for SSIM/PSNR.
///
/// JPEG/HEIC use quality 75, WebP uses quality 80, and PNG is lossless. The
/// benchmark reports both the plugin timer and end-to-end call wall time;
/// the latter includes source decode and MethodChannel overhead.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('benchmark every available image format at fixed quality', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final input = File('${documents.path}/benchmark-input.png');
    const inputWaitSeconds = int.fromEnvironment(
      'IMAGE_BENCHMARK_INPUT_WAIT_SECONDS',
    );
    for (
      var second = 0;
      second < inputWaitSeconds && !await input.exists();
      second += 1
    ) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(
      await input.exists(),
      isTrue,
      reason: 'Push benchmark-input.png with devicectl; see this test header.',
    );

    const plugin = MaxmediaImageNative();
    const useSocialResize = bool.fromEnvironment(
      'IMAGE_BENCHMARK_SOCIAL_RESIZE',
    );
    final resizePolicy = useSocialResize
        ? ImageResizePolicy.social
        : ImageResizePolicy.original;
    final capability = await plugin.capabilities();
    final candidates = <ImageFormat, double>{
      ImageFormat.jpeg: 0.75,
      ImageFormat.png: 1,
      ImageFormat.webp: 0.80,
      ImageFormat.heic: 0.75,
    };
    final available = candidates.entries
        .where((entry) => capability.formats.contains(entry.key.name))
        .toList(growable: false);
    expect(available, isNotEmpty);

    Future<Map<String, Object?>> runOnce(
      MapEntry<ImageFormat, double> entry,
      String suffix,
    ) async {
      final extension = switch (entry.key) {
        ImageFormat.jpeg => 'jpg',
        ImageFormat.png => 'png',
        ImageFormat.webp => 'webp',
        ImageFormat.heic => 'heic',
      };
      final output = File(
        '${documents.path}/benchmark-${entry.key.name}-$suffix.$extension',
      );
      if (await output.exists()) await output.delete();
      final stopwatch = Stopwatch()..start();
      final result = await plugin.compress(
        ImageCompressionRequest(
          inputPath: input.path,
          outputPath: output.path,
          format: entry.key,
          quality: entry.value,
          resizePolicy: resizePolicy,
        ),
      );
      stopwatch.stop();
      expect(result.terminal, CompressionTerminal.succeeded);
      expect(await output.length(), result.outputBytes);
      return <String, Object?>{
        'format': entry.key.name,
        'quality': entry.value,
        'pluginMilliseconds': result.elapsedMilliseconds,
        'wallMilliseconds': stopwatch.elapsedMicroseconds / 1000,
        'inputBytes': result.inputBytes,
        'outputBytes': result.outputBytes,
        'compressionRatio': result.compressionRatio,
        'executor': result.executor,
        'settings': result.actualSettings,
        'warnings': result.warnings,
        'outputPath': output.path,
      };
    }

    // Warm every encoder once so dynamic-library and framework startup do not
    // get attributed to whichever format happens to run first.
    for (final entry in available) {
      final result = await runOnce(entry, 'warmup');
      await File(result['outputPath']! as String).delete();
    }

    final runs = <Map<String, Object?>>[];
    for (var round = 1; round <= 3; round += 1) {
      for (final entry in available) {
        runs.add(await runOnce(entry, 'run-$round'));
      }
    }

    final report = <String, Object?>{
      'deviceFormats': capability.formats.toList(growable: false),
      'executor': capability.executor,
      'sourcePath': input.path,
      'sourceBytes': await input.length(),
      'resizePolicy': resizePolicy.name,
      'runs': runs,
    };
    // ignore: avoid_print
    print('IMAGE_BENCHMARK_JSON=${jsonEncode(report)}');
    if (const bool.fromEnvironment('IMAGE_BENCHMARK_HOLD_OPEN')) {
      await Future<void>.delayed(const Duration(seconds: 60));
    }
  });
}
