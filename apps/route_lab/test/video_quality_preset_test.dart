import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_route_lab/domain/video_quality_preset.dart';

/// Bits per pixel the ladder is designed around, at 30 fps.
double _bitsPerPixel(VideoQualityPreset preset, {required double ratio}) {
  final shortSide = preset.maxShortSide!;
  final longSide = shortSide * ratio;
  return preset.averageBitrate / (shortSide * longSide * 30);
}

void main() {
  test('scaling rungs retain the intended 30 fps bitrate budget', () {
    for (final preset in [
      VideoQualityPreset.p480,
      VideoQualityPreset.p720,
      VideoQualityPreset.p1080,
    ]) {
      final bpp = _bitsPerPixel(preset, ratio: 16 / 9);
      expect(
        bpp,
        inInclusiveRange(0.05, 0.10),
        reason:
            '${preset.label} lands at ${bpp.toStringAsFixed(4)} bpp, outside '
            'the configured planning range',
      );
    }
  });

  test('the V0 flat rate has a lower bit budget per pixel at 1080p', () {
    // 2 Mbps at 1080p30 — the behaviour this ladder was introduced to change.
    expect(2000000 / (1080 * 1920 * 30), lessThan(0.05));
    // The same bitrate buys a larger per-pixel budget at 720p.
    expect(
      _bitsPerPixel(VideoQualityPreset.p720, ratio: 16 / 9),
      greaterThan(0.05),
    );
  });

  test('only the original rung skips scaling', () {
    for (final preset in VideoQualityPreset.values) {
      expect(
        preset.maxShortSide == null,
        preset == VideoQualityPreset.original,
        reason: '${preset.label} disagrees with its scaling intent',
      );
    }
  });

  test('rungs increase in bitrate as resolution climbs', () {
    final ordered = VideoQualityPreset.values
        .map((preset) => preset.averageBitrate)
        .toList();
    expect(ordered, orderedEquals(<int>[...ordered]..sort()));
  });

  test('bitrate budgets keep the default and lower the requested target', () {
    expect(VideoBitrateBudget.standard.apply(VideoQualityPreset.p720), 2000000);
    expect(VideoBitrateBudget.compact.apply(VideoQualityPreset.p720), 1500000);
    expect(VideoBitrateBudget.smallest.apply(VideoQualityPreset.p720), 1000000);
    expect(
      VideoBitrateBudget.compact.apply(VideoQualityPreset.original),
      6000000,
    );
  });
}
