import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:path_provider/path_provider.dart';

import '../data/media_selection_service.dart';
import '../domain/image_compression_policy.dart';
import '../domain/video_quality_preset.dart';
import 'media_warning_text.dart';

/// Interactive batch playground: multi-pick images (native parallel batch,
/// concurrency configurable) and videos (sequential queue), with per-item
/// status rows and cancel buttons that exercise the plugin cancel contract.
class BatchSection extends StatefulWidget {
  const BatchSection({required this.mediaSelectionService, super.key});

  final MediaSelectionService mediaSelectionService;

  @override
  State<BatchSection> createState() => _BatchSectionState();
}

class _BatchSectionState extends State<BatchSection> {
  final _imageController = ImageBatchController(
    plugin: const MaxmediaImageNative(),
  );
  final _videoController = VideoBatchController(
    plugin: const MaxmediaVideoNative(),
  );
  int _maxConcurrent = 4;
  ImageFormat _imageFormat = ImageFormat.webp;
  Set<ImageFormat> _supportedImageFormats = {
    ImageFormat.webp,
    ImageFormat.jpeg,
  };
  VideoQualityPreset _videoPreset = VideoQualityPreset.p720;
  VideoBitrateBudget _videoBitrateBudget = VideoBitrateBudget.standard;
  VideoHdrPolicy _videoHdrPolicy = VideoHdrPolicy.keepOriginal;
  bool _busy = false;
  bool _listsExpanded = true;
  String? _batchError;
  int? _imageBatchMilliseconds;
  int? _videoBatchMilliseconds;
  StreamSubscription<ImageBatchState>? _imageSubscription;
  StreamSubscription<VideoBatchState>? _videoSubscription;
  final _imageAcquisitionMs = <int?>[];
  final _videoAcquisitionMs = <int?>[];

  @override
  void initState() {
    super.initState();
    _imageSubscription = _imageController.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _videoSubscription = _videoController.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _loadImageFormats();
  }

  Future<void> _loadImageFormats() async {
    try {
      final report = await const MaxmediaImageNative().capabilities();
      if (!mounted) return;
      setState(() {
        _supportedImageFormats = {
          for (final format in ImageFormat.values)
            if (report.formats.contains(format.name)) format,
        };
      });
    } catch (_) {
      // The always-supported baseline formats remain selectable.
    }
  }

  @override
  void dispose() {
    if (_imageSubscription != null) unawaited(_imageSubscription!.cancel());
    if (_videoSubscription != null) unawaited(_videoSubscription!.cancel());
    _imageController.dispose();
    _videoController.dispose();
    super.dispose();
  }

