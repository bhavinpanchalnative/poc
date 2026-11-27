import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/app_settings.dart';
import 'ui/app_theme.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phones: portrait only. In landscape the screens left too little room
  // between the top bar and the dock (the scan card was hidden under it).
  // Tablets keep turning.
  final view = ui.PlatformDispatcher.instance.views.firstOrNull;
  final shortest = view == null ? 0.0 : view.physicalSize.shortestSide / view.devicePixelRatio;
  if (shortest > 0 && shortest < 600) {
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }
  await AppSettings.load();
  runApp(const RoomMeasureApp());
}

class RoomMeasureApp extends StatelessWidget {
  const RoomMeasureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppTheme.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
