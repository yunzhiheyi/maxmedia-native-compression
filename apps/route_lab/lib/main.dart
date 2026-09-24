import 'package:flutter/material.dart';

import 'data/compression_service.dart';
import 'data/media_selection_service.dart';
import 'data/route_repository.dart';
import 'presentation/route_lab_screen.dart';
import 'presentation/route_lab_view_model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = RouteRepository(const NativeCompressionService());
  runApp(
    RouteLabApp(
      viewModel: RouteLabViewModel(repository),
      mediaSelectionService: const NativeMediaSelectionService(),
    ),
  );
}

class RouteLabApp extends StatelessWidget {
  const RouteLabApp({
    required this.viewModel,
    this.mediaSelectionService = const NativeMediaSelectionService(),
    super.key,
  });

  final RouteLabViewModel viewModel;
  final MediaSelectionService mediaSelectionService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MaxMedia Route Lab',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3b5bdb)),
      useMaterial3: true,
    ),
    home: RouteLabScreen(
      viewModel: viewModel,
      mediaSelectionService: mediaSelectionService,
    ),
  );
}
