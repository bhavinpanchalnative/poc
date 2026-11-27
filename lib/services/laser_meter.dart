import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// Where the connection to the laser meter is.
enum LaserState { off, searching, connecting, connected }

/// A Bluetooth laser distance meter (Leica DISTO, Bluetooth LE).
///
/// The user presses the measure button on the laser; the DISTO then sends
/// the distance itself, and it arrives on [readings] (metres). No commands
/// are sent to it, so it works the same on DISTO models whose command set
/// differs (D1, D2, D110, D510, X3, X4...).
class LaserMeter extends ChangeNotifier {
  LaserMeter._();

  static final instance = LaserMeter._();

  /// The DISTO's measurement service.
  static final service = Uuid.parse('3ab10100-f831-4395-b29d-570977d5bf94');

  /// Characteristics that carry the distance: 4 bytes, a little-endian
  /// 32-bit float in metres. 0101 on the D1 / D2 / D110 / D510 range, 010d on
  /// the X3 / X4. Others in the service carry the unit, angles and so on.
  static const distanceCharacteristics = {
    '3ab10101-f831-4395-b29d-570977d5bf94',
    '3ab1010d-f831-4395-b29d-570977d5bf94',
  };

  final _ble = FlutterReactiveBle();
  final _readings = StreamController<double>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  final _subs = <StreamSubscription<List<int>>>[];
  Timer? _scanTimeout;

  LaserState state = LaserState.off;

  /// The connected laser's name ("DISTO D2 1234...").
  String? deviceName;

  /// Why the last connection attempt failed, for the user.
  String? error;

  /// The last distance measured (m).
  double? last;

  /// Distances as they are measured (m).
  Stream<double> get readings => _readings.stream;

  bool get connected => state == LaserState.connected;

  /// The distance in a notification from [characteristic], or null when
  /// it is not a distance (another characteristic, or not a plausible one).
  static double? parseDistance(String characteristic, List<int> bytes) {
    if (!distanceCharacteristics.contains(characteristic.toLowerCase())) return null;
    if (bytes.length < 4) return null;
    final v = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4))).getFloat32(0, Endian.little);
    if (!v.isFinite || v < 0.02 || v > 400) return null;
    return v;
  }

  void _set(LaserState s, {String? err}) {
    state = s;
    error = err;
    notifyListeners();
  }

  /// Finds a DISTO nearby (switched on, Bluetooth on) and connects to it.
  Future<void> connect() async {
    if (state != LaserState.off) return;
    _set(LaserState.searching);
    if (Platform.isAndroid) {
      final ok = await const MethodChannel('room_measure/ar').invokeMethod<bool>('bluetoothPermission');
      if (ok != true) {
        _set(LaserState.off, err: 'Bluetooth permission is needed to connect the laser.');
        return;
      }
    }
    final status = await _ble.statusStream.firstWhere((s) => s != BleStatus.unknown).timeout(
          const Duration(seconds: 5),
          onTimeout: () => BleStatus.unknown,
        );
    if (status != BleStatus.ready) {
      _set(LaserState.off, err: switch (status) {
        BleStatus.poweredOff => 'Bluetooth is off. Turn it on and try again.',
        BleStatus.unauthorized => 'Bluetooth access is off for this app. Allow it in Settings.',
        BleStatus.locationServicesDisabled => 'Location is off. Android needs it on to find Bluetooth devices.',
        BleStatus.unsupported => 'This phone has no Bluetooth LE.',
        _ => 'Bluetooth is not ready.',
      });
      return;
    }
    _scanTimeout = Timer(const Duration(seconds: 20), () {
      if (state != LaserState.searching) return;
      _scan?.cancel();
      _set(LaserState.off,
          err: 'No DISTO found. Switch it on, turn on its Bluetooth (the Bluetooth key), and keep it close.');
    });
    _scan = _ble.scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency).listen((d) {
      if (state != LaserState.searching) return;
      if (!d.name.toUpperCase().contains('DISTO')) return;
      _scanTimeout?.cancel();
      _scan?.cancel();
      _connectTo(d);
    }, onError: (Object e) => _fail('Search failed: $e'));
  }

  void _connectTo(DiscoveredDevice d) {
    deviceName = d.name;
    _set(LaserState.connecting);
    _connection = _ble.connectToDevice(id: d.id, connectionTimeout: const Duration(seconds: 15)).listen((u) async {
      switch (u.connectionState) {
        case DeviceConnectionState.connected:
          try {
            await _subscribe(d.id);
            _set(LaserState.connected);
          } catch (e) {
            _fail('This laser could not be read: $e');
          }
        case DeviceConnectionState.disconnected:
          if (state != LaserState.off) _fail(state == LaserState.connected ? null : 'Could not connect to ${d.name}.');
        default:
      }
    }, onError: (Object e) => _fail('Connection failed: $e'));
  }

  Future<void> _subscribe(String id) async {
    await _ble.discoverAllServices(id);
    final services = await _ble.getDiscoveredServices(id);
    final disto = services.where((s) => s.id == service).toList();
    if (disto.isEmpty) throw StateError('no DISTO measurement service');
    for (final c in disto.first.characteristics) {
      final cid = c.id.toString().toLowerCase();
      if (!distanceCharacteristics.contains(cid) || !(c.isNotifiable || c.isIndicatable)) continue;
      _subs.add(c.subscribe().listen((bytes) {
        final v = parseDistance(cid, bytes);
        if (v == null) return;
        last = v;
        _readings.add(v);
        notifyListeners();
      }, onError: (_) {}));
    }
    if (_subs.isEmpty) throw StateError('no distance characteristic');
  }

  void _fail(String? message) {
    _cleanUp();
    _set(LaserState.off, err: message);
  }

  void _cleanUp() {
    _scanTimeout?.cancel();
    _scan?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _connection?.cancel();
    _connection = null;
  }

  /// Disconnects (or stops searching).
  void disconnect() {
    _cleanUp();
    deviceName = null;
    _set(LaserState.off);
  }
}
