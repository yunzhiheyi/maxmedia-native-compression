import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:maxmedia_video_native/maxmedia_video_native_platform_interface.dart';
import 'package:maxmedia_video_native/maxmedia_video_native_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMaxmediaVideoNativePlatform
    with MockPlatformInterfaceMixin
    implements MaxmediaVideoNativePlatform {
  @override
  Future<CapabilityReport> capabilities() async => const CapabilityReport(
    schemaVersion: 1,
    executor: 'fake',
    platform: 'test',
    features: {'cancel'},
    codecs: {'h264'},
    formats: {'mp4'},
  );

  @override
  Future<void> cancel() async {}

  @override
  Stream<VideoCompressionProgress> get progress => const Stream.empty();

  @override
  Future<VideoSourceSelection?> pickVideoSource() async =>
      const VideoSourceSelection(
        path: '/direct.mov',
        displayName: 'direct.mov',
        accessMode: 'photo-library-direct',
        elapsedMilliseconds: 12,
      );

  @override
  Future<List<VideoSourceSelection>> pickVideoSources() async => const [
    VideoSourceSelection(
      path: '/direct-0.mov',
      displayName: 'direct-0.mov',
      accessMode: 'photo-library-direct',
      elapsedMilliseconds: 12,
    ),
    VideoSourceSelection(
      path: '/direct-1.mov',
      displayName: 'direct-1.mov',
      accessMode: 'photo-library-direct',
      elapsedMilliseconds: 13,
    ),
  ];

  @override
  Future<CompressionResult> compress(VideoCompressionRequest request) async =>
      CompressionResult(
        schemaVersion: 1,
        terminal: CompressionTerminal.succeeded,
        executor: 'fake',
        outputPath: request.outputPath,
        elapsedMilliseconds: 1,
        inputBytes: 10,
        outputBytes: 8,
        actualSettings: {'codec': request.codec.name},
      );
}

void main() {
  final MaxmediaVideoNativePlatform initialPlatform =
      MaxmediaVideoNativePlatform.instance;

  test('$MethodChannelMaxmediaVideoNative is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMaxmediaVideoNative>());
  });

  test('delegates compression to the platform implementation', () async {
    const maxmediaVideoNativePlugin = MaxmediaVideoNative();
    final fakePlatform = MockMaxmediaVideoNativePlatform();
    MaxmediaVideoNativePlatform.instance = fakePlatform;
    final result = await maxmediaVideoNativePlugin.compress(
      VideoCompressionRequest(
        inputPath: '/in.mov',
        outputPath: '/out.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
      ),
    );
    expect(result.actualSettings['codec'], 'h264');
  });

  test('delegates native video source selection', () async {
    const plugin = MaxmediaVideoNative();
    final fakePlatform = MockMaxmediaVideoNativePlatform();
    MaxmediaVideoNativePlatform.instance = fakePlatform;

    final selection = await plugin.pickVideoSource();

    expect(selection?.path, '/direct.mov');
    expect(selection?.accessMode, 'photo-library-direct');
  });
}
