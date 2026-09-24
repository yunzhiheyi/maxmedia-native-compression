import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_route_contracts/media_route_contracts.dart';
import 'package:video_player/video_player.dart';

import 'media_warning_text.dart';
import 'route_lab_view_model.dart';

class ResultSummary extends StatelessWidget {
  const ResultSummary({
    required this.result,
    required this.kind,
    required this.inputPath,
    super.key,
  });

  final CompressionResult result;
  final MediaResultKind kind;
  final String inputPath;

  @override
  Widget build(BuildContext context) {
    final settings = result.actualSettings;
    final input = _inputSettings(settings);
    final output = _outputSettings(settings);
    final performance = _stringMap(settings['performance']);
    final hdrHandling = settings['hdrHandling']?.toString();
    final savedFraction = 1 - result.compressionRatio;
    final savedText = savedFraction >= 0
        ? '体积减少 ${(savedFraction * 100).toStringAsFixed(1)}%'
        : '体积增加 ${(-savedFraction * 100).toStringAsFixed(1)}%';
    final reduced = result.outputBytes < result.inputBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: reduced
              ? Theme.of(context).colorScheme.secondaryContainer
              : Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  reduced
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_rounded,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reduced ? '压缩完成' : '未达到压缩目标',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '$savedText · 耗时 ${_duration(result.elapsedMilliseconds)}',
                      ),
                      if (!reduced) const Text('输出文件不应替换原文件，请降低目标码率后重试。'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('原文件与压缩结果', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _PreviewComparison(
          kind: kind,
          inputPath: inputPath,
          outputPath: result.outputPath,
        ),
        const SizedBox(height: 12),
        _MetricsTable(
          kind: kind,
          inputPath: inputPath,
          inputBytes: result.inputBytes,
          outputBytes: result.outputBytes,
          input: input,
          output: output,
        ),
        if (kind == MediaResultKind.video && performance.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('性能诊断', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '取帧调用 ${_performanceDuration(performance, 'readerCallMilliseconds')} · '
                    '写入等待 ${_performanceDuration(performance, 'writerBackpressureMilliseconds')} · '
                    '写入提交 ${_performanceDuration(performance, 'writerAppendMilliseconds')} · '
                    '收尾 ${_performanceDuration(performance, 'finishWritingMilliseconds')}',
                  ),
                  const Text('以上为调用与等待耗时，不能直接等同硬件解码或编码耗时。'),
                ],
              ),
            ),
          ),
        ],
        if (kind == MediaResultKind.video &&
            hdrHandling == 'tone-map-to-sdr') ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('HDR 处理：已转换为 SDR BT.709 后再编码 H.264。'),
            ),
          ),
        ],
        if (result.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '说明：${result.warnings.map(localizedMediaWarning).join('；')}',
              ),
            ),
          ),
        ],
      ],
    );
  }

  Map<String, Object?> _inputSettings(Map<String, Object?> settings) {
    final nested = _stringMap(settings['input']);
    if (nested.isNotEmpty) return nested;
    return {
      'width': settings['inputWidth'],
      'height': settings['inputHeight'],
      if (kind == MediaResultKind.image) 'format': _extension(inputPath),
    };
  }

  Map<String, Object?> _outputSettings(Map<String, Object?> settings) {
    final nested = _stringMap(settings['output']);
    return nested.isEmpty ? settings : nested;
  }
}

class _PreviewComparison extends StatelessWidget {
  const _PreviewComparison({
    required this.kind,
    required this.inputPath,
    required this.outputPath,
  });

