import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_image_native/maxmedia_image_native_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

final class ScriptedBatchPlatform extends MaxmediaImageNativePlatform
    with MockPlatformInterfaceMixin {
  ScriptedBatchPlatform(this.settleScript);

  /// After [delay], every item settles via the progress stream and then the
  /// batch future resolves.
  final Future<void> Function(ScriptedBatchPlatform platform) settleScript;
  final progressController = StreamController<ImageBatchProgress>.broadcast();
  final cancelledCalls = <Set<String>?>[];
  int? lastMaxConcurrent;
  String? lastBatchId;

  void emit(ImageBatchProgress progress) => progressController.add(progress);

  @override
  Stream<ImageBatchProgress> batchProgress() => progressController.stream;

  @override
  Future<CompressionResult> compress(
    ImageCompressionRequest request, {
    required String operationId,
  }) async => throw UnimplementedError();

  @override
  Future<List<ImageBatchItemResult>> compressBatch(
    List<ImageCompressionRequest> requests, {
    required String batchId,
    int maxConcurrent = 4,
  }) async {
    lastMaxConcurrent = maxConcurrent;
    lastBatchId = batchId;
    await settleScript(this);
    return [
      for (var index = 0; index < requests.length; index += 1)
        ImageBatchItemResult(
          index: index,
          result: CompressionResult(
            schemaVersion: 1,
            terminal: index == 1
                ? CompressionTerminal.cancelled
                : CompressionTerminal.succeeded,
            executor: 'fake',
            outputPath: requests[index].outputPath,
            elapsedMilliseconds: index + 1,
            inputBytes: 10,
            outputBytes: index == 1 ? 0 : 5,
            actualSettings: const {'cancelled': false},
            warnings: const [],
          ),
        ),
    ];
  }

  @override
  Future<void> cancelImageCompression({Set<String>? operationIds}) async {
    cancelledCalls.add(operationIds);
  }
}

void main() {
  test(
    'per-item statuses stream in real time and finalize from results',
    () async {
      final platform = ScriptedBatchPlatform((platform) async {
        platform.emit(
          const ImageBatchProgress(
            completed: 1,
            total: 3,
            index: 0,
            terminal: 'succeeded',
          ),
        );
        // Let the broadcast delivery run while the batch is still pending,
        // mirroring how native progress arrives over the platform channel.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        platform.emit(
          const ImageBatchProgress(
            completed: 2,
            total: 3,
            index: 1,
            terminal: 'cancelled',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      MaxmediaImageNativePlatform.instance = platform;
      final controller = ImageBatchController(
        plugin: const MaxmediaImageNative(),
      );
      final states = <ImageBatchState>[];
      final subscription = controller.stateStream.listen(states.add);

      await controller.start([
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
        ImageCompressionRequest(
          inputPath: '/in-2.png',
          outputPath: '/out-2.jpg',
          format: ImageFormat.jpeg,
          quality: 0.8,
        ),
      ], maxConcurrent: 2);
      // Broadcast deliveries are asynchronous; let them flush before closing.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      expect(platform.lastMaxConcurrent, 2);
      final finalState = controller.currentState!;
      expect(finalState.isFinished, isTrue);
      expect(finalState.items[0].status, ImageBatchItemStatus.succeeded);
      expect(finalState.items[0].result?.outputBytes, 5);
      expect(finalState.items[1].status, ImageBatchItemStatus.cancelled);
      expect(finalState.items[2].status, ImageBatchItemStatus.succeeded);
      // Intermediate state must already show the first two items settled.
      final intermediate = states.where((state) => state.settledCount == 2);
      expect(intermediate, isNotEmpty);
    },
  );

  test('cancelItem scopes the operation id to that item', () async {
    final platform = ScriptedBatchPlatform((_) async {});
    MaxmediaImageNativePlatform.instance = platform;
    final controller = ImageBatchController(
      plugin: const MaxmediaImageNative(),
    );
    final running = controller.start([
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
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await controller.cancelItem(1);
    expect(platform.cancelledCalls.single!.single, endsWith('#1'));
    await platform.settleScript(platform);
    await running;
    controller.dispose();
  });

  test('start rejects a second concurrent run', () async {
    final platform = ScriptedBatchPlatform((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    MaxmediaImageNativePlatform.instance = platform;
    final controller = ImageBatchController(
      plugin: const MaxmediaImageNative(),
    );
    final running = controller.start([
      ImageCompressionRequest(
        inputPath: '/in-0.png',
        outputPath: '/out-0.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
    ]);
    expect(
      () => controller.start([
        ImageCompressionRequest(
          inputPath: '/in-1.png',
          outputPath: '/out-1.jpg',
          format: ImageFormat.jpeg,
          quality: 0.8,
        ),
      ]),
      throwsStateError,
    );
    await running;
    controller.dispose();
  });

  test('progress and cancellation stay within one batch', () async {
    final release = Completer<void>();
    final platform = ScriptedBatchPlatform((_) => release.future);
    MaxmediaImageNativePlatform.instance = platform;
    final controller = ImageBatchController(
      plugin: const MaxmediaImageNative(),
    );
    final requests = [
      for (var index = 0; index < 2; index++)
        ImageCompressionRequest(
          inputPath: '/input-$index.png',
          outputPath: '/output-$index.webp',
          format: ImageFormat.webp,
          quality: 0.8,
        ),
    ];
    final running = controller.start(requests);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    platform.emit(
      const ImageBatchProgress(
        batchId: 'another-batch',
        completed: 1,
        total: 2,
        index: 0,
        terminal: 'succeeded',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.currentState!.settledCount, 0);

    await controller.cancelAll();
    expect(platform.cancelledCalls.single, {
      '${platform.lastBatchId}#0',
      '${platform.lastBatchId}#1',
    });
    release.complete();
    await running;
    controller.dispose();
  });
}
