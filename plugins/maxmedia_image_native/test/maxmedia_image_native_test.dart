import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_image_native/maxmedia_image_native_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

final class FakeImagePlatform extends MaxmediaImageNativePlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<CapabilityReport> capabilities() async => const CapabilityReport(
    schemaVersion: 1,
    executor: 'fake',
    platform: 'test',
    features: {'resize'},
    codecs: {},
    formats: {'jpeg'},
  );

  @override
  Future<CompressionResult> compress(
    ImageCompressionRequest request, {
    required String operationId,
  }) async => CompressionResult(
    schemaVersion: 1,
    terminal: CompressionTerminal.succeeded,
    executor: 'fake',
    outputPath: request.outputPath,
    elapsedMilliseconds: 1,
    inputBytes: 10,
    outputBytes: 5,
    actualSettings: {'format': request.format.name},
  );

  @override
  Future<List<ImageBatchItemResult>> compressBatch(
    List<ImageCompressionRequest> requests, {
    required String batchId,
    int maxConcurrent = 4,
  }) async => [
    for (var index = 0; index < requests.length; index += 1)
      ImageBatchItemResult(
        index: index,
        result: CompressionResult(
          schemaVersion: 1,
          terminal: CompressionTerminal.succeeded,
          executor: 'fake',
          outputPath: requests[index].outputPath,
          elapsedMilliseconds: 1,
          inputBytes: 10,
          outputBytes: 5,
          actualSettings: {'format': requests[index].format.name},
        ),
      ),
  ];
}

void main() {
  test('delegates compression to the platform implementation', () async {
    MaxmediaImageNativePlatform.instance = FakeImagePlatform();
    const plugin = MaxmediaImageNative();
    final result = await plugin.compress(
      ImageCompressionRequest(
        inputPath: '/in.png',
        outputPath: '/out.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
    );
    expect(result.outputPath, '/out.jpg');
    expect(result.compressionRatio, 0.5);
  });

  test('batch delegates every request and keeps input order', () async {
    MaxmediaImageNativePlatform.instance = FakeImagePlatform();
    const plugin = MaxmediaImageNative();
    final outcomes = await plugin.compressBatch([
      ImageCompressionRequest(
        inputPath: '/in-0.png',
        outputPath: '/out-0.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
      ImageCompressionRequest(
        inputPath: '/in-1.png',
        outputPath: '/out-1.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
    ]);
    expect(outcomes, hasLength(2));
    expect(outcomes.map((outcome) => outcome.result?.outputPath), [
      '/out-0.jpg',
      '/out-1.jpg',
    ]);
  });

  test('batch rejects an empty request list', () async {
    MaxmediaImageNativePlatform.instance = FakeImagePlatform();
    const plugin = MaxmediaImageNative();
    expect(
      () => plugin.compressBatch(<ImageCompressionRequest>[]),
      throwsArgumentError,
    );
  });
}
