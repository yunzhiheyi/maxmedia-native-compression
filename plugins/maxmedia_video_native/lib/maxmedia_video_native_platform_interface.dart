import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

import 'maxmedia_video_native_method_channel.dart';
import 'video_compression_progress.dart';
import 'video_source_selection.dart';

abstract class MaxmediaVideoNativePlatform extends PlatformInterface {
  /// Constructs a MaxmediaVideoNativePlatform.
  MaxmediaVideoNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static MaxmediaVideoNativePlatform _instance =
      MethodChannelMaxmediaVideoNative();

  /// The default instance of [MaxmediaVideoNativePlatform] to use.
  ///
  /// Defaults to [MethodChannelMaxmediaVideoNative].
  static MaxmediaVideoNativePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MaxmediaVideoNativePlatform] when
  /// they register themselves.
  static set instance(MaxmediaVideoNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<CapabilityReport> capabilities() =>
      throw UnimplementedError('capabilities() has not been implemented.');

  Future<CompressionResult> compress(VideoCompressionRequest request) =>
      throw UnimplementedError('compress() has not been implemented.');

  Future<VideoSourceSelection?> pickVideoSource() =>
      throw UnimplementedError('pickVideoSource() has not been implemented.');

  /// Multi-select variant of [pickVideoSource]; every picked video is
  /// resolved with the same direct-access policy. Unimplemented platforms
  /// make callers fall back to the general file picker.
  Future<List<VideoSourceSelection>> pickVideoSources() =>
      throw UnimplementedError('pickVideoSources() has not been implemented.');

  Stream<VideoCompressionProgress> get progress =>
      throw UnimplementedError('progress has not been implemented.');

  Future<void> cancel() =>
      throw UnimplementedError('cancel() has not been implemented.');
}
