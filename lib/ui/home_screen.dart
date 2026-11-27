import 'package:flutter/material.dart';

import '../capture/ar_measure.dart';
import '../engine/floor_map.dart';
import '../engine/floor_plan_builder.dart';
import '../engine/models.dart';
import '../engine/sample_rooms.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/plan_exporter.dart';
import '../services/scan_store.dart';
import 'app_theme.dart';
import 'brand.dart';
import 'common.dart';
import 'distances_screen.dart';
import 'floor_map_painter.dart';
import 'floor_map_screen.dart';
import 'history_view.dart';
import 'manual_entry_screen.dart';
import 'nav_bar.dart';
import 'opening_drawing_screen.dart';
import 'photo_measure_screen.dart';
import 'plan_painter.dart';
import 'plan_screen.dart';
import 'scan_guide_screen.dart';

String formatDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final l = d.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

FloorPlan? tryBuild(RoomScan s) {
  try {
    return const FloorPlanBuilder().build(s);
  } on PlanException {
    return null;
  }
}

/// Start screen: scan or enter a room, and open saved rooms.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.debugMethod});

  /// Overrides the device check (for tests and screenshots).
  @visibleForTesting
  final ScanMethod? debugMethod;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RoomScan> saved = [];
  List<FloorMap> maps = [];
  List<SavedOpening> looseOpenings = [];
  List<MeasuredLine> looseLines = [];

  /// 0 Measure, 1 History.
  int _page = 0;
  final plans = <String, FloorPlan?>{};
  bool loading = true;
  ScanMethod? method;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.debugMethod != null) {
      method = widget.debugMethod;
      return;
    }
    RoomScanner.availableMethod().then((m) {
      if (mounted) setState(() => method = m);
    });
  }

  Future<void> _load() async {
    List<RoomScan> scans;
    List<FloorMap> floorMaps;
    try {
      scans = await ScanStore.loadAll();
    } catch (_) {
      scans = [];
    }
    try {
      floorMaps = await MapStore.loadAll();
    } catch (_) {
      floorMaps = [];
    }
    final loose = await OpeningStore.load();
    final lines = await LineStore.load();
    if (!mounted) return;
    setState(() {
      saved = scans;
      maps = floorMaps;
      looseOpenings = loose;
      looseLines = lines;
      plans
        ..clear()
        ..addEntries(scans.map((s) => MapEntry(s.id, tryBuild(s))));
      loading = false;
    });
  }

  /// New rooms start without a name: the user types it (asked for once it is measured).
  String get _nextName => '';

  /// The room most recently measured in (a saved room, or the room given
  /// for a door / window): offered for the next door / window.
  String get _lastRoomName {
    final candidates = <(DateTime, String)>[
      for (final s in saved)
        if (s.name.trim().isNotEmpty) (s.createdAt, s.name),
      for (final o in looseOpenings)
        if (o.room.trim().isNotEmpty) (o.measuredAt, o.room),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return candidates.isEmpty ? '' : candidates.first.$2;
  }

  Future<void> _open(
    RoomScan scan, {
    bool saved = false,
    bool justScanned = false,
    int? openOpening,
    int initialTab = 0,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanScreen(
          scan: scan,
          saved: saved,
          justScanned: justScanned,
          openOpening: openOpening,
          initialTab: initialTab,
        ),
      ),
    );
    _load();
  }

  String _len(double m) => formatLength(m, AppSettings.unit.value);

  /// The user names what was just measured: the room, and any lines and
  /// surfaces in it, that have no name yet. Mandatory: nothing is saved
  /// before every name is typed.
  Future<void> _nameScan(RoomScan scan, {String? suggestion}) async {
    final labels = <String>[];
    final apply = <void Function(String)>[];
    final initial = <String>[];
    if (isUnnamed(scan.name)) {
      labels.add('Room name');
      apply.add((n) => scan.name = n);
      // What kind of room the scanner recognised (LiDAR), to accept or change.
      initial.add(suggestion ?? '');
    }
    for (var k = 0; k < scan.lines.length; k++) {
      final l = scan.lines[k];
      if (!isUnnamed(l.name)) continue;
      labels.add('Line · ${_len(l.length)}');
      apply.add((n) => scan.lines[k] = scan.lines[k].copyWith(name: n));
    }
    for (var k = 0; k < scan.surfaces.length; k++) {
      final m = scan.surfaces[k];
      if (!isUnnamed(m.name)) continue;
      labels.add('${m.kind.label} · ${_len(m.width)} × ${_len(m.height)}');
      apply.add((n) => scan.surfaces[k] = scan.surfaces[k].copyWith(name: n));
    }
    if (labels.isEmpty || !mounted) return;
    final names = await askNames(context,
        title: labels.length == 1 ? 'Name this room' : 'Name your measurements',
        labels: labels,
        initial: initial);
    for (var i = 0; i < names.length; i++) {
      apply[i](names[i]);
    }
  }

  /// LiDAR, several rooms scanned in one go: the user names the floor and
  /// each room (offered as recognised: Kitchen, Bedroom...), then the rooms
  /// are saved and placed on a new floor map as they were scanned, which
  /// opens.
  Future<void> _saveFloor(CapturedScan captured) async {
    final rooms = captured.floorRooms;
    final suggested = captured.floorSuggestedNames;
    String size(RoomScan s) {
      try {
        final p = const FloorPlanBuilder().build(s);
        return '${_len(p.overallSize.width)} × ${_len(p.overallSize.depth)}';
      } on PlanException {
        return '${s.walls.length} walls';
      }
    }

    final labels = [
      'Floor name',
      for (var i = 0; i < rooms.length; i++) 'Room ${i + 1} · ${size(rooms[i])}',
    ];
    final names = await askNames(context,
        title: 'Name the ${rooms.length} rooms scanned',
        labels: labels,
        initial: ['', ...suggested]);
    if (!mounted) return;
    // Not named (dialog closed): the rooms are still kept, with the names
    // offered, so nothing scanned is lost.
    final ok = names.length == labels.length;
    String nameOf(int i) {
      final n = ok ? names[i + 1].trim() : '';
      if (n.isNotEmpty) return n;
      return i < suggested.length ? suggested[i] : 'Room ${i + 1}';
    }

    final mapName = ok && names[0].trim().isNotEmpty
        ? names[0].trim()
        : 'Floor ${DateTime.now().day}/${DateTime.now().month}';
    final map = FloorMap(
      id: RoomScan.newId(),
      name: mapName,
      createdAt: DateTime.now(),
    );
    for (var i = 0; i < rooms.length; i++) {
      final s = rooms[i];
      s.name = nameOf(i);
      await ScanStore.save(s);
      final off = i < captured.floorOffsets.length ? captured.floorOffsets[i] : null;
      // A room whose plan can't be built is saved, but not put on the map
      // (it shows in History to be fixed).
      if (off != null) map.rooms.add(MapRoom(scanId: s.id, offset: off));
    }
    await MapStore.save(map);
    if (!mounted) return;
    showMessage(context, '${rooms.length} rooms saved as the floor map "$mapName".');
    await _openMap(map);
  }

  Future<void> _saveAndOpen(
    RoomScan scan, {
    bool justScanned = false,
    int? openOpening,
    String? suggestedName,
  }) async {
    await _nameScan(scan, suggestion: suggestedName);
    if (!mounted) return;
    await ScanStore.save(scan);
    if (!mounted) return;
    await _open(
      scan,
      saved: true,
      justScanned: justScanned,
      openOpening: openOpening,
    );
  }

  Future<void> _openLooseOpening(
    SavedOpening o, {
    bool justScanned = false,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            OpeningDrawingScreen(opening: o, justScanned: justScanned),
      ),
    );
    _load();
  }

  Future<void> _scan() async {
    final m = method;
    if (m == null || m == ScanMethod.none) return;
    if (!AppSettings.skipScanGuide) {
      final go = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => ScanGuideScreen(method: m)),
      );
      if (go != true || !mounted) return;
    }
    CapturedScan? captured;
    try {
      captured = await RoomScanner.scan(m, name: _nextName);
    } on ScanFailure catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.no_photography_outlined),
          title: const Text('Scanning unavailable'),
          content: Text(e.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (captured == null || !mounted) return;
    if (!captured.hasRoom) {
      // No room outline: doors / windows and distances are kept on their
      // own rather than building a plan with no walls.
      final lines = captured.scan.lines;
      for (final p in captured.scan.photos) {
        try {
          await (await ScanStore.photoFile(p)).delete();
        } catch (_) {}
      }
      // The user names each door, window and line measured (mandatory),
      // and says which room the doors / windows are in, so the room shows
      // with them everywhere.
      var loose = captured.looseOpenings;
      final askRoom = loose.isNotEmpty;
      final labels = [
        if (askRoom) 'Room',
        for (final o in loose)
          '${o.type.label} · ${_len(o.width)}${o.height == null ? '' : ' × ${_len(o.height!)}'}',
        for (final l in lines) 'Line · ${_len(l.length)}',
      ];
      final first = askRoom ? 1 : 0;
      final names = labels.isEmpty || !mounted
          ? const <String>[]
          : await askNames(context,
              title: labels.length - first == 1
                  ? 'Name this ${loose.isEmpty ? 'line' : loose.first.type.label.toLowerCase()}'
                  : 'Name your measurements',
              labels: labels,
              initial: [if (askRoom) _lastRoomName]);
      if (names.length == labels.length) {
        final room = askRoom ? names[0] : '';
        loose = [
          for (var i = 0; i < loose.length; i++)
            loose[i].copyWith(name: names[first + i], room: room),
        ];
      }
      String lineName(int i) =>
          names.length == labels.length ? names[first + loose.length + i] : '';
      if (loose.isNotEmpty) {
        await OpeningStore.save([
          ...loose.reversed,
          ...await OpeningStore.load(),
        ]);
      }
      if (lines.isEmpty) {
        if (loose.isEmpty || !mounted) return;
        // Straight to the drawing of the door / window whose ✓ finished
        // the scan.
        final k = captured.focusOpening ?? loose.length - 1;
        await _openLooseOpening(
          loose[k.clamp(0, loose.length - 1)],
          justScanned: true,
        );
        return;
      }
      final kept = await LineStore.load();
      await LineStore.save([
        for (var i = lines.length - 1; i >= 0; i--)
          MeasuredLine(
            name: lineName(i),
            length: lines[i].length,
            run: lines[i].run,
            rise: lines[i].rise,
            measuredAt: DateTime.now(),
            estimated: lines[i].estimated,
          ),
        ...kept,
      ]);
      if (!mounted) return;
      // A door / window's ✓ finished the scan: its drawing first (the
      // lines are saved in Distances too).
      final k = captured.focusOpening;
      if (k != null && loose.isNotEmpty) {
        await _openLooseOpening(
          loose[k.clamp(0, loose.length - 1)],
          justScanned: true,
        );
      } else {
        await _distances();
      }
      return;
    }
    // Several rooms (LiDAR): saved together as a floor map.
    if (captured.isFloor) {
      await _saveFloor(captured);
      return;
    }
    // Straight to the floor plan: the room is named automatically and can
    // be renamed there.
    final est = captured.estimatedWalls;
    if (est > 0) {
      showMessage(
        context,
        '$est wall${est == 1 ? ' was' : 's were'} estimated from the floor. '
        'Check ${est == 1 ? 'its length' : 'their lengths'} with Edit shape.',
      );
    }
    await _saveAndOpen(
      captured.scan,
      justScanned: captured.complete,
      openOpening: captured.focusOpening,
      suggestedName: captured.suggestedName,
    );
  }

  Future<void> _manual() async {
    final scan = await Navigator.push<RoomScan>(
      context,
      MaterialPageRoute(
        builder: (_) => ManualEntryScreen(defaultName: _nextName),
      ),
    );
    if (scan != null) await _saveAndOpen(scan);
  }

  Future<void> _photo() async {
    final scan = await Navigator.push<RoomScan>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoMeasureScreen(defaultName: _nextName),
      ),
    );
    if (scan != null) await _saveAndOpen(scan);
  }

  Future<void> _distances() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DistancesScreen()),
    );
    _load();
  }

  // ---------------------------------------------------------------- history

  /// Everything saved, as History items: rooms, the doors, windows, lines
  /// and surfaces inside them and those measured on their own, and floor
  /// maps. Each opens its plan or its 2D drawing.
  List<HistoryItem> _historyItems(BuildContext context, LengthUnit unit) {
    final cs = Theme.of(context).colorScheme;
    String len(double m) => formatLength(m, unit);
    final items = <HistoryItem>[];
    for (final s in saved) {
      final p = plans[s.id];
      items.add(
        HistoryItem(
          kind: HistoryKind.room,
          title: s.name,
          subtitle: p == null
              ? 'Needs attention'
              : '${len(p.overallSize.width)} × ${len(p.overallSize.depth)}  ·  ${s.source.label}',
          value: p == null ? null : formatArea(p.area, unit),
          date: s.createdAt,
          thumbnail: PlanThumbnailPainter(
            p,
            fill: cs.primary.withValues(alpha: 0.14),
            stroke: cs.primary,
          ),
          onTap: () => _open(s, saved: true),
          menu: [
            ('Rename', Icons.edit_outlined, () => _rename(s)),
            ('Delete', Icons.delete_outline, () => _delete(s)),
          ],
        ),
      );
      final labels = PlanExporter.openingLabels(s.openings);
      for (final (k, o) in s.openings.indexed) {
        if (o.type == OpeningType.opening) continue;
        final window = o.type == OpeningType.window;
        items.add(
          HistoryItem(
            kind: window ? HistoryKind.window : HistoryKind.door,
            title: labels[k],
            subtitle:
                '${s.name}  ·  wall W${o.wallIndex + 1}'
                '${window && o.sill != null ? '  ·  sill ${len(o.sill!)}' : ''}',
            value: [
              len(o.width),
              if (o.height != null) len(o.height!),
            ].join(' × '),
            estimated: o.estimated,
            date: s.createdAt,
            onTap: () => _open(s, saved: true, openOpening: k),
          ),
        );
      }
      for (final m in s.surfaces) {
        items.add(
          HistoryItem(
            kind: HistoryKind.surface,
            title: m.name,
            subtitle: '${s.name}  ·  ${m.kind.label}',
            value: '${len(m.width)} × ${len(m.height)}',
            date: s.createdAt,
            onTap: () => _open(s, saved: true, initialTab: 3),
          ),
        );
      }
      for (final l in s.lines) {
        items.add(
          HistoryItem(
            kind: HistoryKind.line,
            title: l.name,
            subtitle: s.name,
            value: len(l.length),
            estimated: l.estimated,
            date: l.measuredAt ?? s.createdAt,
            onTap: () => _open(s, saved: true, initialTab: 3),
          ),
        );
      }
    }
    for (final o in looseOpenings) {
      final window = o.type == OpeningType.window;
      items.add(
        HistoryItem(
          kind: window ? HistoryKind.window : HistoryKind.door,
          title: o.name,
          subtitle: [
            o.room.trim().isEmpty ? 'No room' : o.room.trim(),
            if (window && o.sill != null) 'sill ${len(o.sill!)}',
          ].join('  ·  '),
          value: [
            len(o.width),
            if (o.height != null) len(o.height!),
          ].join(' × '),
          estimated: o.estimated,
          date: o.measuredAt,
          onTap: () => _openLooseOpening(o),
        ),
      );
    }
    for (final l in looseLines) {
      items.add(
        HistoryItem(
          kind: HistoryKind.line,
          title: l.name,
          subtitle: 'Distance',
          value: len(l.length),
          estimated: l.estimated,
          date: l.measuredAt ?? DateTime(2000),
          onTap: _distances,
        ),
      );
    }
    final byId = {for (final s in saved) s.id: s};
    for (final m in maps) {
      final rooms = placeRooms(m, byId);
      items.add(
        HistoryItem(
          kind: HistoryKind.map,
          title: m.name,
          subtitle: rooms.isEmpty
              ? 'No rooms yet'
              : '${rooms.length} room${rooms.length == 1 ? '' : 's'}',
          value: rooms.isEmpty ? null : formatArea(totalArea(rooms), unit),
          date: m.createdAt,
          thumbnail: rooms.isEmpty
              ? null
              : MapThumbnailPainter(
                  rooms,
                  fill: cs.primary.withValues(alpha: 0.14),
                  stroke: cs.primary,
                ),
          onTap: () => _openMap(m),
        ),
      );
    }
    return items;
  }

  Widget _history(BuildContext context, LengthUnit unit) {
    final canScan = method != null && method != ScanMethod.none;
    final scan = canScan
        ? const ('Start scan', Icons.photo_camera_outlined)
        : const ('Enter dimensions', Icons.keyboard_alt_outlined);
    final scanAction = HistoryEmptyAction(
      scan.$1,
      scan.$2,
      canScan ? _scan : _manual,
    );
    return HistoryView(
      loading: loading,
      items: _historyItems(context, unit),
      emptyActions: {
        HistoryKind.room: scanAction,
        HistoryKind.door: scanAction,
        HistoryKind.window: scanAction,
        HistoryKind.surface: scanAction,
        if (canScan)
          HistoryKind.line: HistoryEmptyAction(
            'Measure a distance',
            Icons.open_in_full_rounded,
            _distances,
          ),
        HistoryKind.map: HistoryEmptyAction(
          'New map',
          Icons.add_rounded,
          _newMap,
        ),
      },
      // Floor maps: a new one can be started from the list.
      header: (k) => k == HistoryKind.map && maps.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                onPressed: _newMap,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New map'),
              ),
            )
          : null,
    );
  }

  Future<void> _openMap(FloorMap m) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FloorMapScreen(map: m)),
    );
    _load();
  }

  Future<void> _newMap() async {
    if (saved.isEmpty) {
      showMessage(context, 'Scan or enter a room first, then build a map.');
      return;
    }
    final name = await askText(context, title: 'Name this floor map', label: 'Name', confirm: 'Create');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final m = FloorMap(
      id: RoomScan.newId(),
      name: name.trim(),
      createdAt: DateTime.now(),
    );
    await MapStore.save(m);
    if (!mounted) return;
    await _openMap(m);
  }

  Future<void> _rename(RoomScan s) async {
    final v = await askText(
      context,
      title: 'Rename room',
      initial: s.name,
      label: 'Room name',
    );
    if (v == null || v.trim().isEmpty) return;
    s.name = v.trim();
    await ScanStore.save(s);
    _load();
  }

  Future<void> _delete(RoomScan s) async {
    final ok = await confirm(
      context,
      title: 'Delete "${s.name}"?',
      message: 'This room and its floor plan will be removed.',
    );
    if (!ok) return;
    await ScanStore.delete(s.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final history = _page == 1;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        toolbarHeight: 64,
        title: history ? const Text('History') : const BrandLogo(size: 32),
        actions: const [UnitButton(), SizedBox(width: 12)],
      ),
      // Content scrolls on under the floating dock.
      extendBody: true,
      bottomNavigationBar: BrandDock(
        selected: _page,
        onSelected: (i) => setState(() => _page = i),
        items: const [
          DockItem(
            icon: Icons.view_in_ar_outlined,
            selectedIcon: Icons.view_in_ar_rounded,
            label: 'Measure',
          ),
          DockItem(
            icon: Icons.history_rounded,
            selectedIcon: Icons.history_rounded,
            label: 'History',
          ),
        ],
        // The same as the scan card's button: a scan, or manual entry
        // where the camera can't scan.
        actionIcon: method == null || method == ScanMethod.none
            ? Icons.keyboard_alt_outlined
            : Icons.photo_camera_outlined,
        actionLabel: method == null || method == ScanMethod.none
            ? 'Enter dimensions'
            : 'Start scan',
        onAction: method == null
            ? null
            : (method == ScanMethod.none ? _manual : _scan),
      ),
      body: ValueListenableBuilder<LengthUnit>(
        valueListenable: AppSettings.unit,
        builder: (context, unit, _) => IndexedStack(
          index: _page,
          children: [_measure(context, unit), _history(context, unit)],
        ),
      ),
    );
  }

  /// The latest three saved measurements, with a way to the full History.
  List<Widget> _recent(BuildContext context, LengthUnit unit) {
    final items = _historyItems(context, unit)
      ..sort((a, b) => b.date.compareTo(a.date));
    if (loading || items.isEmpty) return const [];
    return [
      SectionLabel(
        'Recent',
        trailing: TextButton(
          onPressed: () => setState(() => _page = 1),
          child: const Text('See all'),
        ),
      ),
      for (final item in items.take(3))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: HistoryTile(item: item, showKind: true),
        ),
    ];
  }

  Widget _measure(BuildContext context, LengthUnit unit) {
    return ListView(
      // Clear of the floating dock (the Scaffold adds its height to the
      // bottom padding because the body extends under it).
      padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.paddingOf(context).bottom + 24),
      children: [
        _ScanCard(method: method, onScan: _scan, onManual: _manual),
        const SectionLabel('Other ways to measure'),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Without camera scanning the big card already offers
              // manual entry; don't show it twice.
              if (method != null && method != ScanMethod.none) ...[
                Expanded(
                  child: _QuickAction(
                    icon: Icons.straighten_rounded,
                    color: AppTheme.brand,
                    title: 'Enter dimensions',
                    subtitle: 'Type lengths from a tape measure',
                    onTap: _manual,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _QuickAction(
                  icon: Icons.add_photo_alternate_outlined,
                  color: AppTheme.surfaceMark,
                  title: 'From a photo',
                  subtitle: 'A floor tile in the photo sets the scale',
                  wide: method == null || method == ScanMethod.none,
                  onTap: _photo,
                ),
              ),
            ],
          ),
        ),
        // Point-to-point distances need the camera scanner.
        if (method != null && method != ScanMethod.none) ...[
          const SizedBox(height: 12),
          _QuickAction(
            icon: Icons.open_in_full_rounded,
            color: AppTheme.lineMark,
            title: 'Measure a distance',
            subtitle: 'The straight line between any two points',
            wide: true,
            onTap: _distances,
          ),
        ],
        ..._recent(context, unit),
        const SectionLabel('Examples'),
        for (final s in SampleRooms.all())
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RoomCard(
              scan: s,
              plan: tryBuild(s),
              unit: unit,
              onTap: () => _open(s),
            ),
          ),
      ],
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({
    required this.method,
    required this.onScan,
    required this.onManual,
  });

  final ScanMethod? method;
  final VoidCallback onScan, onManual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canScan = method == ScanMethod.guided || method == ScanMethod.lidar;
    final subtitle = switch (method) {
      null => 'Checking your device...',
      ScanMethod.guided =>
        'Walk around the room with your camera facing the walls. Walls, '
            'corners and dimensions are measured automatically.',
      ScanMethod.lidar =>
        'Walk around the room. Walls, doors and windows are detected '
            'automatically with LiDAR.',
      ScanMethod.none =>
        'Camera scanning needs an Android phone with ARCore or an iPhone '
            'or iPad with ARKit. You can still enter dimensions by hand.',
    };
    final badge = switch (method) {
      ScanMethod.lidar => 'LiDAR scanner',
      ScanMethod.guided => 'AR scanner',
      _ => null,
    };
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
        gradient: AppTheme.heroGradient,
        boxShadow: [
          BoxShadow(
            color: AppTheme.brand.withValues(alpha: 0.16),
            blurRadius: 24,
            spreadRadius: -6,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          // A faint blueprint grid and room outline behind the text.
          const Positioned.fill(
            child: CustomPaint(painter: _BlueprintPainter()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppTheme.radiusM),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                      ),
                      child: const Icon(
                        Icons.view_in_ar_rounded,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.scan.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: AppTheme.scan.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: AppTheme.scan,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              badge,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.white,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  canScan || method == null ? 'Scan a room' : 'Measure a room',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppTheme.ink,
                      minimumSize: const Size(0, 54),
                    ),
                    onPressed: method == null
                        ? null
                        : (canScan ? onScan : onManual),
                    icon: Icon(
                      canScan
                          ? Icons.photo_camera_outlined
                          : Icons.keyboard_alt_outlined,
                    ),
                    label: Text(canScan ? 'Start scan' : 'Enter dimensions'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The hero card's background: a fine grid and a room outline, like a
/// blueprint, fading out towards the text.
class _BlueprintPainter extends CustomPainter {
  const _BlueprintPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    const step = 22.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    // An L-shaped room in the top-right corner, with a dimension line.
    final w = size.width, o = Offset(w - 150, 24);
    final room = Path()
      ..moveTo(o.dx, o.dy)
      ..lineTo(o.dx + 120, o.dy)
      ..lineTo(o.dx + 120, o.dy + 110)
      ..lineTo(o.dx + 60, o.dy + 110)
      ..lineTo(o.dx + 60, o.dy + 60)
      ..lineTo(o.dx, o.dy + 60)
      ..close();
    canvas.drawPath(
      room,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final dim = Paint()
      ..color = AppTheme.scan.withValues(alpha: 0.45)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(o.dx, o.dy - 10),
      Offset(o.dx + 120, o.dy - 10),
      dim,
    );
    canvas.drawLine(Offset(o.dx, o.dy - 14), Offset(o.dx, o.dy - 6), dim);
    canvas.drawLine(
      Offset(o.dx + 120, o.dy - 14),
      Offset(o.dx + 120, o.dy - 6),
      dim,
    );
  }

  @override
  bool shouldRepaint(_BlueprintPainter old) => false;
}

class _PlanThumb extends StatelessWidget {
  const _PlanThumb({required this.painter});
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
      ),
      child: CustomPaint(painter: painter),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.scan,
    required this.plan,
    required this.unit,
    required this.onTap,
  });

  final RoomScan scan;
  final FloorPlan? plan;
  final LengthUnit unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = plan;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _PlanThumb(
                painter: PlanThumbnailPainter(
                  p,
                  fill: cs.primary.withValues(alpha: 0.14),
                  stroke: cs.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      scan.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    if (p == null)
                      Text(
                        'Needs attention',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.error,
                        ),
                      )
                    else
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: formatArea(p.area, unit),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontFeatures: AppTheme.tabular,
                              ),
                            ),
                            TextSpan(
                              text:
                                  '   ${formatLength(p.overallSize.width, unit)} × '
                                  '${formatLength(p.overallSize.depth, unit)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontFeatures: AppTheme.tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _Tag(scan.source.label),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            formatDate(scan.createdAt),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small rounded label, e.g. how a room was measured.
class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.wide = false,
  });

  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;

  /// Full width: icon beside the text instead of above it.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
      ),
      child: Icon(icon, color: color, size: 22),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: wide
              ? Row(
                  children: [
                    badge,
                    const SizedBox(width: 14),
                    Expanded(child: text),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [badge, const SizedBox(height: 14), text],
                ),
        ),
      ),
    );
  }
}
