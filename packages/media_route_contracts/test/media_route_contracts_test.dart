import 'package:media_route_contracts/media_route_contracts.dart';
import 'package:test/test.dart';

void main() {
  test('image request round-trips without losing policy fields', () {
    final request = ImageCompressionRequest(
      inputPath: '/input.png',
      outputPath: '/output.jpg',
      format: ImageFormat.jpeg,
      quality: 0.82,
      maxWidth: 1920,
      maxHeight: 1080,
      preserveMetadata: true,
      resizePolicy: ImageResizePolicy.social,
      targetCompressionRatio: 0.70,
      minimumQuality: 0.60,
    );

    final decoded = ImageCompressionRequest.fromJson(request.toJson());
    expect(decoded.toJson(), request.toJson());
    expect(decoded.resizePolicy, ImageResizePolicy.social);
  });

  test('image request rejects a half-specified adaptive policy', () {
    expect(
      () => ImageCompressionRequest(
        inputPath: '/input.png',
        outputPath: '/output.webp',
        format: ImageFormat.webp,
        quality: 0.8,
        targetCompressionRatio: 0.7,
      ),
      throwsArgumentError,
    );
  });

  test('image request rejects an adaptive floor above requested quality', () {
    expect(
      () => ImageCompressionRequest(
        inputPath: '/input.png',
        outputPath: '/output.webp',
        format: ImageFormat.webp,
        quality: 0.6,
        targetCompressionRatio: 0.7,
        minimumQuality: 0.7,
      ),
      throwsArgumentError,
    );
  });

  test('image request defaults to original-size policy for old payloads', () {
    final json = ImageCompressionRequest(
      inputPath: '/input.png',
      outputPath: '/output.webp',
      format: ImageFormat.webp,
      quality: 0.8,
    ).toJson()..remove('resizePolicy');

    expect(
      ImageCompressionRequest.fromJson(json).resizePolicy,
      ImageResizePolicy.original,
    );
  });

  test('image request protects the source color space by default', () {
    final request = ImageCompressionRequest(
      inputPath: '/input.png',
      outputPath: '/output.webp',
      format: ImageFormat.webp,
      quality: 0.8,
    );
    expect(request.colorPolicy, ImageColorPolicy.keepOriginal);
    final olderPayload = request.toJson()..remove('colorPolicy');
    expect(
      ImageCompressionRequest.fromJson(olderPayload).colorPolicy,
      ImageColorPolicy.keepOriginal,
    );
  });

  test('video request rejects half-specified dimensions', () {
    expect(
      () => VideoCompressionRequest(
        inputPath: '/input.mov',
        outputPath: '/output.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
        width: 1280,
      ),
      throwsArgumentError,
    );
  });

  test('video request round-trips the short-side cap', () {
    final request = VideoCompressionRequest(
      inputPath: '/input.mov',
      outputPath: '/output.mp4',
      codec: VideoCodec.h264,
      container: ContainerFormat.mp4,
      averageBitrate: 2_000_000,
      maxShortSide: 720,
      removeAudio: true,
    );

    final decoded = VideoCompressionRequest.fromJson(request.toJson());
    expect(decoded.maxShortSide, 720);
    expect(decoded.toJson(), request.toJson());
  });

  test('video request round-trips every HDR policy', () {
    for (final policy in VideoHdrPolicy.values) {
      final request = VideoCompressionRequest(
        inputPath: '/input.mov',
        outputPath: '/output.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
        hdrPolicy: policy,
      );

      final decoded = VideoCompressionRequest.fromJson(request.toJson());
      expect(decoded.hdrPolicy, policy);
      expect(decoded.toJson(), request.toJson());
    }
  });

  test(
    'video request protects HDR sources by default, including old payloads',
    () {
      final request = VideoCompressionRequest(
        inputPath: '/input.mov',
        outputPath: '/output.mp4',
        codec: VideoCodec.hevc,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
      );
      expect(request.hdrPolicy, VideoHdrPolicy.keepOriginal);
      final olderPayload = request.toJson()..remove('hdrPolicy');
      expect(
        VideoCompressionRequest.fromJson(olderPayload).hdrPolicy,
        VideoHdrPolicy.keepOriginal,
      );
    },
  );

  test('video request rejects a non-positive short-side cap', () {
    expect(
      () => VideoCompressionRequest(
        inputPath: '/input.mov',
        outputPath: '/output.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
        maxShortSide: 0,
      ),
      throwsArgumentError,
    );
  });

  test('video request rejects mixing the short-side cap with exact size', () {
    expect(
      () => VideoCompressionRequest(
        inputPath: '/input.mov',
        outputPath: '/output.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
        width: 1280,
        height: 720,
        maxShortSide: 720,
      ),
      throwsArgumentError,
    );
  });

  test('compression result exposes a stable ratio', () {
    const result = CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'test',
      outputPath: '/output',
      elapsedMilliseconds: 10,
      inputBytes: 100,
      outputBytes: 25,
      actualSettings: {},
    );
    expect(result.compressionRatio, 0.25);
  });
}
