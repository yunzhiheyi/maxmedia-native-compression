import 'package:media_route_contracts/media_route_contracts.dart';

String videoHdrPolicyLabel(VideoHdrPolicy policy) => switch (policy) {
  VideoHdrPolicy.keepOriginal => '保留 HDR 原片（默认）',
  VideoHdrPolicy.allowWithWarning => '继续转码并提示色彩风险',
  VideoHdrPolicy.toneMapToSdr => '转换为 SDR BT.709 后转 H.264',
  VideoHdrPolicy.rejectH264 => '遇到 HDR 时拒绝 H.264',
};

String localizedVideoError(String? error) {
  if (error?.contains('HDR_COLOR_PRESERVATION') == true) {
    return '检测到 HDR 或无法确认色彩信息，已跳过压缩并保留原视频。';
  }
  return error ?? '压缩失败';
}

String localizedImageError(String? error) {
  if (error?.contains('IMAGE_COLOR_PRESERVATION') == true ||
      error?.contains('Source image kept unchanged') == true) {
    return '无法确认输出保留原图色彩，已跳过压缩并保留原图。';
  }
  return error ?? '压缩失败';
}

String localizedMediaWarning(String warning) {
  if (warning.startsWith('estimatedDataRate is container metadata')) {
    return '视频码率为系统从容器读取的估算值；技术选型仍需使用 ffprobe/VMAF 复核';
  }
  if (warning.startsWith('Result records requested settings')) {
    return '当前记录的是请求参数；实际编码结果仍需独立核对';
  }
  if (warning.startsWith('averageBitrate capped')) {
    return '源视频码率较低，已自动下调编码目标';
  }
  if (warning.startsWith('HDR source was decoded to 8-bit')) {
    return 'HDR 已按 8-bit 转码，色彩准确性和 HDR 保留尚未验证';
  }
  if (warning.startsWith('HDR pixels were rendered through')) {
    return 'HDR 已转换为 SDR BT.709，画面颜色可能变化';
  }
  if (warning == 'Metadata preservation after resize is best-effort') {
    return '图片缩放后的 metadata 保留是尽力而为，仍需独立检查 EXIF/ICC';
  }
  if (warning == 'WebP metadata was not preserved by the libwebp route') {
    return 'WebP 路线当前不保留 EXIF/ICC 等 metadata，像素方向已归一化';
  }
  if (warning.startsWith('Image quality was adapted once')) {
    return '已根据首次结果估算一次补偿质量，避免反复完整编码';
  }
  if (warning.startsWith('The quality floor was reached')) {
    return '已达到 60% 质量下限；未继续牺牲画质以追求目标体积';
  }
  if (warning.startsWith('Social resize policy reduced')) {
    return '已按社交分享策略等比缩小像素尺寸，再执行格式编码';
  }
  return warning;
}

/// Benchmark caveats remain in the result payload but do not crowd each batch
/// item; actual color and bitrate changes remain visible next to that item.
List<String> batchVideoWarnings(Iterable<String> warnings) => [
  for (final warning in warnings)
    if (!warning.startsWith('estimatedDataRate is container metadata') &&
        !warning.startsWith('Result records requested settings'))
      localizedMediaWarning(warning),
];

bool hasVideoColorRisk(Iterable<String> warnings) => warnings.any(
  (warning) =>
      warning.startsWith('HDR source was decoded to 8-bit') ||
      warning.startsWith('HDR pixels were rendered through'),
);
