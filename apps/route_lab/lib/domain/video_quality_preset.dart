/// Output resolution ladder offered to the user.
///
/// Bitrates are derived from a bits-per-pixel target rather than picked by
/// feel: `bitrate = bpp x width x height x fps`. The old flat 2 Mbps at
/// 1080p30 works out to 0.032 bpp, while 720p30 gives 0.073 bpp. This is
/// only a starting point: frame rate, image complexity and codec affect the
/// visual result, so the rungs are not a quality guarantee.
///
/// [maxShortSide] is the short side in display orientation; the executor scales
/// the real source geometry to it and never upscales, so a 720p source asked
/// for [p1080] simply stays 720p.
///
/// One iPhone 14 sample in `EV-MEDIA-000` item 13 took 44.45 s at 1080p,
/// 22.96 s at 720p and 23.23 s at 480p. The similar 720p/480p times do not
/// establish a general decode floor; other sources and devices need testing.
enum VideoQualityPreset {
  p480(
    label: '480p',
    maxShortSide: 480,
    // 480x854x30 = 12.3 Mpx/s x 0.075
    averageBitrate: 900_000,
  ),
  p720(
    label: '720p',
    maxShortSide: 720,
    // 720x1280x30 = 27.6 Mpx/s x 0.075
    averageBitrate: 2_000_000,
  ),
  p1080(
    label: '1080p',
    maxShortSide: 1080,
    // 1080x1920x30 = 62.2 Mpx/s x 0.075
    averageBitrate: 4_500_000,
  ),
  original(
    label: '原始分辨率',
    maxShortSide: null,
    // The source resolution is unknown before probing, so this rung cannot be
    // derived from bpp. It stays deliberately generous and relies on the
    // executor capping the request at 75% of the source bitrate.
    averageBitrate: 8_000_000,
  );

  const VideoQualityPreset({
    required this.label,
    required this.maxShortSide,
    required this.averageBitrate,
  });

  final String label;
  final int? maxShortSide;
  final int averageBitrate;

  /// Short caption describing what the rung costs and buys.
  ///
  /// The measured times are from one iPhone 14 sample (`EV-MEDIA-000` item 13)
  /// and are only illustrative, not estimates for the selected source.
  String get hint => switch (this) {
    p480 => '短边 480 · 体积更小，细节损失更多',
    p720 => '短边 720 · 默认分享档；按 30fps 估算，高帧率需检查画质',
    p1080 => '短边 1080 · 保留更多细节，通常需要更多编码工作',
    original => '不缩放 · 保留原始像素尺寸，文件可能更大',
  };
}

/// Explicit bitrate budget applied after choosing an output resolution.
/// Lower budgets target smaller files at the cost of more visible artifacts.
enum VideoBitrateBudget {
  standard(label: '标准码率', percent: 100),
  compact(label: '小体积 · 75% 码率', percent: 75),
  smallest(label: '更小体积 · 50% 码率', percent: 50);

  const VideoBitrateBudget({required this.label, required this.percent});

  final String label;
  final int percent;

  int apply(VideoQualityPreset preset) =>
      (preset.averageBitrate * percent / 100).round();
}
