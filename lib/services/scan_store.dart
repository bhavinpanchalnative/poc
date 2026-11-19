import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/models.dart';

/// Saves scans as JSON files in the app's documents folder.
class ScanStore {
  static Future<Directory> _dir(String sub) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}room_measure'
        '${Platform.pathSeparator}$sub');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> exportsDir() => _dir('exports');

  /// The file of a room photo stored under [name].
  static Future<File> photoFile(String name) async =>
      File('${(await _dir('photos')).path}${Platform.pathSeparator}$name');

  /// Copies a photo (e.g. from the scanner's temporary folder) into the
  /// app's photo folder and returns its stored name.
  static Future<String> keepPhoto(String path, {String prefix = 'room'}) async {
    final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final name = '${prefix}_${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(path).copy((await photoFile(name)).path);
    return name;
  }

  static Future<File> _file(String id) async =>
      File('${(await _dir('scans')).path}${Platform.pathSeparator}$id.json');

  static Future<void> save(RoomScan scan) async {
    final f = await _file(scan.id);
    await f.writeAsString(const JsonEncoder.withIndent('  ')
        .convert(scan.toJson()));
  }

  static Future<void> delete(String id) async {
    final f = await _file(id);
    if (await f.exists()) {
      // Take the room's photos with it.
      try {
        final scan = RoomScan.fromJson(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        for (final p in scan.photos) {
          final pf = await photoFile(p);
          if (await pf.exists()) await pf.delete();
        }
      } catch (_) {}
      await f.delete();
    }
  }

  static Future<List<RoomScan>> loadAll() async {
    final dir = await _dir('scans');
    final scans = <RoomScan>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        scans.add(RoomScan.fromJson(
            jsonDecode(await e.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Skip unreadable files rather than failing the whole list.
      }
    }
    scans.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return scans;
  }
}

/// Saves floor maps (rooms arranged together) next to the scans.
class MapStore {
  static Future<File> _file(String id) async {
    final dir = await ScanStore._dir('maps');
    return File('${dir.path}${Platform.pathSeparator}$id.json');
  }

  static Future<void> save(FloorMap map) async {
    final f = await _file(map.id);
    await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(map.toJson()));
  }

  static Future<void> delete(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }

  static Future<List<FloorMap>> loadAll() async {
    final dir = await ScanStore._dir('maps');
    final maps = <FloorMap>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        maps.add(FloorMap.fromJson(
            jsonDecode(await e.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Skip unreadable files rather than failing the whole list.
      }
    }
    maps.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return maps;
  }
}

/// Stand-alone distance measurements (not part of a room), newest first.
class LineStore {
  static Future<File> _file() async {
    final dir = await ScanStore._dir('lines');
    return File('${dir.path}${Platform.pathSeparator}lines.json');
  }

  static Future<List<MeasuredLine>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List)
          .map((l) => MeasuredLine.fromJson(l as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<MeasuredLine> lines) async {
    final f = await _file();
    await f.writeAsString(jsonEncode([for (final l in lines) l.toJson()]));
  }
}

/// Doors and windows measured without a room, newest first.
class OpeningStore {
  static Future<File> _file() async {
    final dir = await ScanStore._dir('openings');
    return File('${dir.path}${Platform.pathSeparator}openings.json');
  }

  static Future<List<SavedOpening>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List)
          .map((o) => SavedOpening.fromJson(o as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SavedOpening> openings) async {
    final f = await _file();
    await f.writeAsString(jsonEncode([for (final o in openings) o.toJson()]));
  }
}