  Future<void> _pickAndCompressImages() async {
    setState(() {
      _busy = true;
      _batchError = null;
    });
    try {
      final documents = await getApplicationDocumentsDirectory();
      final selections = await widget.mediaSelectionService.pickImages();
      if (!mounted || selections.isEmpty) return;
      _imageAcquisitionMs
        ..clear()
        ..addAll([
          for (final s in selections) s.acquisitionElapsedMilliseconds,
        ]);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final extension = switch (_imageFormat) {
        ImageFormat.jpeg => 'jpg',
        ImageFormat.heic => 'heic',
        ImageFormat.png => 'png',
        ImageFormat.webp => 'webp',
      };
      final requests = [
        for (var index = 0; index < selections.length; index += 1)
          ImageCompressionPolicy.apply(
            ImageCompressionRequest(
              inputPath: selections[index].inputPath,
              outputPath: '${documents.path}/batch-$stamp-$index.$extension',
              format: _imageFormat,
              quality: 0.80,
              resizePolicy: ImageResizePolicy.social,
            ),
          ),
      ];
      _imageBatchMilliseconds = null;
      final watch = Stopwatch()..start();
      await _imageController.start(requests, maxConcurrent: _maxConcurrent);
      watch.stop();
      _imageBatchMilliseconds = watch.elapsedMilliseconds;
    } catch (error) {
      if (mounted) setState(() => _batchError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndQueueVideos() async {
    setState(() {
      _busy = true;
      _batchError = null;
    });
    try {
      final documents = await getApplicationDocumentsDirectory();
      final selections = await widget.mediaSelectionService.pickVideos();
      if (!mounted || selections.isEmpty) return;
      _videoAcquisitionMs
        ..clear()
        ..addAll([
          for (final s in selections) s.acquisitionElapsedMilliseconds,
        ]);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final requests = [
        for (var index = 0; index < selections.length; index += 1)
          VideoCompressionRequest(
            inputPath: selections[index].inputPath,
            outputPath: '${documents.path}/batch-v-$stamp-$index.mp4',
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            averageBitrate: _videoBitrateBudget.apply(_videoPreset),
            maxShortSide: _videoPreset.maxShortSide,
            removeAudio: false,
            hdrPolicy: _videoHdrPolicy,
          ),
      ];
      _videoBatchMilliseconds = null;
      final watch = Stopwatch()..start();
      await _videoController.start(requests);
      watch.stop();
      _videoBatchMilliseconds = watch.elapsedMilliseconds;
    } catch (error) {
      if (mounted) setState(() => _batchError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _CapabilityCard(
    title: '批量压缩（多选）',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_batchError != null)
          Text(
            _batchError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            onPressed: _busy ? null : _pickAndCompressImages,
            child: const Text('多选图片压缩'),
          ),
        ),
        ExpansionTile(
          key: const ValueKey('batch-image-advanced-options'),
          title: const Text('批量图片高级选项'),
          subtitle: Text(
            '${_imageFormat.name.toUpperCase()} · $_maxConcurrent 张并发',
          ),
          children: [
            Row(
              children: [
                const Text('图片并发数'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _maxConcurrent,
                  items: [
                    for (final value in const [1, 2, 4, 6])
                      DropdownMenuItem(value: value, child: Text('$value')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _maxConcurrent = value ?? 4),
                ),
              ],
            ),
            DropdownButtonFormField<ImageFormat>(
              initialValue: _imageFormat,
              decoration: const InputDecoration(labelText: '批量图片格式'),
              items: [
                for (final format in [
                  ImageFormat.webp,
                  ImageFormat.jpeg,
                  ImageFormat.heic,
                ])
                  if (_supportedImageFormats.contains(format))
                    DropdownMenuItem(
                      value: format,
                      child: Text(format.name.toUpperCase()),
                    ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _imageFormat = value);
                    },
            ),
          ],
        ),
        if (_imageController.currentState != null) ...[
          if (_imageAcquisitionMs.isNotEmpty &&
              _imageAcquisitionMs.first != null)
            Text(
              '图片选取/获取共 ${(_imageAcquisitionMs.first! / 1000).toStringAsFixed(2)} s',
            ),
          if (_imageBatchMilliseconds != null)
            Text(
              '图片批次处理共 ${(_imageBatchMilliseconds! / 1000).toStringAsFixed(2)} s',
            ),
          _listHeader(
            '图片（${_imageController.currentState!.settledCount}'
            '/${_imageController.currentState!.totalCount}）',
          ),
          if (_listsExpanded)
            ..._imageController.currentState!.items.map(
              (item) => _ImageBatchRow(
                item: item,
                onCancel: () => _imageController.cancelItem(item.index),
              ),
            ),
          if (_listsExpanded && !_imageController.currentState!.isFinished)
            TextButton(
              onPressed: () => _imageController.cancelAll(),
              child: const Text('全部取消'),
            ),
        ],
        const Divider(height: 24),
        ExpansionTile(
          key: const ValueKey('batch-video-advanced-options'),
          title: const Text('批量视频高级选项'),
          subtitle: Text(
            '${_videoPreset.label} · ${_videoBitrateBudget.label} · 保留声音',
          ),
          children: [
            DropdownButtonFormField<VideoQualityPreset>(
              initialValue: _videoPreset,
              decoration: const InputDecoration(labelText: '批量视频分辨率'),
              items: [
                for (final preset in VideoQualityPreset.values)
                  DropdownMenuItem(value: preset, child: Text(preset.label)),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _videoPreset = value);
                    },
            ),
            DropdownButtonFormField<VideoBitrateBudget>(
              initialValue: _videoBitrateBudget,
              decoration: const InputDecoration(labelText: '批量视频目标码率'),
              items: [
                for (final budget in VideoBitrateBudget.values)
                  DropdownMenuItem(value: budget, child: Text(budget.label)),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _videoBitrateBudget = value);
                      }
                    },
            ),
            Text(
              '当前请求 ${(_videoBitrateBudget.apply(_videoPreset) / 1000000).toStringAsFixed(2)} Mbps；降低码率会损失画面细节。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!Platform.isAndroid) ...[
              DropdownButtonFormField<VideoHdrPolicy>(
                key: const ValueKey('batch-video-hdr-policy'),
                initialValue: _videoHdrPolicy,
                decoration: const InputDecoration(labelText: '批量视频 HDR 处理'),
                items: [
                  for (final policy in VideoHdrPolicy.values)
                    DropdownMenuItem(
                      value: policy,
                      child: Text(videoHdrPolicyLabel(policy)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _videoHdrPolicy = value);
                        }
                      },
              ),
              Text(
                'HDR 默认跳过压缩并保留原片，避免未经验证的色彩变化。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        Row(
          children: [
            const Expanded(child: Text('视频按队列逐条编码（可取消当前/全部）')),
            FilledButton.tonal(
              onPressed: _busy ? null : _pickAndQueueVideos,
              child: const Text('多选视频排队'),
            ),
          ],
        ),
        if (_videoController.currentState != null) ...[
          if (_videoBatchMilliseconds != null)
            Text(
              '视频队列处理共 ${(_videoBatchMilliseconds! / 1000).toStringAsFixed(2)} s',
            ),
          _listHeader(
            '视频（${_videoController.currentState!.settledCount}'
            '/${_videoController.currentState!.totalCount}）',
          ),
          if (_listsExpanded)
            ..._videoController.currentState!.items.map(
              (item) => _VideoQueueRow(
                item,
                acquisitionMs: item.index < _videoAcquisitionMs.length
                    ? _videoAcquisitionMs[item.index]
                    : null,
              ),
            ),
          if (_listsExpanded && !_videoController.currentState!.isFinished)
            TextButton(
              onPressed: () => _videoController.cancelAll(),
              child: const Text('全部取消'),
            ),
        ],
      ],
    ),
  );

  Widget _listHeader(String label) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(label, style: Theme.of(context).textTheme.bodySmall),
    trailing: IconButton(
      icon: Icon(_listsExpanded ? Icons.expand_less : Icons.expand_more),
      onPressed: () => setState(() => _listsExpanded = !_listsExpanded),
    ),
  );
}

String _batchStatusLabel(ImageBatchItemStatus status) => switch (status) {
  ImageBatchItemStatus.queued => '排队中',
  ImageBatchItemStatus.succeeded => '成功',
  ImageBatchItemStatus.cancelled => '已取消',
  ImageBatchItemStatus.failed => '失败',
};

String _videoStatusLabel(VideoQueueItemStatus status) => switch (status) {
  VideoQueueItemStatus.queued => '排队中',
  VideoQueueItemStatus.running => '编码中',
  VideoQueueItemStatus.succeeded => '成功',
  VideoQueueItemStatus.cancelled => '已取消',
  VideoQueueItemStatus.failed => '失败',
};

String _acquisitionSuffix(int? acquisitionMs) => acquisitionMs == null
    ? ''
    : ' · 选取/获取累计 ${(acquisitionMs / 1000).toStringAsFixed(2)} s';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MiB';
}

class _ImageBatchRow extends StatefulWidget {
  const _ImageBatchRow({required this.item, required this.onCancel});

