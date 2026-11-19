import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/units.dart';

/// App preferences, kept in a small JSON file next to the saved scans.
class AppSettings {
  static final unit = ValueNotifier<LengthUnit>(LengthUnit.meters);
  static bool skipScanGuide = false;

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}room_measure');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}settings.json');
  }

  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final u = j['unit'] as String?;
      unit.value = LengthUnit.values
          .firstWhere((e) => e.name == u, orElse: () => LengthUnit.meters);
      skipScanGuide = j['skipScanGuide'] as bool? ?? false;
    } catch (_) {
      // Defaults are fine when settings can't be read.
    }
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'unit': unit.value.name,
        'skipScanGuide': skipScanGuide,
      }));
    } catch (_) {}
  }

  static Future<void> setUnit(LengthUnit u) async {
    unit.value = u;
    await _save();
  }

  static Future<void> setSkipScanGuide(bool v) async {
    skipScanGuide = v;
    await _save();
  }
}
