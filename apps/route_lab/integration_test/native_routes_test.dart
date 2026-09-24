import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'maxmedia-native-routes-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  testWidgets('ImageIO resizes a bundled PNG and writes JPEG', (tester) async {
    final input = '${temporaryDirectory.path}/input.png';
    final output = '${temporaryDirectory.path}/output.jpg';
    await _copyAsset('integration_test/assets/input.png', input);

    final result = await const MaxmediaImageNative().compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: output,
        format: ImageFormat.jpeg,
        quality: 0.82,
        maxWidth: 160,
        maxHeight: 90,
      ),
    );

    expect(result.terminal, CompressionTerminal.succeeded);
    expect(await File(output).length(), greaterThan(0));
    expect(result.actualSettings['inputWidth'], 320);
    expect(result.actualSettings['inputHeight'], 180);
    expect(result.actualSettings['width'], 160);
    expect(result.actualSettings['height'], 90);
    expect(result.actualSettings['orientationNormalized'], isTrue);
  });

  testWidgets('libwebp preserves dimensions and writes WebP', (tester) async {
    final input = '${temporaryDirectory.path}/input.png';
    final output = '${temporaryDirectory.path}/output.webp';
    await _copyAsset('integration_test/assets/input.png', input);

    const plugin = MaxmediaImageNative();
    final capability = await plugin.capabilities();
    if (Platform.isMacOS) expect(capability.platform, 'macos');
    expect(capability.formats, contains('webp'));
    final result = await plugin.compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: output,
        format: ImageFormat.webp,
        quality: 0.80,
      ),
    );

    final bytes = await File(output).readAsBytes();
    expect(result.terminal, CompressionTerminal.succeeded);
    expect(bytes.length, greaterThan(12));
    expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
    expect(String.fromCharCodes(bytes.skip(8).take(4)), 'WEBP');
    expect(result.actualSettings['format'], 'webp');
    expect(result.actualSettings['width'], 320);
    expect(result.actualSettings['height'], 180);
    expect(result.actualSettings['resizePolicy'], 'original');
  });

  testWidgets('Apple standard video compression keeps source audio', (
    tester,
  ) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    final input = '${temporaryDirectory.path}/with-audio.mp4';
    final output = '${temporaryDirectory.path}/with-audio-output.mp4';
    await _copyAsset('integration_test/assets/video-with-audio.mp4', input);

    final result = await const MaxmediaVideoNative().compress(
      VideoCompressionRequest(
        inputPath: input,
        outputPath: output,
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
        maxShortSide: 720,
      ),
    );
    expect(result.terminal, CompressionTerminal.succeeded);
    expect(result.actualSettings['audioPreserved'], isTrue);
    expect(result.actualSettings['audioRemoved'], isFalse);
    expect(await File(output).length(), lessThan(await File(input).length()));
  });

  testWidgets('Apple SDR video retains Display P3 color tags', (tester) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    final input = '${temporaryDirectory.path}/p3-sdr.mp4';
    final output = '${temporaryDirectory.path}/p3-sdr-output.mp4';
    await _copyAsset('integration_test/assets/video-p3-sdr.mp4', input);

    final result = await const MaxmediaVideoNative().compress(
      VideoCompressionRequest(
        inputPath: input,
        outputPath: output,
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 180_000,
      ),
    );
    expect(result.terminal, CompressionTerminal.succeeded);
    final source = result.actualSettings['input'] as Map;
    final encoded = result.actualSettings['output'] as Map;
    expect(source['colorPrimaries'].toString().toUpperCase(), contains('P3'));
    for (final key in ['colorPrimaries', 'transferFunction', 'yCbCrMatrix']) {
      expect(encoded[key], source[key]);
    }
    expect(await File(output).length(), lessThan(await File(input).length()));
  });

  testWidgets('social resize policy never enlarges a small image', (
    tester,
  ) async {
    final input = '${temporaryDirectory.path}/input.png';
    final output = '${temporaryDirectory.path}/social.webp';
    await _copyAsset('integration_test/assets/input.png', input);

    final result = await const MaxmediaImageNative().compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: output,
        format: ImageFormat.webp,
        quality: 0.80,
        resizePolicy: ImageResizePolicy.social,
      ),
    );

    expect(result.actualSettings['width'], 320);
    expect(result.actualSettings['height'], 180);
    expect(result.actualSettings['resizePolicy'], 'social');
    expect(result.actualSettings['socialResizeApplied'], isFalse);
  });

  testWidgets('grayscale JPEG is converted to WebP pixels', (tester) async {
    final input = '${temporaryDirectory.path}/gray.jpg';
    final output = '${temporaryDirectory.path}/gray.webp';
    await _copyAsset('integration_test/assets/image-gray.jpg', input);

    final result = await const MaxmediaImageNative().compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: output,
        format: ImageFormat.webp,
        quality: 0.80,
      ),
    );

    expect(result.terminal, CompressionTerminal.succeeded);
    expect(result.actualSettings['width'], 120);
    expect(result.actualSettings['height'], 80);
    expect(await File(output).length(), greaterThan(0));
  });

  testWidgets('wide-gamut WebP carries its source ICC profile', (
    tester,
  ) async {
    final input = '${temporaryDirectory.path}/display-p3.png';
    final output = '${temporaryDirectory.path}/display-p3.webp';
    await _copyAsset('integration_test/assets/image-display-p3.png', input);
    final original = await File(input).readAsBytes();

    final request = ImageCompressionRequest(
      inputPath: input,
      outputPath: output,
      format: ImageFormat.webp,
      quality: 0.8,
    );
    final result = await const MaxmediaImageNative().compress(request);
    expect(result.terminal, CompressionTerminal.succeeded);
    final outputBytes = await File(output).readAsBytes();
    expect(String.fromCharCodes(outputBytes).contains('ICCP'), isTrue);
    if (Platform.isIOS || Platform.isMacOS) {
      expect(result.actualSettings['iccPreserved'], isTrue);
    }
    expect(await File(input).readAsBytes(), original);
  });

  if (Platform.isIOS || Platform.isMacOS) {
    testWidgets('ImageIO keeps the Display P3 profile in JPEG output', (
      tester,
    ) async {
      final input = '${temporaryDirectory.path}/display-p3.png';
      final output = '${temporaryDirectory.path}/display-p3.jpg';
      await _copyAsset('integration_test/assets/image-display-p3.png', input);

      final result = await const MaxmediaImageNative().compress(
        ImageCompressionRequest(
          inputPath: input,
          outputPath: output,
          format: ImageFormat.jpeg,
          quality: 0.8,
        ),
      );
      expect(result.terminal, CompressionTerminal.succeeded);
      expect(result.actualSettings['colorPolicy'], 'keepOriginal');
      final outputBytes = await File(output).readAsBytes();
      expect(String.fromCharCodes(outputBytes).contains('ICC_PROFILE'), isTrue);
    });
  }

  testWidgets('EXIF orientation is normalized for JPEG and bounded WebP', (
    tester,
  ) async {
    final input = '${temporaryDirectory.path}/oriented.jpg';
    await _copyAsset('integration_test/assets/image-oriented.jpg', input);
    const plugin = MaxmediaImageNative();
    final jpeg = await plugin.compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: '${temporaryDirectory.path}/oriented-output.jpg',
        format: ImageFormat.jpeg,
        quality: 0.80,
      ),
    );
    final webp = await plugin.compress(
      ImageCompressionRequest(
        inputPath: input,
        outputPath: '${temporaryDirectory.path}/oriented-output.webp',
        format: ImageFormat.webp,
        quality: 0.80,
        maxWidth: 100,
        maxHeight: 50,
      ),
    );

    expect(jpeg.actualSettings['inputWidth'], 80);
    expect(jpeg.actualSettings['inputHeight'], 120);
    expect(jpeg.actualSettings['width'], 80);
    expect(jpeg.actualSettings['height'], 120);
    expect(jpeg.actualSettings['orientationNormalized'], isTrue);
    expect(webp.actualSettings['width'], lessThanOrEqualTo(100));
    expect(webp.actualSettings['height'], lessThanOrEqualTo(50));
  });

  testWidgets('image rejects an output path that aliases its input', (
    tester,
  ) async {
    final path = '${temporaryDirectory.path}/same.jpg';
    await _copyAsset('integration_test/assets/image-oriented.jpg', path);
    final original = await File(path).readAsBytes();

    await expectLater(
      const MaxmediaImageNative().compress(
        ImageCompressionRequest(
          inputPath: path,
          outputPath: path,
          format: ImageFormat.jpeg,
          quality: 0.80,
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(await File(path).readAsBytes(), original);
  });

  testWidgets('image batch rejects an output that aliases another input', (
    tester,
  ) async {
    final firstInput = '${temporaryDirectory.path}/first.jpg';
    final secondInput = '${temporaryDirectory.path}/second.jpg';
    await _copyAsset('integration_test/assets/image-oriented.jpg', firstInput);
    await _copyAsset('integration_test/assets/image-gray.jpg', secondInput);
    final original = await File(secondInput).readAsBytes();

    await expectLater(
      const MaxmediaImageNative().compressBatch([
        ImageCompressionRequest(
          inputPath: firstInput,
          outputPath: secondInput,
          format: ImageFormat.jpeg,
          quality: 0.8,
        ),
        ImageCompressionRequest(
          inputPath: secondInput,
          outputPath: '${temporaryDirectory.path}/other.webp',
          format: ImageFormat.webp,
          quality: 0.8,
        ),
      ]),
      throwsA(isA<PlatformException>()),
    );
    expect(await File(secondInput).readAsBytes(), original);
  });

  testWidgets('video rejects an output path that aliases its input', (
    tester,
  ) async {
    final path = '${temporaryDirectory.path}/same.mp4';
    await _copyAsset('integration_test/assets/input.mp4', path);
    final original = await File(path).readAsBytes();

    await expectLater(
      const MaxmediaVideoNative().compress(
        VideoCompressionRequest(
          inputPath: path,
          outputPath: path,
          codec: VideoCodec.h264,
          container: ContainerFormat.mp4,
          averageBitrate: 250000,
          removeAudio: true,
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(await File(path).readAsBytes(), original);
  });

  for (final codec in [VideoCodec.h264, VideoCodec.hevc]) {
    testWidgets('default policy keeps an HDR source for ${codec.name}', (
      tester,
    ) async {
      final input = '${temporaryDirectory.path}/hdr-input.mp4';
      final output = '${temporaryDirectory.path}/hdr-output-${codec.name}.mp4';
      await _copyAsset('integration_test/assets/video-hdr-hlg.mp4', input);
      final original = await File(input).readAsBytes();

      await expectLater(
        const MaxmediaVideoNative().compress(
          VideoCompressionRequest(
            inputPath: input,
            outputPath: output,
            codec: codec,
            container: ContainerFormat.mp4,
            averageBitrate: 250000,
            removeAudio: true,
          ),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'HDR_COLOR_PRESERVATION',
          ),
        ),
      );
      expect(await File(output).exists(), isFalse);
      expect(await File(input).readAsBytes(), original);
    });
  }

  testWidgets('native video fallback protects HDR when policy is omitted', (
    tester,
  ) async {
    final input = '${temporaryDirectory.path}/hdr-input.mp4';
    final output = '${temporaryDirectory.path}/hdr-fallback.mp4';
    await _copyAsset('integration_test/assets/video-hdr-hlg.mp4', input);
    final original = await File(input).readAsBytes();
    final request = VideoCompressionRequest(
      inputPath: input,
      outputPath: output,
      codec: VideoCodec.h264,
      container: ContainerFormat.mp4,
      averageBitrate: 250000,
      removeAudio: true,
    ).toJson()..remove('hdrPolicy');

    await expectLater(
      const MethodChannel(
        'maxmedia_video_native',
      ).invokeMethod<Object?>('compress', request),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'HDR_COLOR_PRESERVATION',
        ),
      ),
    );
    expect(await File(output).exists(), isFalse);
    expect(await File(input).readAsBytes(), original);
  });

  testWidgets('cancelled video leaves no partial output', (tester) async {
    final input = '${temporaryDirectory.path}/cancel-input.mp4';
    final output = '${temporaryDirectory.path}/cancel-output.mp4';
    await _copyAsset('integration_test/assets/video-cancel.mp4', input);
    const plugin = MaxmediaVideoNative();
    final running = plugin.compress(
      VideoCompressionRequest(
        inputPath: input,
        outputPath: output,
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 500000,
        removeAudio: true,
      ),
    );
    await plugin.cancel();
    final result = await running;

    expect(result.terminal, CompressionTerminal.cancelled);
    expect(await File(output).exists(), isFalse);
  });

  if (Platform.isIOS || Platform.isMacOS) {
    testWidgets('concurrent Apple video export is rejected as busy', (
      tester,
    ) async {
      final input = '${temporaryDirectory.path}/busy-input.mp4';
      await _copyAsset('integration_test/assets/video-cancel.mp4', input);
      const plugin = MaxmediaVideoNative();
      VideoCompressionRequest request(String output) => VideoCompressionRequest(
        inputPath: input,
        outputPath: '${temporaryDirectory.path}/$output.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 500000,
        removeAudio: true,
      );
      final first = plugin.compress(request('first'));
      final second = plugin.compress(request('second'));
      await expectLater(
        second,
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'BUSY',
          ),
        ),
      );
      await plugin.cancel();
      expect((await first).terminal, CompressionTerminal.cancelled);
      expect(
        await File('${temporaryDirectory.path}/second.mp4').exists(),
        isFalse,
      );
    });

    for (final codec in [VideoCodec.h264, VideoCodec.hevc]) {
      testWidgets('AVAssetReader/Writer emits an inspected ${codec.name} MP4', (
        tester,
      ) async {
        final input = '${temporaryDirectory.path}/input.mp4';
        final output = '${temporaryDirectory.path}/output-${codec.name}.mp4';
        await _copyAsset('integration_test/assets/input.mp4', input);
        const plugin = MaxmediaVideoNative();
        final progressEvents = <VideoCompressionProgress>[];
        final progressSubscription = plugin.progress.listen(progressEvents.add);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final result = await plugin.compress(
          VideoCompressionRequest(
            inputPath: input,
            outputPath: output,
            codec: codec,
            container: ContainerFormat.mp4,
            averageBitrate: 800000,
            removeAudio: true,
          ),
        );

        expect(result.terminal, CompressionTerminal.succeeded);
        expect(await File(output).length(), greaterThan(0));
        expect(result.actualSettings['codec'], codec.name);
        expect(result.actualSettings['videoProcessing'], 'transcode');
        expect(result.actualSettings['width'], 320);
        expect(result.actualSettings['height'], 180);
        expect(result.actualSettings['nominalFrameRate'], greaterThan(0));
        final inputSettings = Map<String, Object?>.from(
          result.actualSettings['input']! as Map,
        );
        final outputSettings = Map<String, Object?>.from(
          result.actualSettings['output']! as Map,
        );
        expect(inputSettings['width'], 320);
        expect(inputSettings['height'], 180);
        expect(inputSettings['nominalFrameRate'], greaterThan(0));
        expect(inputSettings['estimatedDataRate'], greaterThan(0));
        expect(outputSettings['codec'], codec.name);
        expect(outputSettings['estimatedDataRate'], greaterThan(0));
        expect(result.outputBytes, lessThan(result.inputBytes));
        expect(
          result.actualSettings['averageBitrateApplied'],
          lessThanOrEqualTo(800000),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(progressEvents, isNotEmpty);
        expect(
          progressEvents.any(
            (event) => event.fraction > 0 && event.fraction < 1,
          ),
          isTrue,
        );
        expect(progressEvents.last.percent, 100);
        await progressSubscription.cancel();
      });
    }
  }

  if (Platform.isAndroid) {
    testWidgets('Media3 downscales a longer video by its short side', (
      tester,
    ) async {
      final input = '${temporaryDirectory.path}/android-scale-input.mp4';
      final output = '${temporaryDirectory.path}/android-scale-output.mp4';
      await _copyAsset('integration_test/assets/video-cancel.mp4', input);

      final result = await const MaxmediaVideoNative().compress(
        VideoCompressionRequest(
          inputPath: input,
          outputPath: output,
          codec: VideoCodec.h264,
          container: ContainerFormat.mp4,
          averageBitrate: 500000,
          maxShortSide: 180,
          removeAudio: true,
        ),
      );

      expect(result.terminal, CompressionTerminal.succeeded);
      expect(result.outputBytes, lessThan(result.inputBytes));
      final outputSettings = Map<String, Object?>.from(
        result.actualSettings['output']! as Map,
      );
      expect(outputSettings['width'], 320);
      expect(outputSettings['height'], 180);
    });
  }

  if (Platform.isIOS || Platform.isMacOS) {
    testWidgets(
      'lower Apple bitrate budget reduces size at the same resolution',
      (tester) async {
        final input = '${temporaryDirectory.path}/bitrate-input.mp4';
        await _copyAsset('integration_test/assets/video-cancel.mp4', input);
        const bitrates = [900000, 675000];
        final results = <CompressionResult>[];
        for (final bitrate in bitrates) {
          results.add(
            await const MaxmediaVideoNative().compress(
              VideoCompressionRequest(
                inputPath: input,
                outputPath: '${temporaryDirectory.path}/bitrate-$bitrate.mp4',
                codec: VideoCodec.h264,
                container: ContainerFormat.mp4,
                averageBitrate: bitrate,
                maxShortSide: 480,
                removeAudio: true,
              ),
            ),
          );
        }

        expect(
          results.every(
            (result) => result.terminal == CompressionTerminal.succeeded,
          ),
          isTrue,
        );
        final standardOutput = Map<String, Object?>.from(
          results[0].actualSettings['output']! as Map,
        );
        final compactOutput = Map<String, Object?>.from(
          results[1].actualSettings['output']! as Map,
        );
        expect(compactOutput['width'], standardOutput['width']);
        expect(compactOutput['height'], standardOutput['height']);
        expect(results[1].outputBytes, lessThan(results[0].outputBytes));
      },
    );

    for (final fixture in const [
      (
        asset: 'video-4x3.mp4',
        displayWidth: 320,
        displayHeight: 240,
        encodedWidth: 320,
        encodedHeight: 240,
      ),
      (
        asset: 'video-portrait-pixels.mp4',
        displayWidth: 180,
        displayHeight: 320,
        encodedWidth: 180,
        encodedHeight: 320,
      ),
      (
        asset: 'video-square.mp4',
        displayWidth: 240,
        displayHeight: 240,
        encodedWidth: 240,
        encodedHeight: 240,
      ),
      (
        asset: 'video-ultrawide.mp4',
        displayWidth: 360,
        displayHeight: 120,
        encodedWidth: 360,
        encodedHeight: 120,
      ),
      (
        asset: 'video-ultratall.mp4',
        displayWidth: 120,
        displayHeight: 360,
        encodedWidth: 120,
        encodedHeight: 360,
      ),
      (
        asset: 'video-rotated-tall.mp4',
        displayWidth: 120,
        displayHeight: 360,
        encodedWidth: 360,
        encodedHeight: 120,
      ),
      (
        asset: 'video-rotated-180.mp4',
        displayWidth: 320,
        displayHeight: 240,
        encodedWidth: 320,
        encodedHeight: 240,
      ),
      (
        asset: 'video-rotated-wide.mp4',
        displayWidth: 360,
        displayHeight: 120,
        encodedWidth: 120,
        encodedHeight: 360,
      ),
    ]) {
      testWidgets(
        'Apple route preserves display geometry for ${fixture.asset}',
        (tester) async {
          final input = '${temporaryDirectory.path}/${fixture.asset}';
          final output = '${temporaryDirectory.path}/output-${fixture.asset}';
          await _copyAsset('integration_test/assets/${fixture.asset}', input);

          final result = await const MaxmediaVideoNative().compress(
            VideoCompressionRequest(
              inputPath: input,
              outputPath: output,
              codec: VideoCodec.h264,
              container: ContainerFormat.mp4,
              averageBitrate: 250000,
              removeAudio: true,
            ),
          );

          expect(result.terminal, CompressionTerminal.succeeded);
          final inputSettings = Map<String, Object?>.from(
            result.actualSettings['input']! as Map,
          );
          final outputSettings = Map<String, Object?>.from(
            result.actualSettings['output']! as Map,
          );
          for (final settings in [inputSettings, outputSettings]) {
            expect(settings['width'], fixture.displayWidth);
            expect(settings['height'], fixture.displayHeight);
            expect(settings['encodedWidth'], fixture.encodedWidth);
            expect(settings['encodedHeight'], fixture.encodedHeight);
          }
          expect(result.outputBytes, lessThan(result.inputBytes));
        },
      );
    }

    for (final fixture in const [
      // Unrotated: the encoded pair and the display pair scale together.
      (
        asset: 'video-4x3.mp4',
        maxShortSide: 120,
        displayWidth: 160,
        displayHeight: 120,
        encodedWidth: 160,
        encodedHeight: 120,
      ),
      // Rotated: the cap is measured on the 120-wide display side but applied
      // to the 360-wide encoded side, so the two pairs stay swapped.
      (
        asset: 'video-rotated-tall.mp4',
        maxShortSide: 60,
        displayWidth: 60,
        displayHeight: 180,
        encodedWidth: 180,
        encodedHeight: 60,
      ),
      // Cap above the source: left untouched rather than upscaled.
      (
        asset: 'video-ultrawide.mp4',
        maxShortSide: 1080,
        displayWidth: 360,
        displayHeight: 120,
        encodedWidth: 360,
        encodedHeight: 120,
      ),
    ]) {
      testWidgets('Apple route downscales ${fixture.asset} to short side '
          '${fixture.maxShortSide}', (tester) async {
        final input = '${temporaryDirectory.path}/scaled-${fixture.asset}';
        final output =
            '${temporaryDirectory.path}/scaled-output-${fixture.asset}';
        await _copyAsset('integration_test/assets/${fixture.asset}', input);

        final result = await const MaxmediaVideoNative().compress(
          VideoCompressionRequest(
            inputPath: input,
            outputPath: output,
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            averageBitrate: 250000,
            maxShortSide: fixture.maxShortSide,
            removeAudio: true,
          ),
        );

        expect(result.terminal, CompressionTerminal.succeeded);
        final outputSettings = Map<String, Object?>.from(
          result.actualSettings['output']! as Map,
        );
        expect(outputSettings['width'], fixture.displayWidth);
        expect(outputSettings['height'], fixture.displayHeight);
        expect(outputSettings['encodedWidth'], fixture.encodedWidth);
        expect(outputSettings['encodedHeight'], fixture.encodedHeight);
        expect(result.outputBytes, lessThan(result.inputBytes));
      });
    }

    testWidgets('Apple route rejects explicit width/height', (tester) async {
      final input = '${temporaryDirectory.path}/explicit-size.mp4';
      await _copyAsset('integration_test/assets/video-4x3.mp4', input);

      await expectLater(
        const MaxmediaVideoNative().compress(
          VideoCompressionRequest(
            inputPath: input,
            outputPath: '${temporaryDirectory.path}/explicit-size-out.mp4',
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            averageBitrate: 250000,
            width: 160,
            height: 120,
            removeAudio: true,
          ),
        ),
        throwsA(isA<Exception>()),
      );
    });
  }
}

Future<void> _copyAsset(String assetPath, String destinationPath) async {
  final data = await rootBundle.load(assetPath);
  await File(destinationPath).writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}
