import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_image_native/maxmedia_image_native_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelMaxmediaImageNative platform =
      MethodChannelMaxmediaImageNative();
  const MethodChannel channel = MethodChannel('maxmedia_image_native');
  const EventChannel progressChannel = EventChannel(
    'maxmedia_image_native/batch_progress',
  );
  // EventChannel listen/cancel travel over a method channel of the same name.
  const MethodChannel progressMethodChannel = MethodChannel(
    'maxmedia_image_native/batch_progress',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'capabilities') {
            return <String, Object?>{
              'schemaVersion': 1,
              'executor': 'native',
              'platform': 'test',
              'features': <String>['resize'],
              'codecs': <String>[],
              'formats': <String>['jpeg'],
              'warnings': <String>[],
            };
          }
          if (methodCall.method == 'compressBatch') {
            return <String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'result': <String, Object?>{
                    'schemaVersion': 1,
                    'terminal': 'succeeded',
                    'executor': 'native',
                    'outputPath': '/out-0.jpg',
                    'elapsedMilliseconds': 1,
                    'inputBytes': 10,
                    'outputBytes': 5,
                    'actualSettings': <String, Object?>{'format': 'jpeg'},
                    'warnings': <String>[],
                  },
                },
                <String, Object?>{'index': 1, 'error': 'decode failed'},
              ],
            };
          }
          return <String, Object?>{
            'schemaVersion': 1,
            'terminal': 'succeeded',
            'executor': 'native',
            'outputPath': '/out.jpg',
            'elapsedMilliseconds': 1,
            'inputBytes': 10,
            'outputBytes': 5,
            'actualSettings': <String, Object?>{'format': 'jpeg'},
            'warnings': <String>[],
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          progressMethodChannel,
          (MethodCall methodCall) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(progressMethodChannel, null);
  });

  test('decodes capabilities', () async {
    expect((await platform.capabilities()).formats, contains('jpeg'));
  });

  test('encodes request and decodes result', () async {
    String? sentOperationId;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'compress') {
            final arguments = methodCall.arguments! as Map<Object?, Object?>;
            sentOperationId = arguments['operationId'] as String?;
            return <String, Object?>{
              'schemaVersion': 1,
              'terminal': 'succeeded',
              'executor': 'native',
              'outputPath': '/out.jpg',
              'elapsedMilliseconds': 1,
              'inputBytes': 10,
              'outputBytes': 5,
              'actualSettings': <String, Object?>{'format': 'jpeg'},
              'warnings': <String>[],
            };
          }
          return null;
        });
    final result = await platform.compress(
      ImageCompressionRequest(
        inputPath: '/in.png',
        outputPath: '/out.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
      operationId: 'op-1',
    );
    expect(result.outputBytes, 5);
    expect(sentOperationId, 'op-1');
  });

  test('cancel forwards the operation id allowlist', () async {
    Object? sentArguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'cancelImageCompression') {
            sentArguments = methodCall.arguments;
            return null;
          }
          return null;
        });

    await platform.cancelImageCompression(
      operationIds: const {'imagebatch-1#0', 'imagebatch-1#1'},
    );
    expect((sentArguments! as Map)['operationIds'], [
      'imagebatch-1#0',
      'imagebatch-1#1',
    ]);

    await platform.cancelImageCompression();
    expect((sentArguments! as Map).containsKey('operationIds'), isFalse);
  });

  test('decodes a cancelled item outcome', () {
    final outcome = ImageBatchItemResult.fromJson(<String, Object?>{
      'index': 2,
      'result': <String, Object?>{
        'schemaVersion': 1,
        'terminal': 'cancelled',
        'executor': 'native',
        'outputPath': '/out-2.jpg',
        'elapsedMilliseconds': 12,
        'inputBytes': 0,
        'outputBytes': 0,
        'actualSettings': <String, Object?>{'cancelled': true},
        'warnings': <String>['cancelled'],
      },
    });
    expect(outcome.succeeded, isFalse);
    expect(outcome.result?.terminal, CompressionTerminal.cancelled);
    expect(outcome.error, isNull);
  });

  test('compressBatch decodes mixed outcomes in input order', () async {
    final outcomes = await platform.compressBatch([
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
    ], batchId: 'batch-1');
    expect(outcomes, hasLength(2));
    expect(outcomes[0].succeeded, isTrue);
    expect(outcomes[0].result?.outputPath, '/out-0.jpg');
    expect(outcomes[1].succeeded, isFalse);
    expect(outcomes[1].error, 'decode failed');
  });

  test('batch progress events decode and order', () async {
    final events = <ImageBatchProgress>[];
    final subscription = platform.batchProgress().listen(events.add);
    await Future<void>.delayed(Duration.zero);

    Future<void> push(int completed, int total) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            progressChannel.name,
            const StandardMethodCodec().encodeSuccessEnvelope(<String, Object?>{
              'completed': completed,
              'total': total,
              'index': completed - 1,
              'terminal': completed == 3 ? 'cancelled' : 'succeeded',
            }),
            (_) {},
          );
    }

    await push(1, 3);
    await push(3, 3);
    await subscription.cancel();

    expect(events.map((event) => (event.completed, event.total)).toList(), [
      (1, 3),
      (3, 3),
    ]);
    expect(events.first.index, 0);
    expect(events.first.terminal, 'succeeded');
    expect(events.last.terminal, 'cancelled');
    expect(events.last.finished, isTrue);
  });
}