  final ImageBatchItemState item;
  final VoidCallback onCancel;

  @override
  State<_ImageBatchRow> createState() => _ImageBatchRowState();
}

class _ImageBatchRowState extends State<_ImageBatchRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final result = item.result;
    final summary = switch (item.status) {
      ImageBatchItemStatus.succeeded when result != null =>
        '${_formatBytes(result.outputBytes)} · ${result.elapsedMilliseconds} ms',
      ImageBatchItemStatus.queued => '等待中',
      ImageBatchItemStatus.cancelled => '已取消并释放资源',
      ImageBatchItemStatus.failed => localizedImageError(item.error),
      _ => '',
    };
    final name = item.request.inputPath.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          onTap: () => setState(() => _expanded = !_expanded),
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_batchStatusLabel(item.status)} · $summary',
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.status == ImageBatchItemStatus.queued)
                TextButton(onPressed: widget.onCancel, child: const Text('取消'))
              else
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
            ],
          ),
        ),
        if (_expanded && result != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              '原始 ${_formatBytes(result.inputBytes)} → 压缩后 '
              '${_formatBytes(result.outputBytes)}'
              '（减少 ${((1 - result.compressionRatio) * 100).toStringAsFixed(1)}%）'
              ' · 压缩耗时 ${result.elapsedMilliseconds} ms'
              ' · 原生总耗时 ${result.actualSettings['totalElapsedMilliseconds'] ?? result.elapsedMilliseconds} ms'
              ' · ${result.actualSettings['width']}×${result.actualSettings['height']}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _VideoQueueRow extends StatefulWidget {
  const _VideoQueueRow(this.item, {required this.acquisitionMs});

  final VideoQueueItemState item;
  final int? acquisitionMs;

  @override
  State<_VideoQueueRow> createState() => _VideoQueueRowState();
}

