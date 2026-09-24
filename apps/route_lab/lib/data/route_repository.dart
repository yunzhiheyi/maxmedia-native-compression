import 'dart:io';

import 'package:maxmedia_video_native/maxmedia_video_native.dart';

import 'compression_service.dart';
import '../domain/image_compression_policy.dart';

class RouteRepository {
  RouteRepository(this._service);

  final CompressionGateway _service;
  CapabilityReport? imageCapability;
  CapabilityReport? videoCapability;
  CompressionResult? lastImageResult;
  CompressionResult? lastVideoResult;
  Stream<VideoCompressionProgress> get videoProgress => _service.videoProgress;

  Future<void> loadCapabilities() async {
    final values = await Future.wait([
      _service.imageCapabilities(),
      _service.videoCapabilities(),
    ]);
    imageCapability = values[0];
    videoCapability = values[1];
  }

  Future<CompressionResult> compressImage(
    ImageCompressionRequest request,
  ) async {
    final planned = ImageCompressionPolicy.apply(request);
    final lossy = _isLossy(request.format);
    final result = await _service.compressImage(planned);
    if (lossy &&
        result.terminal == CompressionTerminal.succeeded &&
        result.outputBytes >= result.inputBytes) {
      final output = File(result.outputPath);
      if (await output.exists()) await output.delete();
      throw StateError('原图已经足够紧凑；在当前质量下限内无法继续减小，已保留原文件');
    }

    final actualSettings = <String, Object?>{
      ...result.actualSettings,
      'qualityRequested':
          result.actualSettings['qualityRequested'] ?? request.quality,
      'qualityApplied':
          result.actualSettings['qualityApplied'] ??
          result.actualSettings['quality'] ??
          request.quality,
      'adaptiveAttempts': result.actualSettings['adaptiveAttempts'] ?? 1,
      if (lossy)
        'targetCompressionRatio':
            result.actualSettings['targetCompressionRatio'] ??
            ImageCompressionPolicy.targetRatio,
      if (lossy)
        'minimumUsefulQuality':
            result.actualSettings['minimumUsefulQuality'] ??
            planned.minimumQuality,
    };
    final summarized = CompressionResult(
      schemaVersion: result.schemaVersion,
      terminal: result.terminal,
      executor: result.executor,
      outputPath: result.outputPath,
      elapsedMilliseconds: result.elapsedMilliseconds,
      inputBytes: result.inputBytes,
      outputBytes: result.outputBytes,
      actualSettings: actualSettings,
      warnings: result.warnings,
    );
    lastImageResult = summarized;
    return summarized;
  }

  bool _isLossy(ImageFormat format) =>
      format == ImageFormat.jpeg ||
      format == ImageFormat.webp ||
      format == ImageFormat.heic;

  Future<CompressionResult> compressVideo(
    VideoCompressionRequest request,
  ) async {
    final result = await _service.compressVideo(request);
    lastVideoResult = result;
    return result;
  }

  Future<void> cancelVideo() => _service.cancelVideo();

  Future<void> cancelImage() => _service.cancelImages();
}
