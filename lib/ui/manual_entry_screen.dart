import 'package:flutter/material.dart';

import '../engine/floor_plan_builder.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import 'common.dart';
import 'plan_painter.dart';

enum _Shape { rectangle, custom }

class _WallRow {
  _WallRow(VoidCallback onChanged) {
    length.addListener(onChanged);
  }

  final length = TextEditingController();
  bool left = true;
}

/// Builds a room from typed measurements. Pops the new [RoomScan].
class ManualEntryScreen extends StatefulWidget {
  const ManualEntryScreen({super.key, required this.defaultName});

  final String defaultName;

  @override
  State<ManualEntryScreen> createState() => _ManualEntryScreenState();
}

class _ManualEntryScreenState extends State<ManualEntryScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.defaultName);
  final _length = TextEditingController();
  final _width = TextEditingController();
  late final _walls = [for (var i = 0; i < 4; i++) _WallRow(_typed)];
  var _shape = _Shape.rectangle;

  LengthUnit get unit => AppSettings.unit.value;

  @override
  void initState() {
    super.initState();
    for (final c in [_length, _width]) {
      c.addListener(_typed);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _length,
      _width,
      for (final w in _walls) w.length,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _typedAnything => [
    _name,
    _length,
    _width,
    for (final w in _walls) w.length,
  ].any((c) => c.text.trim().isNotEmpty);

  /// A measurement was typed: the floor plan preview follows.
  void _typed() {
    if (mounted) setState(() {});
  }

  /// The room as typed so far, or why it can't be drawn yet.
  ({RoomScan? scan, String? problem}) _room() {
    final List<double> lengths;
    final List<double> turns;
    double? len(TextEditingController c) {
      final v = parseLength(c.text, unit);
      return v == null || v.isNaN || v <= 0 ? null : v;
    }

    if (_shape == _Shape.rectangle) {
      final l = len(_length), w = len(_width);
      if (l == null || w == null) {
        return (
          scan: null,
          problem: 'Enter the length and width to see the floor plan.',
        );
      }
      lengths = [l, w, l, w];
      turns = [90, 90, 90, 90];
    } else {
      final ls = [for (final r in _walls) len(r.length)];
      if (ls.any((l) => l == null)) {
        return (scan: null, problem: 'Enter every wall to see the floor plan.');
      }
      lengths = [for (final l in ls) l!];
      turns = [for (final r in _walls) r.left ? 90.0 : -90.0];
      final sum = turns.fold(0.0, (a, b) => a + b);
      if (sum.abs() != 360) {
        return (
          scan: null,
          problem:
              'The turns don\'t close the room. A room needs 4 more turns one '
              'way than the other (now ${(sum / 90).round().abs()}).',
        );
      }
    }
    final walls = wallsFromLengths(lengths, turns);
    // Going round the room, the last wall must end where the first began.
    // If not, the plan would quietly change some typed lengths to close.
    final gap = walls.last.b.distanceTo(walls.first.a);
    if (_shape == _Shape.custom && gap > 0.05) {
      return (
        scan: null,
        problem:
            'The walls don\x27t meet: the last wall ends ${formatLength(gap, unit)} '
            'from where the first starts. Walls on opposite sides must add up to '
            'the same length: check the lengths and turns.',
      );
    }
    final scan = RoomScan(
      id: RoomScan.newId(),
      name: _name.text.trim(),
      createdAt: DateTime.now(),
      source: CaptureSource.manual,
      walls: walls,
    );
    try {
      const FloorPlanBuilder().build(scan);
    } on PlanException catch (e) {
      return (scan: null, problem: e.message);
    }
    return (scan: scan, problem: null);
  }

  void _create() {
    if (!_form.currentState!.validate()) return;
    final r = _room();
    final scan = r.scan;
    if (scan == null) {
      showMessage(context, r.problem ?? 'Check the measurements.');
      return;
    }
    Navigator.pop(context, scan);
  }

  /// The floor plan of what is typed, drawn as soon as it is complete and
  /// redrawn with every change.
  Widget _preview(ThemeData theme) {
    final r = _room();
    final scan = r.scan;
    FloorPlan? plan;
    if (scan != null) {
      try {
        plan = const FloorPlanBuilder().build(scan);
      } on PlanException {
        plan = null;
      }
    }
    if (plan == null) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            r.problem ?? 'Enter the measurements to see the floor plan.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 1.2,
        child: CustomPaint(
          key: const ValueKey('manual-plan-preview'),
          painter: PlanPainter(plan: plan, unit: unit),
        ),
      ),
    );
  }

  Widget _section(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Back with measurements typed asks first: they were lost silently.
    return PopScope(
      canPop: !_typedAnything,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirm(
          context,
          title: 'Discard these measurements?',
          message: 'What you typed is not saved.',
          action: 'Discard',
        );
        if (leave && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 20,
          title: const Text('Enter dimensions'),
          actions: const [UnitButton(), SizedBox(width: 12)],
        ),
        body: ValueListenableBuilder<LengthUnit>(
          valueListenable: AppSettings.unit,
          builder: (context, unit, _) => Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                Text(
                  'Type the measurements from a tape or laser and get a '
                  'floor plan.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SectionLabel('Room'),
                _section(
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Room name'),
                    // Mandatory: the room is not created without a name.
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: (v) => isUnnamed(v ?? '') ? nameNeeded : null,
                  ),
                ),
                const SectionLabel('Shape'),
                _section(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<_Shape>(
                        segments: const [
                          ButtonSegment(
                            value: _Shape.rectangle,
                            icon: Icon(Icons.crop_square_rounded),
                            label: Text('Rectangle'),
                          ),
                          ButtonSegment(
                            value: _Shape.custom,
                            icon: Icon(Icons.polyline_outlined),
                            label: Text('Custom shape'),
                          ),
                        ],
                        selected: {_shape},
                        onSelectionChanged: (s) =>
                            setState(() => _shape = s.first),
                      ),
                      const SizedBox(height: 18),
                      if (_shape == _Shape.rectangle) ...[
                        LengthField(
                          controller: _length,
                          unit: unit,
                          label: 'Length',
                        ),
                        const SizedBox(height: 14),
                        LengthField(
                          controller: _width,
                          unit: unit,
                          label: 'Width',
                        ),
                      ] else ...[
                        Text(
                          'Walk around the room and enter each wall in order. '
                          'After each wall, choose which way the next one turns.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        for (final (i, r) in _walls.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: LengthField(
                                    controller: r.length,
                                    unit: unit,
                                    label: 'Wall ${i + 1}',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: SegmentedButton<bool>(
                                    showSelectedIcon: false,
                                    style: const ButtonStyle(
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    segments: const [
                                      ButtonSegment(
                                        value: true,
                                        icon: Icon(Icons.turn_left_rounded),
                                        tooltip: 'Then turn left',
                                      ),
                                      ButtonSegment(
                                        value: false,
                                        icon: Icon(Icons.turn_right_rounded),
                                        tooltip: 'Then turn right',
                                      ),
                                    ],
                                    selected: {r.left},
                                    onSelectionChanged: (s) =>
                                        setState(() => r.left = s.first),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove wall',
                                  onPressed: _walls.length > 3
                                      ? () {
                                          final gone = _walls.removeAt(i);
                                          setState(() {});
                                          // Once its field has gone.
                                          WidgetsBinding.instance
                                              .addPostFrameCallback(
                                                (_) => gone.length.dispose(),
                                              );
                                        }
                                      : null,
                                  icon: const Icon(
                                    Icons.remove_circle_outline_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _walls.add(_WallRow(_typed))),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add wall'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SectionLabel('Floor plan'),
                _section(_preview(theme)),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Material(
          color: cs.surface,
          shape: Border(top: BorderSide(color: cs.outlineVariant)),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.architecture_rounded),
                  label: const Text('Create floor plan'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