class _VideoQueueRowState extends State<_VideoQueueRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final progress = item.progress;
    final warnings = item.result == null
        ? const <String>[]
        : batchVideoWarnings(item.result!.warnings);
    final colorRisk =
        item.result != null && hasVideoColorRisk(item.result!.warnings);
    final name = item.request.inputPath.split('/').last;
    final summary = switch (item.status) {
      VideoQueueItemStatus.running =>
        progress == null
            ? '准备中…'
            : '${(progress.fraction * 100).toStringAsFixed(0)}% · ${progress.stage}',
      VideoQueueItemStatus.succeeded =>
        '${_formatBytes(item.result?.outputBytes ?? 0)}'
            ' · ${item.result?.elapsedMilliseconds ?? 0} ms',
      VideoQueueItemStatus.queued => '等待中',
      VideoQueueItemStatus.cancelled => '已取消',
      VideoQueueItemStatus.failed => localizedVideoError(item.error),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          onTap: () => setState(() => _expanded = !_expanded),
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_videoStatusLabel(item.status)} · $summary',
            overflow: TextOverflow.ellipsis,
          ),
          trailing: item.status == VideoQueueItemStatus.running
              ? ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 80),
                  child: LinearProgressIndicator(value: progress?.fraction),
                )
              : Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
        ),
        if (_expanded && item.result != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              '原始 ${_formatBytes(item.result!.inputBytes)} → 压缩后 '
              '${_formatBytes(item.result!.outputBytes)}'
              '（减少 ${((1 - item.result!.compressionRatio) * 100).toStringAsFixed(1)}%）'
              ' · 压缩耗时 ${(item.result!.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
              '${_acquisitionSuffix(widget.acquisitionMs)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_expanded && warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              '${colorRisk ? '画质提醒' : '编码说明'}：${warnings.join('；')}',
              style: TextStyle(
                color: colorRisk
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}
