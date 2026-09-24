import 'package:maxmedia_image_native/maxmedia_image_native.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';

abstract interface class CompressionGateway {
  Future<CapabilityReport> imageCapabilities();
  Future<CapabilityReport> videoCapabilities();
  Future<CompressionResult> compressImage(ImageCompressionRequest request);
  Future<CompressionResult> compressVideo(VideoCompressionRequest request);
  Stream<VideoCompressionProgress> get videoProgress;
  Future<void> cancelVideo();

  /// Cancels all queued or in-flight image compression operations; decoded
  /// pixel memory on the native side is released immediately.
  Future<void> cancelImages();
}

class NativeCompressionService implements CompressionGateway {
  const NativeCompressionService({
    this.imagePlugin = const MaxmediaImageNative(),
    this.videoPlugin = const MaxmediaVideoNative(),
  });

  final MaxmediaImageNative imagePlugin;
  final MaxmediaVideoNative videoPlugin;

  @override
  Future<CapabilityReport> imageCapabilities() => imagePlugin.capabilities();
  @override
  Future<CapabilityReport> videoCapabilities() => videoPlugin.capabilities();
  @override
  Future<CompressionResult> compressImage(ImageCompressionRequest request) =>
      imagePlugin.compress(request);
  @override
  Future<CompressionResult> compressVideo(VideoCompressionRequest request) =>
      videoPlugin.compress(request);
  @override
  Stream<VideoCompressionProgress> get videoProgress => videoPlugin.progress;
  @override
  Future<void> cancelVideo() => videoPlugin.cancel();
  @override
  Future<void> cancelImages() => imagePlugin.cancelImageCompression();
}
