import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_route_lab/presentation/media_warning_text.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

void main() {
  test('batch video keeps HDR risk but omits repeated benchmark caveats', () {
    const raw = [
      'estimatedDataRate is container metadata; benchmark decisions still require ffprobe/VMAF',
      'HDR source was decoded to 8-bit; color accuracy and HDR preservation are not validated for this transcode',
    ];

    expect(batchVideoWarnings(raw), ['HDR 已按 8-bit 转码，色彩准确性和 HDR 保留尚未验证']);
    expect(hasVideoColorRisk(raw), isTrue);
    expect(raw, hasLength(2));
  });

  test('ordinary bitrate adjustments are readable without a color alarm', () {
    const raw = [
      'estimatedDataRate is container metadata; benchmark decisions still require ffprobe/VMAF',
      'averageBitrate capped from 2000000 to 1500000 to stay below source bitrate',
    ];

    expect(batchVideoWarnings(raw), ['源视频码率较低，已自动下调编码目标']);
    expect(hasVideoColorRisk(raw), isFalse);
  });

  test('batch HDR choices match the single-video wording', () {
    expect(videoHdrPolicyLabel(VideoHdrPolicy.keepOriginal), '保留 HDR 原片（默认）');
    expect(
      localizedVideoError('PlatformException(HDR_COLOR_PRESERVATION, blocked)'),
      '检测到 HDR 或无法确认色彩信息，已跳过压缩并保留原视频。',
    );
    expect(
      videoHdrPolicyLabel(VideoHdrPolicy.toneMapToSdr),
      '转换为 SDR BT.709 后转 H.264',
    );
  });

  test('image color protection is shown as a skipped compression', () {
    expect(
      localizedImageError('PlatformException(IMAGE_COLOR_PRESERVATION)'),
      '无法确认输出保留原图色彩，已跳过压缩并保留原图。',
    );
  });
}
