import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_route_contracts/media_route_contracts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:maxmedia_route_lab/data/compression_service.dart';
import 'package:maxmedia_route_lab/data/route_repository.dart';

/// Measures the user-facing adaptive route rather than a single native encode.
/// Push a representative, already-compressed JPEG to
/// `Documents/adaptive-input.jpg` while the test is waiting.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('adaptive image compression encodes no more than twice', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final input = File('${documents.path}/adaptive-input.jpg');
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
    expect(await input.exists(), isTrue);

    final repository = RouteRepository(const NativeCompressionService());
    final runs = <Map<String, Object?>>[];
    for (var round = 1; round <= 3; round += 1) {
      final output = File('${documents.path}/adaptive-webp-$round.webp');
      if (await output.exists()) await output.delete();
      final stopwatch = Stopwatch()..start();
      final result = await repository.compressImage(
        ImageCompressionRequest(
          inputPath: input.path,
          outputPath: output.path,
          format: ImageFormat.webp,
          quality: 0.80,
        ),
      );
      stopwatch.stop();
      final attempts = result.actualSettings['adaptiveAttempts']! as int;
      expect(attempts, lessThanOrEqualTo(2));
      runs.add(<String, Object?>{
        'round': round,
        'wallMilliseconds': stopwatch.elapsedMicroseconds / 1000,
        'reportedMilliseconds': result.elapsedMilliseconds,
        'inputBytes': result.inputBytes,
        'outputBytes': result.outputBytes,
        'compressionRatio': result.compressionRatio,
        'qualityRequested': result.actualSettings['qualityRequested'],
        'qualityApplied': result.actualSettings['qualityApplied'],
        'adaptiveAttempts': attempts,
        'warnings': result.warnings,
      });
    }

    // ignore: avoid_print
    print(
      'IMAGE_ADAPTIVE_BENCHMARK_JSON=${jsonEncode(<String, Object?>{'sourcePath': input.path, 'sourceBytes': await input.length(), 'runs': runs})}',
    );
  });

  testWidgets('adaptive route fires the second pass when the first misses', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final input = File('${documents.path}/adaptive-input.jpg');
    expect(await input.exists(), isTrue);

    final repository = RouteRepository(const NativeCompressionService());
    final output = File('${documents.path}/adaptive-two-pass.jpeg');
    if (await output.exists()) await output.delete();
    final stopwatch = Stopwatch()..start();

    // Quality 0.95 on a noisy source is expected to miss the 0.70 target on
    // the first encode, forcing the single adaptive re-encode at the
    // estimated quality without re-decoding the file.
    final result = await repository.compressImage(
      ImageCompressionRequest(
        inputPath: input.path,
        outputPath: output.path,
        format: ImageFormat.jpeg,
        quality: 0.95,
      ),
    );
    stopwatch.stop();

    final attempts = result.actualSettings['adaptiveAttempts']! as int;
    expect(attempts, 2);
    final applied = result.actualSettings['qualityApplied']! as double;
    expect(applied, lessThan(0.95));
    expect(applied, greaterThanOrEqualTo(0.60));
    expect(result.outputBytes, lessThan(result.inputBytes));
    expect(result.warnings, isNotEmpty);
    // ignore: avoid_print
    final twoPassReport = <String, Object?>{
      'wallMilliseconds': stopwatch.elapsedMicroseconds / 1000,
      'reportedMilliseconds': result.elapsedMilliseconds,
      'inputBytes': result.inputBytes,
      'outputBytes': result.outputBytes,
      'compressionRatio': result.compressionRatio,
      'qualityRequested': result.actualSettings['qualityRequested'],
      'qualityApplied': applied,
      'adaptiveAttempts': attempts,
      'warnings': result.warnings,
    };
    // ignore: avoid_print
    print('IMAGE_TWO_PASS_JSON=${jsonEncode(twoPassReport)}');
  });
}
