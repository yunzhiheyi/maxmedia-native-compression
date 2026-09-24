import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

import 'maxmedia_image_native_platform_interface.dart';
import 'src/image_batch_types.dart';

/// An implementation of [MaxmediaImageNativePlatform] that uses method channels.
class MethodChannelMaxmediaImageNative extends MaxmediaImageNativePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('maxmedia_image_native');

  /// Progress events for batch compression, one per settled item.
  @visibleForTesting
  final batchProgressChannel = const EventChannel(
    'maxmedia_image_native/batch_progress',
  );

  @override
  Future<CapabilityReport> capabilities() async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'capabilities',
    );
    if (value == null) throw const FormatException('Missing capability report');
    return CapabilityReport.fromJson(value);
  }

  @override
  Future<CompressionResult> compress(
    ImageCompressionRequest request, {
    required String operationId,
  }) async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'compress',
      request.toJson()..['operationId'] = operationId,
    );
    if (value == null) {
      throw const FormatException('Missing compression result');
    }
    return CompressionResult.fromJson(value);
  }

  @override
  Future<List<ImageBatchItemResult>> compressBatch(
    List<ImageCompressionRequest> requests, {
    required String batchId,
    int maxConcurrent = 4,
  }) async {
    final value = await methodChannel.invokeMapMethod<Object?, Object?>(
      'compressBatch',
      {
        'batchId': batchId,
        'maxConcurrent': maxConcurrent,
        'requests': [
          for (var index = 0; index < requests.length; index += 1)
            requests[index].toJson()..['operationId'] = '$batchId#$index',
        ],
      },
    );
    if (value == null) throw const FormatException('Missing batch results');
    final items = value['results']! as List<Object?>;
    return [for (final item in items) ImageBatchItemResult.fromJson(item)];
  }

  @override
  Future<void> cancelImageCompression({Set<String>? operationIds}) async {
    await methodChannel.invokeMethod<void>('cancelImageCompression', {
      if (operationIds != null)
        'operationIds': operationIds.toList(growable: false),
    });
  }

  @override
  Stream<ImageBatchProgress> batchProgress() => batchProgressChannel
      .receiveBroadcastStream()
      .map(ImageBatchProgress.fromJson);
}
