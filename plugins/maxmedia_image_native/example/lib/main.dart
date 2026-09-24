import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const MaterialApp(home: ImageExample()));

class ImageExample extends StatefulWidget {
  const ImageExample({super.key});

  @override
  State<ImageExample> createState() => _ImageExampleState();
}

class _ImageExampleState extends State<ImageExample> {
  final _plugin = const MaxmediaImageNative();
  String _message = 'Choose an image to compress to WebP.';
  bool _busy = false;

  Future<void> _compress() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      final inputPath = picked?.path;
      if (inputPath == null) {
        if (mounted) setState(() => _message = 'No image selected.');
        return;
      }

      final capabilities = await _plugin.capabilities();
      if (!capabilities.formats.contains('webp')) {
        throw UnsupportedError('WebP encoding is unavailable on this device');
      }
      final directory = await getTemporaryDirectory();
      final outputPath =
          '${directory.path}/image-${DateTime.now().microsecondsSinceEpoch}.webp';
      final result = await _plugin.compress(
        ImageCompressionRequest(
          inputPath: inputPath,
          outputPath: outputPath,
          format: ImageFormat.webp,
          quality: 0.8,
          resizePolicy: ImageResizePolicy.social,
        ),
      );
      if (!mounted) return;
      setState(() {
        _message =
            '${result.terminal.name}: '
            '${result.inputBytes} → ${result.outputBytes} bytes\n'
            '${result.outputPath}\n${result.warnings.join('\n')}';
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Compression failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Image compression example')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: _busy ? null : _compress,
            child: const Text('Choose image and compress'),
          ),
          const SizedBox(height: 16),
          SelectableText(_message),
        ],
      ),
    ),
  );
}