  final MediaResultKind kind;
  final String inputPath;
  final String outputPath;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: _PreviewCard(
          label: '原文件',
          child: kind == MediaResultKind.image
              ? _ImagePreview(path: inputPath)
              : _VideoPreview(path: inputPath),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _PreviewCard(
          label: '压缩后',
          child: kind == MediaResultKind.image
              ? _ImagePreview(path: outputPath)
              : _VideoPreview(path: outputPath),
        ),
      ),
    ],
  );
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(aspectRatio: 16 / 10, child: child),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(label, textAlign: TextAlign.center),
        ),
      ],
    ),
  );
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (_, error, stackTrace) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white),
      ),
    ),
  );
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.path});

  final String path;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late VideoPlayerController controller;
  late Future<void> initialization;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      controller.dispose();
      _initialize();
    }
  }

  void _initialize() {
    controller = VideoPlayerController.file(File(widget.path));
    initialization = controller.initialize().then((_) {
      controller.setLooping(true);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: FutureBuilder<void>(
      future: initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Icon(Icons.videocam_off_outlined, color: Colors.white),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
            Center(
              child: IconButton.filledTonal(
                icon: Icon(
                  controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                onPressed: () {
                  setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  });
                },
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _MetricsTable extends StatelessWidget {
  const _MetricsTable({
    required this.kind,
    required this.inputPath,
    required this.inputBytes,
    required this.outputBytes,
    required this.input,
    required this.output,
  });

  final MediaResultKind kind;
  final String inputPath;
  final int inputBytes;
  final int outputBytes;
  final Map<String, Object?> input;
  final Map<String, Object?> output;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String, String)>[
      ('文件大小', _bytes(inputBytes), _bytes(outputBytes)),
      (
        '格式',
        _text(input['codec'] ?? input['format'] ?? _extension(inputPath)),
        _text(output['codec'] ?? output['format']),
      ),
      ('分辨率', _resolution(input), _resolution(output)),
      if (kind == MediaResultKind.image && _quality(output) != '—')
        ('编码质量', '原始', _quality(output)),
      if (kind == MediaResultKind.video) ...[
        ('帧率', _frameRate(input), _frameRate(output)),
        ('视频码率', _bitrate(input), _bitrate(output)),
        ('时长', _mediaDuration(input), _mediaDuration(output)),
        if (input['colorPrimaries'] != null || output['colorPrimaries'] != null)
          (
            '色域',
            _videoColorLabel(input['colorPrimaries']),
            _videoColorLabel(output['colorPrimaries']),
          ),
        if (input['transferFunction'] != null ||
            output['transferFunction'] != null)
          (
            '亮度曲线',
            _videoColorLabel(input['transferFunction']),
            _videoColorLabel(output['transferFunction']),
          ),
      ],
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Table(
          columnWidths: const {
            0: FixedColumnWidth(74),
            1: FlexColumnWidth(),
            2: FlexColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            _row(context, '指标', '原文件', '压缩后', header: true),
            for (final row in rows) _row(context, row.$1, row.$2, row.$3),
          ],
        ),
      ),
    );
  }

  TableRow _row(
    BuildContext context,
    String label,
    String before,
    String after, {
    bool header = false,
  }) {
    final style = header ? Theme.of(context).textTheme.labelLarge : null;
    Widget cell(String value) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(value, style: style),
    );
    return TableRow(children: [cell(label), cell(before), cell(after)]);
  }
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return {for (final entry in value.entries) entry.key.toString(): entry.value};
}

String _resolution(Map<String, Object?> value) {
  final width = (value['width'] as num?)?.round();
  final height = (value['height'] as num?)?.round();
  return width == null || height == null ? '—' : '$width×$height';
}

String _frameRate(Map<String, Object?> value) {
  final rate = value['nominalFrameRate'] as num?;
  return rate == null ? '—' : '${rate.toDouble().toStringAsFixed(2)} fps';
}

String _bitrate(Map<String, Object?> value) {
  final rate = value['estimatedDataRate'] as num?;
  return rate == null
      ? '—'
      : '${(rate.toDouble() / 1000000).toStringAsFixed(2)} Mbps';
}

String _videoColorLabel(Object? value) {
  if (value == null) return '—';
  final raw = value.toString();
  final normalized = raw.toUpperCase();
  if (normalized.contains('2100_HLG') || normalized.contains('HLG')) {
    return 'HLG';
  }
  if (normalized.contains('2084') || normalized.contains('PQ')) {
    return 'PQ';
  }
  if (normalized.contains('2020')) return 'BT.2020';
  if (normalized.contains('709')) return 'BT.709';
  if (normalized.contains('P3')) return 'P3';
  return raw;
}

String _mediaDuration(Map<String, Object?> value) {
  final milliseconds = value['durationMilliseconds'] as num?;
  return milliseconds == null ? '—' : _duration(milliseconds.round());
}

String _quality(Map<String, Object?> value) {
  final quality = value['qualityApplied'] ?? value['quality'];
  if (quality is! num) return '—';
  return '${(quality.toDouble() * 100).round()}%';
}

String _duration(int milliseconds) {
  if (milliseconds < 1000) return '$milliseconds ms';
  return '${(milliseconds / 1000).toStringAsFixed(2)} s';
}

String _performanceDuration(Map<String, Object?> values, String key) {
  final milliseconds = values[key];
  if (milliseconds is! num) return '—';
  return '${(milliseconds.toDouble() / 1000).toStringAsFixed(2)} s';
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
}

String _extension(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '—' : name.substring(dot + 1).toUpperCase();
}

String _text(Object? value) {
  return switch (value?.toString().toLowerCase()) {
    'h264' => 'H.264',
    'hevc' => 'HEVC',
    'jpeg' || 'jpg' => 'JPEG',
    'png' => 'PNG',
    'webp' => 'WebP',
    'heic' => 'HEIC',
    final text? => text.toUpperCase(),
    null => '—',
  };
}
