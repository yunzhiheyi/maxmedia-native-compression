import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

import 'maxmedia_video_native_platform_interface.dart';
import 'video_compression_progress.dart';
import 'video_source_selection.dart';

/// An implementation of [MaxmediaVideoNativePlatform] that uses method channels.
class MethodChannelMaxmediaVideoNative extends MaxmediaVideoNativePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('maxmedia_video_native');

  @visibleForTesting
  final progressChannel = const EventChannel('maxmedia_video_native/progress');

  Stream<VideoCompressionProgress>? _progress;

  @override
  Stream<VideoCompressionProgress> get progress => _progress ??= progressChannel
      .receiveBroadcastStream()
      .map(VideoCompressionProgress.fromEvent);

  @override
  Future<CapabilityReport> capabilities() async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'capabilities',
    );
    if (value == null) throw const FormatException('Missing capability report');
    return CapabilityReport.fromJson(value);
  }

  @override
  Future<CompressionResult> compress(VideoCompressionRequest request) async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'compress',
      request.toJson(),
    );
    if (value == null) {
      throw const FormatException('Missing compression result');
    }
    return CompressionResult.fromJson(value);
  }

  @override
  Future<VideoSourceSelection?> pickVideoSource() async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'pickVideoSource',
    );
    if (value == null) return null;
    return VideoSourceSelection.fromMap(value);
  }

  @override
  Future<List<VideoSourceSelection>> pickVideoSources() async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'pickVideoSources',
    );
    if (value == null) return const [];
    final sources = value['sources'] as List<Object?>? ?? const [];
    return [
      for (final source in sources)
        VideoSourceSelection.fromMap(source! as Map<Object?, Object?>),
    ];
  }

  @override
  Future<void> cancel() => methodChannel.invokeMethod<void>('cancel');
}
