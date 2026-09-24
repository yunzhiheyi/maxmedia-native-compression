import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:path_provider/path_provider.dart';

/// Separates the 10→8 bit colour-conversion cost from the hardware decode
/// floor (`EV-MEDIA-000` items 13b/15).
///
/// The two inputs are the *same* synthetic content, encoded by the same
/// encoder at the same bitrate, differing only in bit depth and colour tags:
///
///   10-bit HLG (HDR):
///   ffmpeg -y -f lavfi -i "testsrc2=size=1080x1920:rate=30:duration=120" \
///     -vf "noise=alls=14:allf=t,format=yuv420p10le" \
///     -c:v libx265 -preset medium -b:v 9M -pix_fmt yuv420p10le \
///     -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
///     -colorspace bt2020nc -movflags +write_colr -tag:v hvc1 \
///     bench-hdr-10bit-hlg.mp4
///
///   8-bit BT.709 (SDR):
///   ffmpeg -y -f lavfi -i "testsrc2=size=1080x1920:rate=30:duration=120" \
///     -vf "noise=alls=14:allf=t" \
///     -c:v libx265 -preset medium -b:v 9M -pix_fmt yuv420p \
///     -x265-params "colorprim=bt709:transfer=bt709:colormatrix=bt709" \
///     -colorspace bt709 -movflags +write_colr -tag:v hvc1 \
///     bench-sdr-8bit-bt709.mp4
///
///   xcrun devicectl device copy to --device UDID \
///     --domain-type appDataContainer \
///     --domain-identifier cc.maxmax.maxmediaRouteLab \
///     --source bench-hdr-10bit-hlg.mp4 --destination Documents/
///   (repeat for bench-sdr-8bit-bt709.mp4)
///
/// Operational notes learned the hard way on 2026-09-21:
/// - Run via `flutter test integration_test/video_hdr_sdr_benchmark_test.dart`
///   with `-d` set to the iPhone UDID. The tool attaches a debugger to the
///   app; this REQUIRES the phone to be unlocked (a locked phone accepts
///   plain launches but resets the VM-service websocket: "Failed to load …
///   Connection reset by peer"). If every run fails that way, unlock/reboot
///   the phone first.
/// - `flutter test` builds the Debug configuration. The comparison inside
///   this experiment is still internally valid (all conditions share the
///   config), but do not mix these numbers with the Release figures in
///   `EV-MEDIA-000` without re-measuring.
/// - Installing an app built from a *different* source build (another build
///   directory, flutter drive, …) wipes the app data container and the pushed
///   sources with it. Push the sources after the install that `flutter test`
///   performs: run once (fails fast on the missing-file expect), push both
///   files, then run again — the second, same-lineage install keeps the
///   container.
/// - Launching the app directly (`devicectl device process launch`) does NOT
///   execute integration tests; only the tool-driven flows do.
///
/// Every run uses the 720p rung, which item 13 showed sits on the decode
/// floor, so a reader-side difference between the two sources is decode-path
/// cost, not encoder cost. The tone-map condition additionally prices the
/// colour-correct HDR route against the raw 10→8 conversion. Conditions run
/// most-expensive first and repeat in reverse order, so thermal drift appears
/// as a gap between the two runs of each condition instead of masquerading as
/// a bit-depth effect.
const _hdrSourceName = 'bench-hdr-10bit-hlg.mp4';
const _sdrSourceName = 'bench-sdr-8bit-bt709.mp4';
const _maxShortSide = 720;
const _averageBitrate = 2_000_000;

final class _Run {
  _Run({
    required this.label,
    required this.elapsedMilliseconds,
    required this.outputBytes,
    required this.width,
    required this.sampleCount,
    required this.readerCallMilliseconds,
    required this.writerAppendMilliseconds,
    required this.writerBackpressureMilliseconds,
    required this.finishWritingMilliseconds,
    required this.sourceDurationSeconds,
    required this.frameRate,
  });

  final String label;
  final int elapsedMilliseconds;
  final int outputBytes;
  final int width;
  final int sampleCount;
  final double readerCallMilliseconds;
  final double writerAppendMilliseconds;
  final double writerBackpressureMilliseconds;
  final double finishWritingMilliseconds;
  final double sourceDurationSeconds;
  final double frameRate;

  double get seconds => elapsedMilliseconds / 1000;
  double get framesPerSecond => sourceDurationSeconds * frameRate / seconds;
  double get outputMiB => outputBytes / (1024 * 1024);

