import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';

import '../data/route_repository.dart';

enum RouteLabPhase {
  idle,
  loading,
  runningImage,
  runningVideo,
  succeeded,
  failed,
}

enum MediaResultKind { image, video }

class RouteLabViewModel extends ChangeNotifier {
  RouteLabViewModel(this._repository) {
    _progressSubscription = _repository.videoProgress.listen(
      _onVideoProgress,
      onError: (_) {},
    );
  }

  final RouteRepository _repository;
  late final StreamSubscription<VideoCompressionProgress> _progressSubscription;
  RouteLabPhase phase = RouteLabPhase.idle;
  String? error;
  CompressionResult? result;
  MediaResultKind? resultKind;
  String? resultInputPath;
  double? progress;
  String? progressLabel;

  CapabilityReport? get imageCapability => _repository.imageCapability;
  CapabilityReport? get videoCapability => _repository.videoCapability;
  bool get isBusy =>
      phase == RouteLabPhase.loading ||
      phase == RouteLabPhase.runningImage ||
      phase == RouteLabPhase.runningVideo;

  Future<void> loadCapabilities() async {
    await _run(RouteLabPhase.loading, _repository.loadCapabilities);
  }

  Future<void> compressImage(ImageCompressionRequest request) async {
    result = null;
    progress = null;
    progressLabel = '正在解码并编码图片…';
    resultKind = MediaResultKind.image;
    resultInputPath = request.inputPath;
    await _run(RouteLabPhase.runningImage, () async {
      result = await _repository.compressImage(request);
    });
  }

  Future<void> compressVideo(VideoCompressionRequest request) async {
    result = null;
    progress = 0;
    progressLabel = '正在准备视频编码…';
    resultKind = MediaResultKind.video;
    resultInputPath = request.inputPath;
    await _run(RouteLabPhase.runningVideo, () async {
      result = await _repository.compressVideo(request);
    });
  }

  Future<void> cancelVideo() => _repository.cancelVideo();

  void clearResult() {
    result = null;
    resultKind = null;
    resultInputPath = null;
    error = null;
    progress = null;
    progressLabel = null;
    if (!isBusy) phase = RouteLabPhase.idle;
    notifyListeners();
  }

  Future<void> _run(RouteLabPhase runningPhase, AsyncCallback operation) async {
    phase = runningPhase;
    error = null;
    notifyListeners();
    try {
      await operation();
      phase = RouteLabPhase.succeeded;
      progress = 1;
      progressLabel = '处理完成';
    } catch (exception) {
      error = _friendlyError(exception);
      phase = RouteLabPhase.failed;
    }
    notifyListeners();
  }

  String _friendlyError(Object exception) {
    final message = exception.toString();
    if (message.contains('Compression produced no size reduction')) {
      return '源视频已经高度压缩，本次编码无法继续减小体积，未保留更大的输出文件。';
    }
    if (message.contains('Image compression produced no size reduction')) {
      return '原图已经高度压缩，降低到最低质量档后仍无法减小体积，未保留更大的输出文件。';
    }
    if (message.contains('IMAGE_COLOR_PRESERVATION')) {
      return '无法确认输出保留原图色彩，已跳过压缩并保留原图。';
    }
    if (message.contains('HDR_COLOR_PRESERVATION')) {
      return '检测到 HDR 或无法确认色彩信息，已跳过压缩并保留原视频。';
    }
    if (message.contains('hdrPolicy=rejectH264')) {
      return '检测到 HDR 视频，当前策略禁止直接转为 H.264；如需保色，请保留原片。';
    }
    if (message.contains('HDR-to-SDR tone-mapping')) {
      return '当前平台还不支持 HDR 转 SDR；请保留原片，或在支持的平台显式转换。';
    }
    return message;
  }

  void _onVideoProgress(VideoCompressionProgress value) {
    if (phase != RouteLabPhase.runningVideo) return;
    progress = value.fraction;
    progressLabel = switch (value.stage) {
      'probing' => '正在分析源视频…',
      'finalizing' => '正在封装输出文件…',
      _ => '正在编码视频 ${value.percent}%',
    };
    notifyListeners();
  }

  @override
  void dispose() {
    _progressSubscription.cancel();
    super.dispose();
  }
}
