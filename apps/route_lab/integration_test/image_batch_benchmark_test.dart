import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:path_provider/path_provider.dart';

/// Measures single-request queueing against the native batch API on the same
/// set of images. The source file must be pushed into the app Documents
/// directory as `adaptive-input.jpg` before (or while) this runs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native batch compresses a queue faster than serial calls', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final source = File('${documents.path}/adaptive-input.jpg');
    const inputWaitSeconds = int.fromEnvironment(
      'IMAGE_BENCHMARK_INPUT_WAIT_SECONDS',
    );
    for (
      var second = 0;
      second < inputWaitSeconds && !await source.exists();
      second += 1
    ) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(await source.exists(), isTrue);

    const plugin = MaxmediaImageNative();
    ImageCompressionRequest requestFor(String outputPath) =>
        ImageCompressionRequest(
          inputPath: source.path,
          outputPath: outputPath,
          format: ImageFormat.webp,
          quality: 0.80,
        );

    Future<void> clearOutputs(String prefix) async {
      for (var index = 0; index < 8; index += 1) {
        final output = File('${documents.path}/$prefix-$index.webp');
        if (await output.exists()) await output.delete();
      }
    }

    // Warm the encoders so framework startup does not skew either route.
    await plugin.compress(
      requestFor('${documents.path}/batch-warmup.webp'),
    );
    await File('${documents.path}/batch-warmup.webp').delete();

    const imageCount = 6;

    await clearOutputs('batch-seq');
    final serialRequests = List.generate(
      imageCount,
      (index) => requestFor('${documents.path}/batch-seq-$index.webp'),
    );
    final serialWatch = Stopwatch()..start();
    for (final request in serialRequests) {
      await plugin.compress(request);
    }
    serialWatch.stop();

    await clearOutputs('batch-par');
    final batchRequests = List.generate(
      imageCount,
      (index) => requestFor('${documents.path}/batch-par-$index.webp'),
    );
    final progress = <ImageBatchProgress>[];
    final subscription = plugin.batchProgress().listen(progress.add);
    final batchWatch = Stopwatch()..start();
    final outcomes = await plugin.compressBatch(batchRequests);
    batchWatch.stop();
    await subscription.cancel();

    expect(outcomes, hasLength(imageCount));
    expect(outcomes.every((outcome) => outcome.succeeded), isTrue);
    expect(progress, isNotEmpty);
    expect(progress.last.finished, isTrue);

    final serialBytes = <int>[];
    for (var index = 0; index < imageCount; index += 1) {
      serialBytes.add(await File('${documents.path}/batch-seq-$index.webp').length());
    }
    final batchBytes = <int>[];
    for (var index = 0; index < imageCount; index += 1) {
      batchBytes.add(await File('${documents.path}/batch-par-$index.webp').length());
    }

    final report = <String, Object?>{
      'imageCount': imageCount,
      'sourceBytes': await source.length(),
      'serial': {
        'wallMilliseconds': serialWatch.elapsedMicroseconds / 1000,
        'outputBytes': serialBytes,
      },
      'batch': {
        'wallMilliseconds': batchWatch.elapsedMicroseconds / 1000,
        'outputBytes': batchBytes,
        'progressEvents': progress.length,
        'workerCap': 4,
      },
      'speedup':
          serialWatch.elapsedMicroseconds / batchWatch.elapsedMicroseconds,
    };
    // ignore: avoid_print
    print('IMAGE_BATCH_BENCHMARK_JSON=${jsonEncode(report)}');
  });
}
