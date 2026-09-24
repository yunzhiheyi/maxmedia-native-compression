final class VideoCompressionProgress {
  const VideoCompressionProgress({required this.fraction, required this.stage});

  final double fraction;
  final String stage;

  int get percent => (fraction.clamp(0, 1) * 100).round();

  factory VideoCompressionProgress.fromEvent(Object? event) {
    final value = Map<Object?, Object?>.from(event! as Map);
    return VideoCompressionProgress(
      fraction: (value['fraction'] as num).toDouble().clamp(0, 1),
      stage: value['stage'] as String? ?? 'encoding',
    );
  }
}
