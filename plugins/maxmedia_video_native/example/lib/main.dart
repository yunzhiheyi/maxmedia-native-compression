import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const MaterialApp(home: VideoExample()));

class VideoExample extends StatefulWidget {
  const VideoExample({super.key});

  @override
  State<VideoExample> createState() => _VideoExampleState();
}

class _VideoExampleState extends State<VideoExample> {
  final _plugin = const MaxmediaVideoNative();
  String _message = 'Choose a video to compress to MP4.';
  bool _busy = false;
  StreamSubscription<VideoCompressionProgress>? _progressSubscription;

  Future<void> _compress() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.video,
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
      final inputPath = picked?.path;
      if (inputPath == null) {
        if (mounted) setState(() => _message = 'No video selected.');
        return;
      }

      final capabilities = await _plugin.capabilities();
      if (!capabilities.codecs.contains('h264') ||
          !capabilities.formats.contains('mp4')) {
        throw UnsupportedError('H.264 MP4 encoding is unavailable');
      }
      final directory = await getTemporaryDirectory();
      final outputPath =
          '${directory.path}/video-${DateTime.now().microsecondsSinceEpoch}.mp4';
      _progressSubscription = _plugin.progress.listen((progress) {
        if (mounted) {
          setState(() => _message = 'Encoding: ${progress.percent}%');
        }
      });
      final result = await _plugin.compress(
        VideoCompressionRequest(
          inputPath: inputPath,
          outputPath: outputPath,
          codec: VideoCodec.h264,
          container: ContainerFormat.mp4,
          averageBitrate: 1000000,
          maxShortSide: 720,
          removeAudio: true,
        ),
      );
      if (!mounted) return;
      setState(() {
        _message =
            '${result.inputBytes} → ${result.outputBytes} bytes\n'
            '${result.outputPath}\n${result.warnings.join('\n')}';
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Compression failed: $error');
    } finally {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Video compression example')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: _busy ? null : _compress,
            child: const Text('Choose video and compress'),
          ),
          const SizedBox(height: 16),
          SelectableText(_message),
        ],
      ),
    ),
  );
}
