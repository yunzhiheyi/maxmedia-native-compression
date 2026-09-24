import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:maxmedia_video_native/maxmedia_video_native_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

final class ScriptedVideoPlatform extends MaxmediaVideoNativePlatform
    with MockPlatformInterfaceMixin {
  final progressController =
      StreamController<VideoCompressionProgress>.broadcast();
  final compressCalls = <String>[];
  int cancelCalls = 0;

  /// When set, the next [compress] resolves as soon as [release] is called,
  /// letting the test hold an item mid-encode.
  Completer<void>? gate;
  void release() => gate?.complete();

  @override
  Stream<VideoCompressionProgress> get progress => progressController.stream;

  @override
  Future<CapabilityReport> capabilities() async => throw UnimplementedError();

  @override
  Future<VideoSourceSelection?> pickVideoSource() async => null;

  @override
  Future<CompressionResult> compress(VideoCompressionRequest request) async {
    // The native cancel flag only aborts the export it was issued for.
    _cancelRequested = false;
    compressCalls.add(request.inputPath);
    final held = gate;
    if (held != null) {
      await held.future;
    }
    return CompressionResult(
      schemaVersion: 1,
      terminal: _cancelRequested
          ? CompressionTerminal.cancelled
          : CompressionTerminal.succeeded,
      executor: 'fake',
      outputPath: request.outputPath,
      elapsedMilliseconds: 1,
      inputBytes: 10,
      outputBytes: 5,
      actualSettings: const {'codec': 'h264'},
      warnings: const [],
    );
  }

  bool _cancelRequested = false;

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
    _cancelRequested = true;
    release();
  }
}

VideoCompressionRequest requestFor(String name) => VideoCompressionRequest(
  inputPath: '/in-$name.mp4',
  outputPath: '/out-$name.mp4',
  codec: VideoCodec.h264,
  container: ContainerFormat.mp4,
  averageBitrate: 2_000_000,
);

void main() {
  test('queue compresses serially in input order', () async {
    final platform = ScriptedVideoPlatform();
    MaxmediaVideoNativePlatform.instance = platform;
    final controller = VideoBatchController(
      plugin: const MaxmediaVideoNative(),
    );
    final states = <VideoBatchState>[];
    final subscription = controller.stateStream.listen(states.add);

    await controller.start([requestFor('a'), requestFor('b'), requestFor('c')]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await subscription.cancel();

    expect(platform.compressCalls, ['/in-a.mp4', '/in-b.mp4', '/in-c.mp4']);
    final finalState = controller.currentState!;
    expect(finalState.isFinished, isTrue);
    expect(
      finalState.items.every(
        (item) => item.status == VideoQueueItemStatus.succeeded,
      ),
      isTrue,
    );
  });

  test('cancelCurrent aborts the running item and moves to the next', () async {
    final platform = ScriptedVideoPlatform();
    MaxmediaVideoNativePlatform.instance = platform;
    platform.gate = Completer<void>();
    final controller = VideoBatchController(
      plugin: const MaxmediaVideoNative(),
    );

    final running = controller.start([requestFor('a'), requestFor('b')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      controller.currentState!.items[0].status,
      VideoQueueItemStatus.running,
    );

    await controller.cancelCurrent();
    await running;

    expect(platform.cancelCalls, 1);
    final finalState = controller.currentState!;
    expect(finalState.items[0].status, VideoQueueItemStatus.cancelled);
    expect(finalState.items[1].status, VideoQueueItemStatus.succeeded);
    expect(platform.compressCalls, ['/in-a.mp4', '/in-b.mp4']);
  });

  test('cancelAll cancels the running item and drains the queue', () async {
    final platform = ScriptedVideoPlatform();
    MaxmediaVideoNativePlatform.instance = platform;
    platform.gate = Completer<void>();
    final controller = VideoBatchController(
      plugin: const MaxmediaVideoNative(),
    );

    final running = controller.start([
      requestFor('a'),
      requestFor('b'),
      requestFor('c'),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await controller.cancelAll();
    await running;

    expect(platform.compressCalls, ['/in-a.mp4']);
    final finalState = controller.currentState!;
    expect(finalState.items.map((item) => item.status).toList(), [
      VideoQueueItemStatus.cancelled,
      VideoQueueItemStatus.cancelled,
      VideoQueueItemStatus.cancelled,
    ]);
    expect(finalState.isFinished, isTrue);
  });
}
