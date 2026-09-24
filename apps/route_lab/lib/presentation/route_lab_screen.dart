import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

import '../data/media_selection_service.dart';
import '../domain/video_quality_preset.dart';
import 'batch_section.dart';
import 'media_warning_text.dart';
import 'result_summary.dart';
import 'route_lab_view_model.dart';

class RouteLabScreen extends StatefulWidget {
  const RouteLabScreen({
    required this.viewModel,
    required this.mediaSelectionService,
    super.key,
  });

  final RouteLabViewModel viewModel;
  final MediaSelectionService mediaSelectionService;

  @override
  State<RouteLabScreen> createState() => _RouteLabScreenState();
}

class _RouteLabScreenState extends State<RouteLabScreen> {
  final imageInput = TextEditingController();
  final imageOutput = TextEditingController();
  final videoInput = TextEditingController();
  final videoOutput = TextEditingController();
  String? selectedImageName;
  String? selectedVideoName;
  String? selectedVideoAcquisitionSummary;
  ImageFormat selectedImageFormat = ImageFormat.webp;
  ImageResizePolicy selectedImageResizePolicy = ImageResizePolicy.social;
  VideoQualityPreset selectedVideoPreset = VideoQualityPreset.p720;
  VideoBitrateBudget selectedVideoBitrateBudget = VideoBitrateBudget.standard;
  VideoHdrPolicy selectedVideoHdrPolicy = VideoHdrPolicy.keepOriginal;
  bool isPicking = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.loadCapabilities();
  }

  @override
  void dispose() {
    imageInput.dispose();
    imageOutput.dispose();
    videoInput.dispose();
    videoOutput.dispose();
    widget.viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('MaxMedia Route Lab')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '选择一个本地媒体文件，应用会自动生成临时输出路径。能力详情仅用于技术验证。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          _CapabilityCard(
            title: '图片原生路线',
            report: widget.viewModel.imageCapability,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('pick-image'),
            onPressed: isPicking || widget.viewModel.isBusy ? null : _pickImage,
            icon: const Icon(Icons.image_outlined),
            label: Text(selectedImageName ?? '选择图片'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ImageFormat>(
            key: const ValueKey('image-output-format'),
            initialValue: selectedImageFormat,
            decoration: const InputDecoration(
              labelText: '输出格式',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final format in ImageFormat.values)
                DropdownMenuItem(
                  value: format,
                  enabled: _supportsImageFormat(format),
                  child: Text(_imageFormatLabel(format)),
                ),
            ],
            onChanged: widget.viewModel.isBusy ? null : _changeImageFormat,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ImageResizePolicy>(
            key: const ValueKey('image-resize-policy'),
            initialValue: selectedImageResizePolicy,
            decoration: const InputDecoration(
              labelText: '图片尺寸策略',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final policy in ImageResizePolicy.values)
                DropdownMenuItem(
                  value: policy,
                  child: Text(_imageResizePolicyLabel(policy)),
                ),
            ],
            onChanged: widget.viewModel.isBusy
                ? null
                : (policy) {
                    if (policy == null) return;
                    widget.viewModel.clearResult();
                    setState(() => selectedImageResizePolicy = policy);
                  },
          ),
          const SizedBox(height: 6),
          Text(
            _imageResizePolicyHint(selectedImageResizePolicy),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _PathField(
            controller: imageInput,
            label: '图片输入绝对路径',
            onChanged: (_) => setState(() {}),
          ),
          _PathField(
            controller: imageOutput,
            label: '图片输出绝对路径（${_imageFormatLabel(selectedImageFormat)}）',
            onChanged: (_) => setState(() {}),
          ),
          FilledButton(
            key: const ValueKey('compress-image'),
            onPressed:
                widget.viewModel.isBusy ||
                    !_hasImagePaths ||
                    !_supportsImageFormat(selectedImageFormat)
                ? null
                : _compressImage,
            child: Text(
              widget.viewModel.phase == RouteLabPhase.runningImage
                  ? '图片压缩中…'
                  : selectedImageResizePolicy == ImageResizePolicy.original
                  ? '执行原尺寸压缩'
                  : '执行标准压缩',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'WebP 推荐质量 80，JPEG/HEIC 推荐质量 75；所有策略都保持宽高比且不放大。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          ..._resultSection(MediaResultKind.image),
          const Divider(height: 40),
          BatchSection(mediaSelectionService: widget.mediaSelectionService),
          const Divider(height: 40),
          _CapabilityCard(
            title: '视频原生路线',
            report: widget.viewModel.videoCapability,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('pick-video'),
            onPressed: isPicking || widget.viewModel.isBusy ? null : _pickVideo,
            icon: const Icon(Icons.video_file_outlined),
            label: Text(isPicking ? '正在准备媒体文件…' : selectedVideoName ?? '选择视频'),
          ),
          if (selectedVideoAcquisitionSummary case final summary?) ...[
            const SizedBox(height: 6),
            Text(summary, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<VideoQualityPreset>(
            key: const ValueKey('video-output-resolution'),
            initialValue: selectedVideoPreset,
            decoration: const InputDecoration(
              labelText: '输出分辨率',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final preset in VideoQualityPreset.values)
                DropdownMenuItem(value: preset, child: Text(preset.label)),
            ],
            onChanged: widget.viewModel.isBusy ? null : _changeVideoPreset,
          ),
          const SizedBox(height: 6),
          Text(
            selectedVideoPreset.hint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<VideoBitrateBudget>(
            key: const ValueKey('video-bitrate-budget'),
            initialValue: selectedVideoBitrateBudget,
            decoration: const InputDecoration(
              labelText: '目标码率',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final budget in VideoBitrateBudget.values)
                DropdownMenuItem(value: budget, child: Text(budget.label)),
            ],
            onChanged: widget.viewModel.isBusy
                ? null
                : (budget) {
                    if (budget == null) return;
                    widget.viewModel.clearResult();
                    setState(() => selectedVideoBitrateBudget = budget);
                  },
          ),
          const SizedBox(height: 6),
          Text(
            '当前请求 ${(selectedVideoBitrateBudget.apply(selectedVideoPreset) / 1000000).toStringAsFixed(2)} Mbps；更低码率通常能缩小文件，但会损失画面细节。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<VideoHdrPolicy>(
            key: const ValueKey('video-hdr-policy'),
            initialValue: selectedVideoHdrPolicy,
            decoration: const InputDecoration(
              labelText: 'HDR 输入策略',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final policy in VideoHdrPolicy.values)
                DropdownMenuItem(
                  value: policy,
                  child: Text(videoHdrPolicyLabel(policy)),
                ),
            ],
            onChanged: widget.viewModel.isBusy
                ? null
                : (policy) {
                    if (policy == null) return;
                    widget.viewModel.clearResult();
                    setState(() => selectedVideoHdrPolicy = policy);
                  },
          ),
          const SizedBox(height: 6),
          Text(
            'HDR 默认保留原片，不做可能变色的转码；如需转 SDR 或继续压缩，请显式选择。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _PathField(
            controller: videoInput,
            label: '视频输入绝对路径',
            onChanged: (_) => setState(() {}),
          ),
          _PathField(
            controller: videoOutput,
            label: '视频输出绝对路径（MP4）',
            onChanged: (_) => setState(() {}),
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('compress-video'),
                  onPressed: widget.viewModel.isBusy || !_hasVideoPaths
                      ? null
                      : _compressVideo,
                  child: Text(
                    widget.viewModel.phase == RouteLabPhase.runningVideo
                        ? '压缩中 ${(100 * (widget.viewModel.progress ?? 0)).round()}%'
                        : '执行 H.264 原生压缩',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: widget.viewModel.phase == RouteLabPhase.runningVideo
                    ? widget.viewModel.cancelVideo
                    : null,
                child: const Text('取消'),
              ),
            ],
          ),
          ..._resultSection(MediaResultKind.video),
          if (widget.viewModel.error case final error?) ...[
            const SizedBox(height: 20),
            SelectableText(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
  );

  List<Widget> _resultSection(MediaResultKind kind) {
    final result = widget.viewModel.result;
    final inputPath = widget.viewModel.resultInputPath;
    if (result == null ||
        inputPath == null ||
        widget.viewModel.resultKind != kind) {
      return const [];
    }

    return [
      const SizedBox(height: 20),
      ResultSummary(result: result, kind: kind, inputPath: inputPath),
      const SizedBox(height: 12),
      ExpansionTile(
        title: const Text('查看原始结果 JSON'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(result.toJson()),
          ),
        ],
      ),
    ];
  }

  bool get _hasImagePaths =>
      imageInput.text.trim().isNotEmpty && imageOutput.text.trim().isNotEmpty;

  bool get _hasVideoPaths =>
      videoInput.text.trim().isNotEmpty && videoOutput.text.trim().isNotEmpty;

  Future<void> _pickImage() async {
    await _pickMedia(widget.mediaSelectionService.pickImage, (selection) {
      imageInput.text = selection.inputPath;
      imageOutput.text = _replaceExtension(
        selection.outputPath,
        _imageExtension(selectedImageFormat),
      );
      selectedImageName = selection.displayName;
    });
  }

  void _changeImageFormat(ImageFormat? format) {
    if (format == null || !_supportsImageFormat(format)) return;
    widget.viewModel.clearResult();
    setState(() {
      selectedImageFormat = format;
      if (imageOutput.text.trim().isNotEmpty) {
        imageOutput.text = _replaceExtension(
          imageOutput.text,
          _imageExtension(format),
        );
      }
    });
  }

  Future<void> _pickVideo() async {
    await _pickMedia(widget.mediaSelectionService.pickVideo, (selection) {
      videoInput.text = selection.inputPath;
      videoOutput.text = selection.outputPath;
      selectedVideoName = selection.displayName;
      selectedVideoAcquisitionSummary = _videoAcquisitionSummary(selection);
    });
  }

  Future<void> _pickMedia(
    Future<SelectedMedia?> Function() pick,
    void Function(SelectedMedia selection) apply,
  ) async {
    setState(() => isPicking = true);
    try {
      final selection = await pick();
      if (!mounted || selection == null) return;
      widget.viewModel.clearResult();
      setState(() => apply(selection));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('选择文件失败：$error')));
    } finally {
      if (mounted) setState(() => isPicking = false);
    }
  }

  void _compressImage() {
    widget.viewModel.compressImage(
      ImageCompressionRequest(
        inputPath: imageInput.text,
        outputPath: imageOutput.text,
        format: selectedImageFormat,
        quality: _imageQuality(selectedImageFormat),
        preserveMetadata: true,
        resizePolicy: selectedImageResizePolicy,
      ),
    );
  }

  bool _supportsImageFormat(ImageFormat format) {
    final capability = widget.viewModel.imageCapability;
    return capability == null || capability.formats.contains(format.name);
  }

  void _changeVideoPreset(VideoQualityPreset? preset) {
    if (preset == null) return;
    widget.viewModel.clearResult();
    setState(() => selectedVideoPreset = preset);
  }

  void _compressVideo() {
    widget.viewModel.compressVideo(
      VideoCompressionRequest(
        inputPath: videoInput.text,
        outputPath: videoOutput.text,
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: selectedVideoBitrateBudget.apply(selectedVideoPreset),
        maxShortSide: selectedVideoPreset.maxShortSide,
        removeAudio: true,
        hdrPolicy: selectedVideoHdrPolicy,
      ),
    );
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.controller,
    required this.label,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.title, required this.report});
  final String title;
  final CapabilityReport? report;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      title: Text(title),
      subtitle: Text(
        report == null
            ? '读取能力中…'
            : '${report!.executor} · ${report!.formats.join(' / ')}'
                  '${report!.codecs.isEmpty ? '' : ' · ${report!.codecs.join(' / ')}'}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SelectableText(
          report == null
              ? '读取能力中…'
              : const JsonEncoder.withIndent('  ').convert(report!.toJson()),
        ),
      ],
    ),
  );
}

