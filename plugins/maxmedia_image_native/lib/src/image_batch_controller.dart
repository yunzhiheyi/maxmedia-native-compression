import 'dart:async';

import 'package:maxmedia_image_native/maxmedia_image_native.dart';

/// Lifecycle of one item inside an [ImageBatchController] run.
enum ImageBatchItemStatus { queued, succeeded, cancelled, failed }

/// Visible state of one queued image, in input order.
final class ImageBatchItemState {
  const ImageBatchItemState({
    required this.index,
    required this.request,
    this.status = ImageBatchItemStatus.queued,
    this.result,
    this.error,
  });

  final int index;
  final ImageCompressionRequest request;
  final ImageBatchItemStatus status;
  final CompressionResult? result;
  final String? error;

  ImageBatchItemState copyWith({
    ImageBatchItemStatus? status,
    CompressionResult? result,
    String? error,
  }) => ImageBatchItemState(
    index: index,
    request: request,
    status: status ?? this.status,
    result: result ?? this.result,
    error: error ?? this.error,
  );
}

/// Immutable snapshot pushed on [ImageBatchController.stateStream].
final class ImageBatchState {
  const ImageBatchState({required this.items});

  final List<ImageBatchItemState> items;

  int get totalCount => items.length;
  int get settledCount =>
      items.where((item) => item.status != ImageBatchItemStatus.queued).length;
  bool get isFinished => settledCount == totalCount;
}

/// Drives one native image batch and exposes per-item state for a UI.
///
/// The whole queue is submitted in a single native call which runs at most
/// `maxConcurrent` items at a time; queued items occupy no decode memory.
/// Cancelling frees decoded pixel memory on the native side immediately (see
/// the plugin README for the exact checkpoints).
class ImageBatchController {
  ImageBatchController({required this.plugin});

  final MaxmediaImageNative plugin;
  final _states = StreamController<ImageBatchState>.broadcast();
  StreamSubscription<ImageBatchProgress>? _progressSubscription;
  ImageBatchState? _current;
  String? _batchId;
  bool _running = false;

  Stream<ImageBatchState> get stateStream => _states.stream;
  ImageBatchState? get currentState => _current;

  Future<void> start(
    List<ImageCompressionRequest> requests, {
    int maxConcurrent = 4,
  }) async {
    if (_running) {
      throw StateError('A batch is already running in this controller');
    }
    _running = true;
    _batchId = 'uibatch-${DateTime.now().microsecondsSinceEpoch}';
    _current = ImageBatchState(
      items: [
        for (var index = 0; index < requests.length; index += 1)
          ImageBatchItemState(index: index, request: requests[index]),
      ],
    );
    _emit();

    _progressSubscription = plugin.batchProgress().listen(_onProgress);
    List<ImageBatchItemResult> outcomes;
    try {
      outcomes = await plugin.compressBatch(
        requests,
        batchId: _batchId,
        maxConcurrent: maxConcurrent,
      );
    } catch (error) {
      _markQueued(ImageBatchItemStatus.failed, error: error.toString());
      await _settle();
      return;
    }
    // Reconcile with the authoritative results; progress events may have
    // raced or been dropped.
    for (final outcome in outcomes) {
      if (outcome.index < 0 || outcome.index >= _current!.items.length) {
        continue;
      }
      final item = _current!.items[outcome.index];
      if (!outcome.succeeded) {
        _current!.items[outcome.index] = item.copyWith(
          status: outcome.result?.terminal == CompressionTerminal.cancelled
              ? ImageBatchItemStatus.cancelled
              : ImageBatchItemStatus.failed,
          result: outcome.result,
          error: outcome.error,
        );
        continue;
      }
      _current!.items[outcome.index] = item.copyWith(
        status: ImageBatchItemStatus.succeeded,
        result: outcome.result,
      );
    }
    await _settle();
  }

  /// Cancels every queued or in-flight item of the running batch.
  Future<void> cancelAll() {
    final batchId = _batchId;
    final current = _current;
    if (!_running || batchId == null || current == null) return Future.value();
    return plugin.cancelImageCompression(
      operationIds: {
        for (final item in current.items) '$batchId#${item.index}',
      },
    );
  }

  /// Cancels one item; queued items leave the queue before ever decoding.
  Future<void> cancelItem(int index) {
    final batchId = _batchId;
    if (batchId == null) return Future.value();
    return plugin.cancelImageCompression(operationIds: {'$batchId#$index'});
  }

  void dispose() {
    _progressSubscription?.cancel();
    _states.close();
  }

  void _onProgress(ImageBatchProgress progress) {
    final current = _current;
    if (current == null ||
        (progress.batchId != null && progress.batchId != _batchId) ||
        progress.index < 0 ||
        progress.index >= current.items.length) {
      return;
    }
    final item = current.items[progress.index];
    if (item.status != ImageBatchItemStatus.queued) return;
    // The event proves the item settled; the final reconciliation pass still
    // fills in sizes and timings.
    current.items[progress.index] = item.copyWith(
      status: switch (progress.terminal) {
        'succeeded' => ImageBatchItemStatus.succeeded,
        'cancelled' => ImageBatchItemStatus.cancelled,
        _ => ImageBatchItemStatus.failed,
      },
    );
    _emit();
  }

  void _markQueued(ImageBatchItemStatus status, {String? error}) {
    _current = ImageBatchState(
      items: [
        for (final item in _current!.items)
          item.status == ImageBatchItemStatus.queued
              ? item.copyWith(status: status, error: error)
              : item,
      ],
    );
    _emit();
  }

  Future<void> _settle() async {
    _running = false;
    await _progressSubscription?.cancel();
    _progressSubscription = null;
    _emit();
  }

  void _emit() {
    if (_states.isClosed) return;
    // Snapshot: stream consumers must hold an immutable copy, not a view of
    // the list that later progress events keep mutating.
    _states.add(ImageBatchState(items: List.of(_current!.items)));
  }
}
