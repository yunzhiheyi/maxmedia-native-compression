import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_route_lab/domain/video_quality_preset.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:path_provider/path_provider.dart';

/// Measures the resolution ladder on real hardware.
///
/// Not part of the smoke suite: it needs a large source pushed into the app
/// container first, because a bundled asset big enough to reach encoder steady
/// state would bloat the repo.
///
///   ffmpeg -y -f lavfi -i "testsrc2=size=1080x1920:rate=30:duration=120" \
///     -vf "noise=alls=14:allf=t" -c:v hevc_videotoolbox -b:v 15M \
///     -tag:v hvc1 -pix_fmt yuv420p bench-1080x1920-hevc.mp4
///   xcrun devicectl device copy to --device UDID \
///     --domain-type appDataContainer \
///     --domain-identifier cc.maxmax.maxmediaRouteLab \
///     --source bench-1080x1920-hevc.mp4 --destination Documents/
///
/// Runs are ordered most-expensive first and the 720p rung is repeated last, so
/// thermal drift shows up as a gap between the two 720p numbers instead of
/// silently inflating the speed-up.
const _sourceName = 'bench-1080x1920-hevc.mp4';

final class _Run {
  _Run({
    required this.label,
    required this.elapsedMilliseconds,
    required this.outputBytes,
    required this.width,
    required this.height,
    required this.appliedBitrate,
    required this.sourceDurationSeconds,
    required this.frameRate,
  });

  final String label;
  final int elapsedMilliseconds;
  final int outputBytes;
  final int width;
  final int height;
  final int appliedBitrate;
  final double sourceDurationSeconds;
  final double frameRate;

  double get seconds => elapsedMilliseconds / 1000;
  double get realtimeFactor => sourceDurationSeconds / seconds;
  double get framesPerSecond => sourceDurationSeconds * frameRate / seconds;
  double get megapixelsPerSecond => width * height * framesPerSecond / 1e6;
  double get outputMiB => outputBytes / (1024 * 1024);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'resolution ladder throughput on device',
    (tester) async {
      final documents = await getApplicationDocumentsDirectory();
      final source = File('${documents.path}/$_sourceName');
      expect(
        await source.exists(),
        isTrue,
        reason:
            'Missing $_sourceName in ${documents.path}. Push it with devicectl '
            'first; see the header of this file for the exact commands.',
      );

      final sourceBytes = await source.length();
      final runs = <_Run>[];

      // Most expensive first: the device is coolest at the start, so this
      // ordering cannot manufacture a speed-up for the cheaper rungs.
      const schedule = <(String, VideoQualityPreset)>[
        ('原始', VideoQualityPreset.original),
        ('1080p', VideoQualityPreset.p1080),
        ('720p', VideoQualityPreset.p720),
        ('480p', VideoQualityPreset.p480),
        ('720p (重复)', VideoQualityPreset.p720),
      ];

      for (final (label, preset) in schedule) {
        final output = '${documents.path}/bench-out-${runs.length}.mp4';
        final result = await const MaxmediaVideoNative().compress(
          VideoCompressionRequest(
            inputPath: source.path,
            outputPath: output,
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            averageBitrate: preset.averageBitrate,
            maxShortSide: preset.maxShortSide,
            removeAudio: true,
          ),
        );

        expect(result.terminal, CompressionTerminal.succeeded, reason: label);
        final settings = result.actualSettings;
        final input = Map<String, Object?>.from(settings['input']! as Map);
        final out = Map<String, Object?>.from(settings['output']! as Map);

        runs.add(
          _Run(
            label: label,
            elapsedMilliseconds: result.elapsedMilliseconds,
            outputBytes: result.outputBytes,
            width: out['width']! as int,
            height: out['height']! as int,
            appliedBitrate: settings['averageBitrateApplied']! as int,
            sourceDurationSeconds:
                (input['durationMilliseconds']! as int) / 1000,
            frameRate: (input['nominalFrameRate']! as num).toDouble(),
          ),
        );

        await File(output).delete();
        // Let the media engine shed heat so the next rung starts from a
        // comparable thermal state.
        await Future<void>.delayed(const Duration(seconds: 20));
      }

      final buffer = StringBuffer()
        ..writeln('')
        ..writeln('=== 分辨率档位真机实测 ===')
        ..writeln(
          '源：$_sourceName  ${(sourceBytes / (1024 * 1024)).toStringAsFixed(2)} MiB  '
          '${runs.first.sourceDurationSeconds.toStringAsFixed(2)} s  '
          '${runs.first.frameRate.toStringAsFixed(2)} fps',
        )
        ..writeln(
          '档位        分辨率        耗时      倍速    编码fps   Mpx/s   输出MiB  码率',
        );
      for (final run in runs) {
        buffer.writeln(
          '${run.label.padRight(12)}'
          '${'${run.width}x${run.height}'.padRight(14)}'
          '${'${run.seconds.toStringAsFixed(2)}s'.padRight(10)}'
          '${'${run.realtimeFactor.toStringAsFixed(2)}x'.padRight(8)}'
          '${run.framesPerSecond.toStringAsFixed(1).padRight(10)}'
          '${run.megapixelsPerSecond.toStringAsFixed(0).padRight(8)}'
          '${run.outputMiB.toStringAsFixed(2).padRight(9)}'
          '${(run.appliedBitrate / 1e6).toStringAsFixed(2)} Mbps',
        );
      }

      final baseline = runs.first;
      for (final run in runs.skip(1)) {
        buffer.writeln(
          '${run.label} 相对原始档提速 '
          '${(baseline.seconds / run.seconds).toStringAsFixed(2)}x',
        );
      }
      final firstSevenTwenty = runs[2];
      final repeatSevenTwenty = runs.last;
      buffer.writeln(
        '热漂移对照：720p 首次 ${firstSevenTwenty.seconds.toStringAsFixed(2)}s '
        'vs 末次 ${repeatSevenTwenty.seconds.toStringAsFixed(2)}s '
        '(${((repeatSevenTwenty.seconds / firstSevenTwenty.seconds - 1) * 100).toStringAsFixed(1)}%)',
      );
      // ignore: avoid_print
      print(buffer.toString());

      expect(runs[2].width, 720, reason: '720p rung did not scale');
      expect(runs[3].width, 480, reason: '480p rung did not scale');
      expect(runs[1].width, 1080, reason: '1080p rung should not rescale');
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
