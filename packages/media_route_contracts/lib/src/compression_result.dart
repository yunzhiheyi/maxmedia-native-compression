import 'media_enums.dart';

final class CompressionResult {
  const CompressionResult({
    required this.schemaVersion,
    required this.terminal,
    required this.executor,
    required this.outputPath,
    required this.elapsedMilliseconds,
    required this.inputBytes,
    required this.outputBytes,
    required this.actualSettings,
    this.warnings = const [],
  });

  final int schemaVersion;
  final CompressionTerminal terminal;
  final String executor;
  final String outputPath;
  final int elapsedMilliseconds;
  final int inputBytes;
  final int outputBytes;
  final Map<String, Object?> actualSettings;
  final List<String> warnings;

  double get compressionRatio => inputBytes == 0 ? 0 : outputBytes / inputBytes;

  factory CompressionResult.fromJson(
    Map<Object?, Object?> json,
  ) => CompressionResult(
    schemaVersion: (json['schemaVersion'] as num).toInt(),
    terminal: enumByName(
      CompressionTerminal.values,
      json['terminal'],
      'terminal',
    ),
    executor: json['executor'] as String,
    outputPath: json['outputPath'] as String,
    elapsedMilliseconds: (json['elapsedMilliseconds'] as num).toInt(),
    inputBytes: (json['inputBytes'] as num).toInt(),
    outputBytes: (json['outputBytes'] as num).toInt(),
    actualSettings: Map<String, Object?>.from(json['actualSettings'] as Map),
    warnings: (json['warnings'] as List<Object?>? ?? const []).cast<String>(),
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'terminal': terminal.name,
    'executor': executor,
    'outputPath': outputPath,
    'elapsedMilliseconds': elapsedMilliseconds,
    'inputBytes': inputBytes,
    'outputBytes': outputBytes,
    'compressionRatio': compressionRatio,
    'actualSettings': actualSettings,
    'warnings': warnings,
  };
}
