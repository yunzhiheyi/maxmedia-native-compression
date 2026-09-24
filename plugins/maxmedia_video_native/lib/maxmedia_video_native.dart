import 'package:media_route_contracts/media_route_contracts.dart';
import 'maxmedia_video_native_platform_interface.dart';
import 'video_compression_progress.dart';
import 'video_source_selection.dart';

export 'package:media_route_contracts/media_route_contracts.dart';
export 'src/video_batch_controller.dart';
export 'video_compression_progress.dart';
export 'video_source_selection.dart';

class MaxmediaVideoNative {
  const MaxmediaVideoNative();

  Future<CapabilityReport> capabilities() =>
      MaxmediaVideoNativePlatform.instance.capabilities();

  Future<CompressionResult> compress(VideoCompressionRequest request) =>
      MaxmediaVideoNativePlatform.instance.compress(request);

  Future<VideoSourceSelection?> pickVideoSource() =>
      MaxmediaVideoNativePlatform.instance.pickVideoSource();

  /// Multi-select photo-library picker resolving every pick with the same
  /// direct-access policy as [pickVideoSource].
  Future<List<VideoSourceSelection>> pickVideoSources() =>
      MaxmediaVideoNativePlatform.instance.pickVideoSources();

  Stream<VideoCompressionProgress> get progress =>
      MaxmediaVideoNativePlatform.instance.progress;

  Future<void> cancel() => MaxmediaVideoNativePlatform.instance.cancel();
}
