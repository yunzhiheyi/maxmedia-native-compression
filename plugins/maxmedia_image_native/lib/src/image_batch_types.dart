import 'package:media_route_contracts/media_route_contracts.dart';

/// Per-item outcome of a [MaxmediaImageNative.compressBatch] call.
///
/// A batch never fails wholesale: each request reports either a
/// [CompressionResult] or an [error] message, keyed by its position in the
/// original request list.
final class ImageBatchItemResult {
  const ImageBatchItemResult({required this.index, this.result, this.error});

  final int index;
  final CompressionResult? result;
  final String? error;

  /// True only for items that actually produced a compressed output;
  /// cancelled and failed items report false.
  bool get succeeded => result?.terminal == CompressionTerminal.succeeded;

  static ImageBatchItemResult fromJson(Object? json) {
    final map = json! as Map<Object?, Object?>;
    final index = (map['index']! as num).toInt();
    final resultJson = map['result'] as Map<Object?, Object?>?;
    final error = map['error'] as String?;
    return ImageBatchItemResult(
      index: index,
      result: resultJson == null
          ? null
          : CompressionResult.fromJson(resultJson),
      error: error,
    );
  }
}

/// Emitted after each batch item settles, carrying the item's position and
/// terminal so a UI can tick rows off one by one.
final class ImageBatchProgress {
  const ImageBatchProgress({
    this.batchId,
    required this.completed,
    required this.total,
    required this.index,
    required this.terminal,
  });

  final String? batchId;
  final int completed;
  final int total;
  final int index;
  final String terminal;

  bool get finished => completed >= total;

  static ImageBatchProgress fromJson(Object? json) {
    final map = json! as Map<Object?, Object?>;
    return ImageBatchProgress(
      batchId: map['batchId'] as String?,
      completed: (map['completed']! as num).toInt(),
      total: (map['total']! as num).toInt(),
      index: (map['index']! as num).toInt(),
      terminal: map['terminal'] as String? ?? 'failed',
    );
  }
}
