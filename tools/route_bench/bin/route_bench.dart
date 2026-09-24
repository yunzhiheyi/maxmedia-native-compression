import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.contains('--help')) {
    _usage();
    return;
  }
  try {
    final command = arguments.first;
    final options = _parseOptions(arguments.skip(1).toList());
    switch (command) {
      case 'doctor':
        await _doctor();
      case 'probe':
        await _probe(_required(options, 'input'));
      case 'video':
        await _video(options);
      case 'image':
        await _image(options);
      case 'vmaf':
        await _vmaf(options);
      default:
        stderr.writeln('Unknown command: $command');
        _usage();
        exitCode = 64;
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  }
}

Map<String, String> _parseOptions(List<String> arguments) {
  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final token = arguments[index];
    if (!token.startsWith('--')) {
      throw FormatException('Expected --option, got $token');
    }
    final name = token.substring(2);
    if (index + 1 < arguments.length &&
        !arguments[index + 1].startsWith('--')) {
      options[name] = arguments[++index];
    } else {
      options[name] = 'true';
    }
  }
  return options;
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.isEmpty) throw FormatException('Missing --$name');
  return value;
}

Future<void> _doctor() async {
  final ffmpeg = await _run('ffmpeg', [
    '-hide_banner',
    '-version',
  ], allowFailure: true);
  final ffprobe = await _run('ffprobe', [
    '-hide_banner',
    '-version',
  ], allowFailure: true);
  final encoders = await _run('ffmpeg', [
    '-hide_banner',
    '-encoders',
  ], allowFailure: true);
  final report = {
    'schemaVersion': 1,
    'ffmpegAvailable': ffmpeg.exitCode == 0,
    'ffprobeAvailable': ffprobe.exitCode == 0,
    'ffmpegVersion': _firstLine(ffmpeg.stdoutText),
    'ffprobeVersion': _firstLine(ffprobe.stdoutText),
    'encoders': {
      'libx264': encoders.stdoutText.contains('libx264'),
      'libx265': encoders.stdoutText.contains('libx265'),
      'h264_videotoolbox': encoders.stdoutText.contains('h264_videotoolbox'),
      'hevc_videotoolbox': encoders.stdoutText.contains('hevc_videotoolbox'),
      'libwebp': encoders.stdoutText.contains('libwebp'),
      'avif':
          encoders.stdoutText.contains('libaom-av1') ||
          encoders.stdoutText.contains('librav1e'),
    },
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if (ffmpeg.exitCode != 0 || ffprobe.exitCode != 0) exitCode = 1;
}

Future<void> _probe(String input) async {
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(await _probeJson(input)),
  );
}

Future<Map<String, Object?>> _probeJson(String input) async {
  final result = await _run('ffprobe', [
    '-v',
    'error',
    '-show_format',
    '-show_streams',
    '-of',
    'json',
    input,
  ]);
  return Map<String, Object?>.from(jsonDecode(result.stdoutText) as Map);
}

Future<void> _video(Map<String, String> options) async {
  final input = _required(options, 'input');
  final output = _required(options, 'output');
  final codec = options['codec'] ?? 'h264';
  final route = options['route'] ?? 'software';
  final bitrate = int.parse(options['bitrate'] ?? '2000000');
  final encoder = switch ((codec, route)) {
    ('h264', 'software') => 'libx264',
    ('hevc', 'software') => 'libx265',
    ('h264', 'videotoolbox') => 'h264_videotoolbox',
    ('hevc', 'videotoolbox') => 'hevc_videotoolbox',
    _ => throw FormatException('Unsupported codec/route: $codec/$route'),
  };
  final partial = _partialPath(output);
  final args = <String>[
    '-hide_banner',
    '-y',
    '-i',
    input,
    '-map',
    '0:v:0',
    if (options['remove-audio'] != 'true') ...['-map', '0:a?'],
    '-c:v',
    encoder,
    '-b:v',
    bitrate.toString(),
    '-maxrate',
    (bitrate * 1.25).round().toString(),
    '-bufsize',
    (bitrate * 2).toString(),
    '-g',
    options['gop'] ?? '60',
    if (options['width'] != null && options['height'] != null) ...[
      '-vf',
      'scale=${options['width']}:${options['height']}:force_original_aspect_ratio=decrease,'
          'pad=${options['width']}:${options['height']}:(ow-iw)/2:(oh-ih)/2',
    ],
    if (options['remove-audio'] == 'true')
      '-an'
    else ...[
      '-c:a',
      'aac',
      '-b:a',
      '128k',
    ],
    '-movflags',
    '+faststart',
    partial,
  ];

  final started = Stopwatch()..start();
  final sourceBytes = await File(input).length();
  try {
    await _run('ffmpeg', args);
    final partialFile = File(partial);
    if (!await partialFile.exists()) {
      throw StateError('ffmpeg produced no output');
    }
    final outputFile = File(output);
    if (await outputFile.exists()) await outputFile.delete();
    await partialFile.rename(output);
    started.stop();
    final probe = await _probeJson(output);
    final outputBytes = await outputFile.length();
    final result = <String, Object?>{
      'schemaVersion': 1,
      'kind': 'video',
      'route': 'ffmpeg-$route',
      'encoder': encoder,
      'inputPath': input,
      'outputPath': output,
      'elapsedMilliseconds': started.elapsedMilliseconds,
      'inputBytes': sourceBytes,
      'outputBytes': outputBytes,
      'compressionRatio': sourceBytes == 0 ? 0 : outputBytes / sourceBytes,
      'requested': {
        'codec': codec,
        'bitrate': bitrate,
        'width': options['width'],
        'height': options['height'],
        'removeAudio': options['remove-audio'] == 'true',
      },
      'actualProbe': probe,
    };
    await _writeReport('$output.route.json', result);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } finally {
    final partialFile = File(partial);
    if (await partialFile.exists()) await partialFile.delete();
  }
}

