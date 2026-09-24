import 'package:media_route_contracts/media_route_contracts.dart';

void main() {
  final request = ImageCompressionRequest(
    inputPath: '/absolute/input.jpg',
    outputPath: '/absolute/output.webp',
    format: ImageFormat.webp,
    quality: 0.8,
    resizePolicy: ImageResizePolicy.social,
  );

  final payload = request.toJson();
  final restored = ImageCompressionRequest.fromJson(payload);
  print(restored.toJson());
}
