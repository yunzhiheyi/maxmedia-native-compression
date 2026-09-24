import 'dart:async';

import 'package:maxmedia_video_native/maxmedia_video_native.dart';

/// Lifecycle of one video inside a [VideoBatchController] queue.
enum VideoQueueItemStatus { queued, running, succeeded, cancelled, failed }

/// Visible state of one queued video, in input order.
final class VideoQueueItemState {
  const VideoQueueItemState({
    required this.index,
    required this.request,
    this.status = VideoQueueItemStatus.queued,
    this.progress,
    this.result,
    this.error,
  });

  final int index;
  final VideoCompressionRequest request;
  final VideoQueueItemStatus status;

  /// Latest progress while [status] is [VideoQueueItemStatus.running].
  final VideoCompressionProgress? progress;
  final CompressionResult? result;
  final String? error;

  VideoQueueItemState copyWith({
    VideoQueueItemStatus? status,
    VideoCompressionProgress? progress,
    CompressionResult? result,
    String? error,
  }) => VideoQueueItemState(
    index: index,
    request: request,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    result: result ?? this.result,
    error: error ?? this.error,
  );
}

/// Immutable snapshot pushed on [VideoBatchController.stateStream].
final class VideoBatchState {
  const VideoBatchState({required this.items});

  final List<VideoQueueItemState> items;

  int get totalCount => items.length;
  int get settledCount => items
      .where(
        (item) =>
            item.status != VideoQueueItemStatus.queued &&
            item.status != VideoQueueItemStatus.running,
      )
      .length;

  /// The one item currently encoding, or null when idle/finished.
  VideoQueueItemState? get runningItem => items
      .where((item) => item.status == VideoQueueItemStatus.running)
      .firstOrNull;

  bool get isFinished => items.every(
    (item) =>
        item.status != VideoQueueItemStatus.queued &&
        item.status != VideoQueueItemStatus.running,
  );
}

/// Compresses a video queue one at a time.
///
/// Video encoders are heavy, long-running and single-instance on the native
/// side (a second export is rejected with BUSY), so the queue is sequential
/// by design: at most one video encodes at any moment, progress streams per
/// frame, and cancelling the current item skips straight to the next one.
class VideoBatchController {
  VideoBatchController({required this.plugin});

  final MaxmediaVideoNative plugin;
  final _states = StreamController<VideoBatchState>.broadcast();
  StreamSubscription<VideoCompressionProgress>? _progressSubscription;
  VideoBatchState? _current;
  bool _cancelRequested = false;
  bool _drainRequested = false;
  bool _running = false;

  Stream<VideoBatchState> get stateStream => _states.stream;
  VideoBatchState? get currentState => _current;

  /// Starts the queue; resolves when every item has settled.
  Future<void> start(List<VideoCompressionRequest> requests) async {
    if (_running) {
      throw StateError('A queue is already running in this controller');
    }
    _running = true;
    _drainRequested = false;
    _current = VideoBatchState(
      items: [
        for (var index = 0; index < requests.length; index += 1)
          VideoQueueItemState(index: index, request: requests[index]),
      ],
    );
    _emit();

    for (var index = 0; index < requests.length; index += 1) {
      if (_drainRequested) break;
      _cancelRequested = false;
      final item = _current!.items[index];
      _current!.items[index] = item.copyWith(
        status: VideoQueueItemStatus.running,
      );
      _listenProgress(index);
      _emit();

      CompressionResult result;
      try {
        result = await plugin.compress(item.request);
      } catch (error) {
        if (_cancelRequested) {
          _settleItem(index, VideoQueueItemStatus.cancelled);
        } else {
          _settleItem(
            index,
            VideoQueueItemStatus.failed,
            error: error.toString(),
          );
        }
        continue;
      }
      switch (result.terminal) {
        case CompressionTerminal.succeeded:
          _settleItem(index, VideoQueueItemStatus.succeeded, result: result);
        case CompressionTerminal.cancelled:
          _settleItem(index, VideoQueueItemStatus.cancelled, result: result);
        case CompressionTerminal.failed:
          _settleItem(index, VideoQueueItemStatus.failed, result: result);
      }
    }
    await _progressSubscription?.cancel();
    _progressSubscription = null;
    _running = false;
    _emit();
  }

  /// Cancels the item that is currently encoding; the queue moves on.
  Future<void> cancelCurrent() {
    if (!_running) return Future.value();
    _cancelRequested = true;
    return plugin.cancel();
  }

  /// Cancels the current item and drops everything still queued.
  Future<void> cancelAll() {
    if (!_running) return Future.value();
    _drainRequested = true;
    _cancelRequested = true;
    final future = plugin.cancel();
    for (var index = 0; index < _current!.items.length; index += 1) {
      final item = _current!.items[index];
      if (item.status == VideoQueueItemStatus.queued) {
        _current!.items[index] = item.copyWith(
          status: VideoQueueItemStatus.cancelled,
        );
      }
    }
    _emit();
    return future;
  }

  void dispose() {
    _progressSubscription?.cancel();
    _states.close();
  }

  void _listenProgress(int index) {
    _progressSubscription?.cancel();
    _progressSubscription = plugin.progress.listen((progress) {
      final current = _current;
      if (current == null) return;
      final item = current.items[index];
      if (item.status != VideoQueueItemStatus.running) return;
      current.items[index] = item.copyWith(progress: progress);
      _emit();
    });
  }

  void _settleItem(
    int index,
    VideoQueueItemStatus status, {
    CompressionResult? result,
    String? error,
  }) {
    _current!.items[index] = _current!.items[index].copyWith(
      status: status,
      result: result,
      error: error,
    );
    _emit();
  }

  void _emit() {
    if (_states.isClosed || _current == null) return;
    // Snapshot: consumers hold an immutable copy, not the mutating list.
    _states.add(VideoBatchState(items: List.of(_current!.items)));
  }
}