Future<void> _image(Map<String, String> options) async {
  final input = _required(options, 'input');
  final output = _required(options, 'output');
  final format = options['format'] ?? 'jpeg';
  final quality = double.parse(options['quality'] ?? '0.82').clamp(0.0, 1.0);
  final partial = _partialPath(output);
  final codecArgs = switch (format) {
    'jpeg' => ['-c:v', 'mjpeg', '-q:v', (31 - quality * 29).round().toString()],
    'png' => [
      '-c:v',
      'png',
      '-compression_level',
      (quality * 9).round().toString(),
    ],
    'webp' => [
      '-c:v',
      'libwebp',
      '-quality',
      (quality * 100).round().toString(),
    ],
    'avif' => [
      '-c:v',
      'libaom-av1',
      '-still-picture',
      '1',
      '-crf',
      (63 - quality * 50).round().toString(),
    ],
    _ => throw FormatException('Unsupported image format: $format'),
  };
  final args = <String>[
    '-hide_banner',
    '-y',
    '-i',
    input,
    '-frames:v',
    '1',
    if (options['width'] != null && options['height'] != null) ...[
      '-vf',
      'scale=${options['width']}:${options['height']}:force_original_aspect_ratio=decrease',
    ],
    ...codecArgs,
    partial,
  ];

  final started = Stopwatch()..start();
  final sourceBytes = await File(input).length();
  try {
    await _run('ffmpeg', args);
    final outputFile = File(output);
    if (await outputFile.exists()) await outputFile.delete();
    await File(partial).rename(output);
    started.stop();
    final outputBytes = await outputFile.length();
    final result = <String, Object?>{
      'schemaVersion': 1,
      'kind': 'image',
      'route': 'ffmpeg',
      'format': format,
      'inputPath': input,
      'outputPath': output,
      'elapsedMilliseconds': started.elapsedMilliseconds,
      'inputBytes': sourceBytes,
      'outputBytes': outputBytes,
      'compressionRatio': sourceBytes == 0 ? 0 : outputBytes / sourceBytes,
      'requested': {'quality': quality},
      'actualProbe': await _probeJson(output),
    };
    await _writeReport('$output.route.json', result);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } finally {
    final partialFile = File(partial);
    if (await partialFile.exists()) await partialFile.delete();
  }
}

Future<void> _vmaf(Map<String, String> options) async {
  final reference = _required(options, 'reference');
  final distorted = _required(options, 'distorted');
  final report = options['report'] ?? '$distorted.vmaf.json';
  final escapedReport = report.replaceAll('\\', '\\\\').replaceAll(':', '\\:');
  await _run('ffmpeg', [
    '-hide_banner',
    '-i',
    distorted,
    '-i',
    reference,
    '-lavfi',
    '[0:v]setpts=PTS-STARTPTS[dist];[1:v]setpts=PTS-STARTPTS[ref];'
        '[dist][ref]libvmaf=log_fmt=json:log_path=$escapedReport',
    '-f',
    'null',
    '-',
  ]);
  stdout.writeln(report);
}

String _partialPath(String output) {
  final file = File(output);
  final name = file.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final partialName = dot <= 0
      ? '$name.partial'
      : '${name.substring(0, dot)}.partial${name.substring(dot)}';
  return '${file.parent.path}${Platform.pathSeparator}$partialName';
}

Future<void> _writeReport(String path, Map<String, Object?> value) async {
  final json = const JsonEncoder.withIndent('  ').convert(value);
  await File(path).writeAsString('$json\n');
}

Future<_CommandResult> _run(
  String executable,
  List<String> arguments, {
  bool allowFailure = false,
}) async {
  final process = await Process.run(executable, arguments);
  final value = _CommandResult(
    process.exitCode,
    process.stdout.toString(),
    process.stderr.toString(),
  );
  if (!allowFailure && process.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      value.stderrText,
      process.exitCode,
    );
  }
  return value;
}

String _firstLine(String value) => value
    .split('\n')
    .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');

void _usage() {
  stdout.writeln('''
MaxMedia route benchmark

  route_bench doctor
  route_bench probe --input FILE
  route_bench video --input FILE --output FILE [--codec h264|hevc]
                    [--route software|videotoolbox] [--bitrate BPS]
                    [--width PX --height PX] [--remove-audio]
  route_bench image --input FILE --output FILE [--format jpeg|png|webp|avif]
                    [--quality 0..1] [--width PX --height PX]
  route_bench vmaf --reference FILE --distorted FILE [--report FILE]
''');
}

final class _CommandResult {
  const _CommandResult(this.exitCode, this.stdoutText, this.stderrText);
  final int exitCode;
  final String stdoutText;
  final String stderrText;
}
