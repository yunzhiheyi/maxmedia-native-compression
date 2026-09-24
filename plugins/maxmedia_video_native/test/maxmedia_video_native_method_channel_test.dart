import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_video_native/maxmedia_video_native_method_channel.dart';
import 'package:maxmedia_video_native/video_compression_progress.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelMaxmediaVideoNative platform =
      MethodChannelMaxmediaVideoNative();
  const MethodChannel channel = MethodChannel('maxmedia_video_native');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'capabilities') {
            return <String, Object?>{
              'schemaVersion': 1,
              'executor': 'native',
              'platform': 'test',
              'features': <String>['cancel'],
              'codecs': <String>['h264'],
              'formats': <String>['mp4'],
              'warnings': <String>[],
            };
          }
          if (methodCall.method == 'cancel') return null;
          if (methodCall.method == 'pickVideoSource') {
            return <String, Object?>{
              'path': '/direct.mov',
              'displayName': 'direct.mov',
              'accessMode': 'photo-library-direct',
              'elapsedMilliseconds': 12,
            };
          }
          return <String, Object?>{
            'schemaVersion': 1,
            'terminal': 'succeeded',
            'executor': 'native',
            'outputPath': '/out.mp4',
            'elapsedMilliseconds': 1,
            'inputBytes': 10,
            'outputBytes': 8,
            'actualSettings': <String, Object?>{'codec': 'h264'},
            'warnings': <String>[],
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('decodes capabilities', () async {
    expect((await platform.capabilities()).codecs, contains('h264'));
  });

  test('encodes request and decodes result', () async {
    final result = await platform.compress(
      VideoCompressionRequest(
        inputPath: '/in.mov',
        outputPath: '/out.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
      ),
    );
    expect(result.outputBytes, 8);
  });

  test('decodes a bounded progress event', () {
    final progress = VideoCompressionProgress.fromEvent({
      'fraction': 1.2,
      'stage': 'finalizing',
    });
    expect(progress.fraction, 1);
    expect(progress.percent, 100);
    expect(progress.stage, 'finalizing');
  });

  test('decodes a native video source selection', () async {
    final selection = await platform.pickVideoSource();
    expect(selection?.displayName, 'direct.mov');
    expect(selection?.elapsedMilliseconds, 12);
  });
}
