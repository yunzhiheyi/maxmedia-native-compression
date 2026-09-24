import 'dart:math' as math;

import 'package:media_route_contracts/media_route_contracts.dart';

/// The Lab's bounded size/quality policy, shared by single and batch routes.
final class ImageCompressionPolicy {
  static const targetRatio = 0.70;
  static const minimumQuality = 0.60;

  static ImageCompressionRequest apply(ImageCompressionRequest request) {
    final lossy =
        request.format == ImageFormat.jpeg ||
        request.format == ImageFormat.webp ||
        request.format == ImageFormat.heic;
    return ImageCompressionRequest(
      inputPath: request.inputPath,
      outputPath: request.outputPath,
      format: request.format,
      quality: request.quality,
      maxWidth: request.maxWidth,
      maxHeight: request.maxHeight,
      preserveMetadata: request.preserveMetadata,
      colorPolicy: request.colorPolicy,
      resizePolicy: request.resizePolicy,
      targetCompressionRatio: lossy ? targetRatio : null,
      minimumQuality: lossy ? math.min(minimumQuality, request.quality) : null,
    );
  }
}