  /// Reader wall time per frame. The loop is serial, so when the pipeline is
  /// decode-bound this is where waiting for the decoder shows up.
  double get readerCallPerFrameMs =>
      sampleCount > 0 ? readerCallMilliseconds / sampleCount : 0;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'HDR 10-bit vs SDR 8-bit decode floor on device',
    (tester) async {
      final documents = await getApplicationDocumentsDirectory();
      final hdrSource = File('${documents.path}/$_hdrSourceName');
      final sdrSource = File('${documents.path}/$_sdrSourceName');
      for (final source in [hdrSource, sdrSource]) {
        expect(
          await source.exists(),
          isTrue,
          reason:
              'Missing ${source.path}. Push it with devicectl first; see the '
              'header of this file for the exact commands.',
        );
      }

      final runs = <_Run>[];

      Future<_Run> compressOnce(
        String label,
        File source,
        VideoHdrPolicy hdrPolicy,
      ) async {
        final output =
            '${documents.path}/hdr-sdr-out-${runs.length}.mp4';
        final result = await const MaxmediaVideoNative().compress(
          VideoCompressionRequest(
            inputPath: source.path,
            outputPath: output,
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            averageBitrate: _averageBitrate,
            maxShortSide: _maxShortSide,
            removeAudio: true,
            hdrPolicy: hdrPolicy,
          ),
        );

        expect(result.terminal, CompressionTerminal.succeeded, reason: label);
        final settings = result.actualSettings;
        final input = Map<String, Object?>.from(settings['input']! as Map);
        final out = Map<String, Object?>.from(settings['output']! as Map);
        final performance =
            Map<String, Object?>.from(settings['performance']! as Map);

        final sourceIsHdr = settings['sourceHdrDetected']! as bool;
        final hdrHandling = settings['hdrHandling']! as String;
        if (source == hdrSource) {
          expect(sourceIsHdr, isTrue,
              reason: '$label: HDR source was not detected as HDR');
          expect(
            hdrHandling,
            hdrPolicy == VideoHdrPolicy.toneMapToSdr
                ? 'tone-map-to-sdr'
                : 'none',
            reason: label,
          );
        } else {
          expect(sourceIsHdr, isFalse,
              reason: '$label: SDR source was unexpectedly detected as HDR');
          expect(hdrHandling, 'none', reason: label);
        }

        final run = _Run(
          label: label,
          elapsedMilliseconds: result.elapsedMilliseconds,
          outputBytes: result.outputBytes,
          width: out['width']! as int,
          sampleCount: (performance['sampleCount']! as num).toInt(),
          readerCallMilliseconds:
              (performance['readerCallMilliseconds']! as num).toDouble(),
          writerAppendMilliseconds:
              (performance['writerAppendMilliseconds']! as num).toDouble(),
          writerBackpressureMilliseconds:
              (performance['writerBackpressureMilliseconds']! as num)
                  .toDouble(),
          finishWritingMilliseconds:
              (performance['finishWritingMilliseconds']! as num).toDouble(),
          sourceDurationSeconds:
              (input['durationMilliseconds']! as int) / 1000,
          frameRate: (input['nominalFrameRate']! as num).toDouble(),
        );
        await File(output).delete();
        return run;
      }

      // Most expensive first, then the same conditions in reverse: per-
      // condition thermal drift is the spread between its own two runs.
      // Schedule: HDR直读, HDR转SDR, SDR直读, SDR直读, HDR转SDR, HDR直读.
      final conditions = <(String, File, VideoHdrPolicy)>[
        ('HDR直读', hdrSource, VideoHdrPolicy.allowWithWarning),
        ('HDR转SDR', hdrSource, VideoHdrPolicy.toneMapToSdr),
        ('SDR直读', sdrSource, VideoHdrPolicy.allowWithWarning),
      ];
      final plan = [...conditions, ...conditions.reversed];

      for (final (label, source, hdrPolicy) in plan) {
        runs.add(await compressOnce(label, source, hdrPolicy));
        // Let the media engine shed heat so the next run starts from a
        // comparable thermal state.
        await Future<void>.delayed(const Duration(seconds: 20));
      }

      final buffer = StringBuffer()
        ..writeln('')
        ..writeln('=== HDR/SDR 解码地板分离真机实测 ===')
        ..writeln(
          '档位：720p / H.264 / 2 Mbps；源 1080x1920 30fps 120s '
          '10-bit HLG 与 8-bit BT.709，同编码器同码率',
        )
        ..writeln(
          '条件          耗时      fps    取帧/帧(ms)  追加/帧(ms) 背压(ms)  收尾(ms)  输出MiB',
        );
      for (final run in runs) {
        buffer.writeln(
          '${run.label.padRight(12)}'
          '${'${run.seconds.toStringAsFixed(2)}s'.padRight(10)}'
          '${run.framesPerSecond.toStringAsFixed(1).padRight(7)}'
          '${run.readerCallPerFrameMs.toStringAsFixed(3).padRight(13)}'
          '${(run.sampleCount > 0
                  ? run.writerAppendMilliseconds / run.sampleCount
                  : 0)
              .toStringAsFixed(3)
              .padRight(11)}'
          '${run.writerBackpressureMilliseconds
              .toStringAsFixed(0)
              .padRight(9)}'
          '${run.finishWritingMilliseconds
              .toStringAsFixed(0)
              .padRight(9)}'
          '${run.outputMiB.toStringAsFixed(2)}',
        );
      }

      double averageSeconds(int index) =>
          (runs[index].seconds + runs[index + 3].seconds) / 2;
      final hdrRaw = averageSeconds(0);
      final hdrToneMap = averageSeconds(1);
      final sdr = averageSeconds(2);
      buffer
        ..writeln(
          '每条件首末两次展开（热漂移）：'
          'HDR直读 ${runs[0].seconds.toStringAsFixed(2)}/${runs[3 + 0].seconds.toStringAsFixed(2)}s，'
          'HDR转SDR ${runs[1].seconds.toStringAsFixed(2)}/${runs[3 + 1].seconds.toStringAsFixed(2)}s，'
          'SDR直读 ${runs[2].seconds.toStringAsFixed(2)}/${runs[3 + 2].seconds.toStringAsFixed(2)}s',
        )
        ..writeln(
          '均值：HDR直读 ${hdrRaw.toStringAsFixed(2)}s，'
          'HDR转SDR ${hdrToneMap.toStringAsFixed(2)}s，'
          'SDR直读 ${sdr.toStringAsFixed(2)}s；'
          '10bit差值 ${(hdrRaw - sdr).toStringAsFixed(2)}s，'
          'tone-map差值 ${(hdrToneMap - hdrRaw).toStringAsFixed(2)}s',
        );
      // ignore: avoid_print
      print(buffer.toString());

      expect(runs.every((run) => run.width == 720), isTrue,
          reason: 'every run must land on the 720p rung');
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