String _imageFormatLabel(ImageFormat format) => switch (format) {
  ImageFormat.jpeg => 'JPEG',
  ImageFormat.png => 'PNG',
  ImageFormat.webp => 'WebP',
  ImageFormat.heic => 'HEIC',
};

String _imageResizePolicyLabel(ImageResizePolicy policy) => switch (policy) {
  ImageResizePolicy.social => '标准压缩（智能缩放，推荐）',
  ImageResizePolicy.original => '保持原尺寸（高清档）',
};

String _imageResizePolicyHint(ImageResizePolicy policy) => switch (policy) {
  ImageResizePolicy.social => '参考 Luban/微信：短边缩到 1440px 内再编码，体积约为原尺寸档的四分之一。',
  ImageResizePolicy.original => '只调整编码格式和质量，保留全部像素；体积明显更大。',
};

String _videoAcquisitionSummary(SelectedMedia selection) {
  final mode = switch (selection.accessMode) {
    'photo-library-direct' => '相册资源直读（未复制）',
    'provider-hardlink' => '临时资源快速链接',
    'provider-copy' => '系统当前格式快速准备',
    'file-picker-copy' => '临时资源复制',
    _ => '本地文件',
  };
  final elapsed = selection.acquisitionElapsedMilliseconds;
  if (elapsed == null) return '视频准备：$mode';
  return '视频准备：$mode · ${(elapsed / 1000).toStringAsFixed(2)} s';
}

String _imageExtension(ImageFormat format) => switch (format) {
  ImageFormat.jpeg => 'jpg',
  ImageFormat.png => 'png',
  ImageFormat.webp => 'webp',
  ImageFormat.heic => 'heic',
};

double _imageQuality(ImageFormat format) => switch (format) {
  ImageFormat.webp => 0.80,
  ImageFormat.jpeg || ImageFormat.heic => 0.75,
  ImageFormat.png => 1,
};

String _replaceExtension(String path, String extension) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  final dot = path.lastIndexOf('.');
  if (dot <= separator) return '$path.$extension';
  return '${path.substring(0, dot)}.$extension';
}
