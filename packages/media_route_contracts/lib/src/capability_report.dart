final class CapabilityReport {
  const CapabilityReport({
    required this.schemaVersion,
    required this.executor,
    required this.platform,
    required this.features,
    required this.codecs,
    required this.formats,
    this.warnings = const [],
  });

  final int schemaVersion;
  final String executor;
  final String platform;
  final Set<String> features;
  final Set<String> codecs;
  final Set<String> formats;
  final List<String> warnings;

  factory CapabilityReport.fromJson(Map<Object?, Object?> json) =>
      CapabilityReport(
        schemaVersion: (json['schemaVersion'] as num).toInt(),
        executor: json['executor'] as String,
        platform: json['platform'] as String,
        features: _strings(json['features']),
        codecs: _strings(json['codecs']),
        formats: _strings(json['formats']),
        warnings: _strings(json['warnings']).toList(growable: false),
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'executor': executor,
    'platform': platform,
    'features': features.toList()..sort(),
    'codecs': codecs.toList()..sort(),
    'formats': formats.toList()..sort(),
    'warnings': warnings,
  };

  static Set<String> _strings(Object? value) =>
      (value as List<Object?>? ?? const [])
          .map((item) => item as String)
          .toSet();
}
