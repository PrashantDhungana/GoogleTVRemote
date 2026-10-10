import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'remote_controller.dart';
import 'ui/remote_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final controller = RemoteController();
  await controller.load();
  runApp(TvRemoteApp(controller: controller));
}

class TvRemoteApp extends StatelessWidget {
  const TvRemoteApp({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Remote',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: RemoteScreen(controller: controller),
    );
  }

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8), brightness: brightness),
  );
}
