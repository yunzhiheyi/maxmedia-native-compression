import 'media_enums.dart';

final class ImageCompressionRequest {
  static const schemaVersion = 1;

  ImageCompressionRequest({
    required this.inputPath,
    required this.outputPath,
    required this.format,
    required this.quality,
    this.maxWidth,
    this.maxHeight,
    this.preserveMetadata = false,
    this.colorPolicy = ImageColorPolicy.keepOriginal,
    this.resizePolicy = ImageResizePolicy.original,
    this.targetCompressionRatio,
    this.minimumQuality,
  }) {
    if (inputPath.isEmpty || outputPath.isEmpty) {
      throw ArgumentError('inputPath and outputPath must not be empty');
    }
    if (!quality.isFinite || quality < 0 || quality > 1) {
      throw ArgumentError.value(quality, 'quality', 'must be within 0..1');
    }
    if (maxWidth != null && maxWidth! <= 0) {
      throw ArgumentError.value(maxWidth, 'maxWidth', 'must be positive');
    }
    if (maxHeight != null && maxHeight! <= 0) {
      throw ArgumentError.value(maxHeight, 'maxHeight', 'must be positive');
    }
    if ((targetCompressionRatio == null) != (minimumQuality == null)) {
      throw ArgumentError(
        'targetCompressionRatio and minimumQuality must be supplied together',
      );
    }
    if (targetCompressionRatio != null &&
        (!targetCompressionRatio!.isFinite ||
            targetCompressionRatio! <= 0 ||
            targetCompressionRatio! >= 1)) {
      throw ArgumentError.value(
        targetCompressionRatio,
        'targetCompressionRatio',
        'must be within 0..1 (exclusive)',
      );
    }
    if (minimumQuality != null &&
        (!minimumQuality!.isFinite ||
            minimumQuality! < 0 ||
            minimumQuality! > quality)) {
      throw ArgumentError.value(
        minimumQuality,
        'minimumQuality',
        'must be within 0..quality',
      );
    }
  }

  final String inputPath;
  final String outputPath;
  final ImageFormat format;
  final double quality;
  final int? maxWidth;
  final int? maxHeight;
  final bool preserveMetadata;
  final ImageColorPolicy colorPolicy;
  final ImageResizePolicy resizePolicy;
  final double? targetCompressionRatio;
  final double? minimumQuality;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'inputPath': inputPath,
    'outputPath': outputPath,
    'format': format.name,
    'quality': quality,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'preserveMetadata': preserveMetadata,
    'colorPolicy': colorPolicy.name,
    'resizePolicy': resizePolicy.name,
    'targetCompressionRatio': targetCompressionRatio,
    'minimumQuality': minimumQuality,
  };

  factory ImageCompressionRequest.fromJson(Map<Object?, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported image request schema: ${json['schemaVersion']}',
      );
    }
    return ImageCompressionRequest(
      inputPath: json['inputPath'] as String,
      outputPath: json['outputPath'] as String,
      format: enumByName(ImageFormat.values, json['format'], 'format'),
      quality: (json['quality'] as num).toDouble(),
      maxWidth: (json['maxWidth'] as num?)?.toInt(),
      maxHeight: (json['maxHeight'] as num?)?.toInt(),
      preserveMetadata: json['preserveMetadata'] as bool? ?? false,
      colorPolicy: json['colorPolicy'] == null
          ? ImageColorPolicy.keepOriginal
          : enumByName(
              ImageColorPolicy.values,
              json['colorPolicy'],
              'colorPolicy',
            ),
      resizePolicy: json['resizePolicy'] == null
          ? ImageResizePolicy.original
          : enumByName(
              ImageResizePolicy.values,
              json['resizePolicy'],
              'resizePolicy',
            ),
      targetCompressionRatio: (json['targetCompressionRatio'] as num?)
          ?.toDouble(),
      minimumQuality: (json['minimumQuality'] as num?)?.toDouble(),
    );
  }
}
