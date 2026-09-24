import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

import 'maxmedia_image_native_method_channel.dart';
import 'src/image_batch_types.dart';

abstract class MaxmediaImageNativePlatform extends PlatformInterface {
  /// Constructs a MaxmediaImageNativePlatform.
  MaxmediaImageNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static MaxmediaImageNativePlatform _instance =
      MethodChannelMaxmediaImageNative();

  /// The default instance of [MaxmediaImageNativePlatform] to use.
  ///
  /// Defaults to [MethodChannelMaxmediaImageNative].
  static MaxmediaImageNativePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MaxmediaImageNativePlatform] when
  /// they register themselves.
  static set instance(MaxmediaImageNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<CapabilityReport> capabilities() =>
      throw UnimplementedError('capabilities() has not been implemented.');

  Future<CompressionResult> compress(
    ImageCompressionRequest request, {
    required String operationId,
  }) => throw UnimplementedError('compress() has not been implemented.');

  Future<List<ImageBatchItemResult>> compressBatch(
    List<ImageCompressionRequest> requests, {
    required String batchId,
    int maxConcurrent = 4,
  }) => throw UnimplementedError('compressBatch() has not been implemented.');

  Future<void> cancelImageCompression({Set<String>? operationIds}) =>
      throw UnimplementedError(
        'cancelImageCompression() has not been implemented.',
      );

  Stream<ImageBatchProgress> batchProgress() =>
      throw UnimplementedError('batchProgress() has not been implemented.');
}
