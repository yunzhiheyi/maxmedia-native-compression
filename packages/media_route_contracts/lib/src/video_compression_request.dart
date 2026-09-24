import 'media_enums.dart';

final class VideoCompressionRequest {
  static const schemaVersion = 1;

  VideoCompressionRequest({
    required this.inputPath,
    required this.outputPath,
    required this.codec,
    required this.container,
    required this.averageBitrate,
    this.width,
    this.height,
    this.maxShortSide,
    this.maxFrameRate,
    this.gopSeconds = 2,
    this.removeAudio = false,
    this.hdrPolicy = VideoHdrPolicy.keepOriginal,
  }) {
    if (inputPath.isEmpty || outputPath.isEmpty) {
      throw ArgumentError('inputPath and outputPath must not be empty');
    }
    if (averageBitrate <= 0) {
      throw ArgumentError.value(
        averageBitrate,
        'averageBitrate',
        'must be positive',
      );
    }
    if ((width == null) != (height == null)) {
      throw ArgumentError('width and height must be provided together');
    }
    if (width != null && (width! <= 0 || height! <= 0)) {
      throw ArgumentError('width and height must be positive');
    }
    if (maxShortSide != null && maxShortSide! <= 0) {
      throw ArgumentError.value(
        maxShortSide,
        'maxShortSide',
        'must be positive',
      );
    }
    if (maxShortSide != null && width != null) {
      throw ArgumentError(
        'maxShortSide and explicit width/height are mutually exclusive',
      );
    }
    if (maxFrameRate != null &&
        (!maxFrameRate!.isFinite || maxFrameRate! <= 0)) {
      throw ArgumentError.value(
        maxFrameRate,
        'maxFrameRate',
        'must be positive',
      );
    }
    if (!gopSeconds.isFinite || gopSeconds <= 0) {
      throw ArgumentError.value(gopSeconds, 'gopSeconds', 'must be positive');
    }
  }

  final String inputPath;
  final String outputPath;
  final VideoCodec codec;
  final ContainerFormat container;
  final int averageBitrate;
  final int? width;
  final int? height;

  /// Longest edge the *short* side of the output may have, in display
  /// orientation (a portrait 1080x1920 source with [maxShortSide] 720 becomes
  /// 720x1280). The executor resolves it against the real source geometry and
  /// preserves the aspect ratio; sources already at or below the cap are left
  /// untouched, so this never upscales. Unlike [width]/[height] the caller does
  /// not need to probe the source first.
  final int? maxShortSide;
  final double? maxFrameRate;
  final double gopSeconds;
  final bool removeAudio;
  final VideoHdrPolicy hdrPolicy;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'inputPath': inputPath,
    'outputPath': outputPath,
    'codec': codec.name,
    'container': container.name,
    'averageBitrate': averageBitrate,
    'width': width,
    'height': height,
    'maxShortSide': maxShortSide,
    'maxFrameRate': maxFrameRate,
    'gopSeconds': gopSeconds,
    'removeAudio': removeAudio,
    'hdrPolicy': hdrPolicy.name,
  };

  factory VideoCompressionRequest.fromJson(Map<Object?, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported video request schema: ${json['schemaVersion']}',
      );
    }
    return VideoCompressionRequest(
      inputPath: json['inputPath'] as String,
      outputPath: json['outputPath'] as String,
      codec: enumByName(VideoCodec.values, json['codec'], 'codec'),
      container: enumByName(
        ContainerFormat.values,
        json['container'],
        'container',
      ),
      averageBitrate: (json['averageBitrate'] as num).toInt(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      maxShortSide: (json['maxShortSide'] as num?)?.toInt(),
      maxFrameRate: (json['maxFrameRate'] as num?)?.toDouble(),
      gopSeconds: (json['gopSeconds'] as num?)?.toDouble() ?? 2,
      removeAudio: json['removeAudio'] as bool? ?? false,
      hdrPolicy: enumByName(
        VideoHdrPolicy.values,
        json['hdrPolicy'] ?? VideoHdrPolicy.keepOriginal.name,
        'hdrPolicy',
      ),
    );
  }
}
