import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_route_lab/domain/image_compression_policy.dart';
import 'package:media_route_contracts/media_route_contracts.dart';

void main() {
  test('initial quality below the usual floor remains a valid request', () {
    final request = ImageCompressionPolicy.apply(
      ImageCompressionRequest(
        inputPath: '/input.jpg',
        outputPath: '/output.webp',
        format: ImageFormat.webp,
        quality: 0.4,
      ),
    );
    expect(request.minimumQuality, 0.4);
    expect(request.targetCompressionRatio, 0.70);
  });

  test('lossless PNG does not receive lossy quality adaptation', () {
    final request = ImageCompressionPolicy.apply(
      ImageCompressionRequest(
        inputPath: '/input.png',
        outputPath: '/output.png',
        format: ImageFormat.png,
        quality: 0.8,
      ),
    );
    expect(request.minimumQuality, isNull);
    expect(request.targetCompressionRatio, isNull);
  });
}
