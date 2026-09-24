import 'package:media_route_contracts/media_route_contracts.dart';
import 'maxmedia_image_native_platform_interface.dart';
import 'src/image_batch_types.dart';

export 'package:media_route_contracts/media_route_contracts.dart';
export 'src/image_batch_controller.dart';
export 'src/image_batch_types.dart';

class MaxmediaImageNative {
  const MaxmediaImageNative();

  static int _operationCounter = 0;

  String _newOperationId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_operationCounter++}';

  Future<CapabilityReport> capabilities() =>
      MaxmediaImageNativePlatform.instance.capabilities();

  /// Compresses one image. [operationId] is generated automatically and lets
  /// [cancelImageCompression] abort the work at the next checkpoint, freeing
  /// any decoded pixel memory.
  Future<CompressionResult> compress(
    ImageCompressionRequest request, {
    String? operationId,
  }) {
    final id = operationId ?? _newOperationId('image');
    return MaxmediaImageNativePlatform.instance.compress(
      request,
      operationId: id,
    );
  }

  /// Compresses many images in one native call.
  ///
  /// The native side fans requests out across its worker pool and reports one
  /// [ImageBatchItemResult] per request in input order; a failing item never
  /// fails the batch. [batchId] scopes the generated operation ids so a
  /// [cancelImageCompression] call can pull queued items before they decode.
  Future<List<ImageBatchItemResult>> compressBatch(
    List<ImageCompressionRequest> requests, {
    String? batchId,
    int maxConcurrent = 4,
  }) {
    if (requests.isEmpty) {
      throw ArgumentError.value(requests, 'requests', 'must not be empty');
    }
    if (maxConcurrent < 1 || maxConcurrent > 8) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'must be within 1..8',
      );
    }
    final id = batchId ?? _newOperationId('imagebatch');
    return MaxmediaImageNativePlatform.instance.compressBatch(
      requests,
      batchId: id,
      maxConcurrent: maxConcurrent,
    );
  }

  /// Cancels queued or in-flight image compression operations and releases
  /// their decoded pixel memory on the native side.
  ///
  /// Without [operationIds] every active operation is cancelled. Cancelled
  /// operations resolve with `terminal: CompressionTerminal.cancelled`;
  /// queued items that never started report zero bytes.
  Future<void> cancelImageCompression({Set<String>? operationIds}) =>
      MaxmediaImageNativePlatform.instance.cancelImageCompression(
        operationIds: operationIds,
      );

  /// Emits one [ImageBatchProgress] event each time a batch item settles
  /// (completes, fails, or is cancelled).
  Stream<ImageBatchProgress> batchProgress() =>
      MaxmediaImageNativePlatform.instance.batchProgress();
}
