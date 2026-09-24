enum MediaRouteKind { ffmpeg, platformNative }

enum ImageFormat { jpeg, png, webp, heic }

/// Controls whether an image may be exported when its color space changes.
enum ImageColorPolicy {
  /// Keep the source if the output cannot preserve its color space.
  keepOriginal,

  /// Allow a color-space conversion, such as Display P3 to untagged WebP/sRGB.
  allowConversion,
}

/// Controls whether image pixels are kept at their original dimensions or
/// resized with a social-sharing policy before encoding.
enum ImageResizePolicy {
  /// Keep the original dimensions unless explicit maxWidth/maxHeight caps are
  /// supplied.
  original,

  /// Use a Luban-inspired, aspect-ratio-aware 1440 px short-side target with
  /// panorama and long-image memory guards. Never enlarges the source.
  social,
}

enum VideoCodec { h264, hevc }

/// Controls what an executor should do with an HDR video source.
enum VideoHdrPolicy {
  /// Keep the source file and reject HDR exports whose color cannot be
  /// guaranteed by the current native route. This is the safe default.
  keepOriginal,

  /// Keep the current 8-bit H.264 path and surface the color-risk warning.
  allowWithWarning,

  /// Convert HDR pixels and metadata to SDR BT.709 before encoding H.264.
  toneMapToSdr,

  /// Refuse the H.264 route until the caller chooses another explicit policy.
  rejectH264,
}

enum ContainerFormat { mp4, mov }

enum CompressionTerminal { succeeded, failed, cancelled }

T enumByName<T extends Enum>(Iterable<T> values, Object? raw, String field) {
  final name = raw?.toString();
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unsupported $field: $raw');
}
