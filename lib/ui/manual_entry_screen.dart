import 'package:flutter/material.dart';

import '../engine/floor_plan_builder.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import 'common.dart';

enum _Shape { rectangle, custom }

class _WallRow {
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
  final _height = TextEditingController();
  final _walls = [for (var i = 0; i < 4; i++) _WallRow()];
  var _shape = _Shape.rectangle;

  LengthUnit get unit => AppSettings.unit.value;

  void _create() {
    if (!_form.currentState!.validate()) return;
    final List<double> lengths;
    final List<double> turns;
    if (_shape == _Shape.rectangle) {
      final l = parseLength(_length.text, unit)!;
      final w = parseLength(_width.text, unit)!;
      lengths = [l, w, l, w];
      turns = [90, 90, 90, 90];
    } else {
      lengths = [for (final r in _walls) parseLength(r.length.text, unit)!];
      turns = [for (final r in _walls) r.left ? 90.0 : -90.0];
      final sum = turns.fold(0.0, (a, b) => a + b);
      if (sum.abs() != 360) {
        showMessage(
            context,
            'The turns don\'t close the room. A room needs 4 more turns one '
            'way than the other (now ${(sum / 90).round().abs()}).');
        return;
      }
    }
    final scan = RoomScan(
      id: RoomScan.newId(),
      name: _name.text.trim().isEmpty ? widget.defaultName : _name.text.trim(),
      createdAt: DateTime.now(),
      source: CaptureSource.manual,
      walls: wallsFromLengths(lengths, turns),
      height: _height.text.trim().isEmpty
          ? null
          : parseLength(_height.text, unit),
    );
    try {
      const FloorPlanBuilder().build(scan);
    } on PlanException catch (e) {
      showMessage(context, e.message);
      return;
    }
    Navigator.pop(context, scan);
  }

  Widget _section(Widget child) => Card(
        child: Padding(padding: const EdgeInsets.all(18), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
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
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SectionLabel('Room'),
              _section(
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Room name'),
                ),
              ),
              const SectionLabel('Shape'),
              _section(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<_Shape>(
                    segments: const [
                      ButtonSegment(
                          value: _Shape.rectangle,
                          icon: Icon(Icons.crop_square_rounded),
                          label: Text('Rectangle')),
                      ButtonSegment(
                          value: _Shape.custom,
                          icon: Icon(Icons.polyline_outlined),
                          label: Text('Custom shape')),
                    ],
                    selected: {_shape},
                    onSelectionChanged: (s) =>
                        setState(() => _shape = s.first),
                  ),
                  const SizedBox(height: 18),
                  if (_shape == _Shape.rectangle) ...[
                    LengthField(
                        controller: _length, unit: unit, label: 'Length'),
                    const SizedBox(height: 14),
                    LengthField(controller: _width, unit: unit, label: 'Width'),
                  ] else ...[
                    Text(
                      'Walk around the room and enter each wall in order. '
                      'After each wall, choose which way the next one turns.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
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
                                  label: 'Wall ${i + 1}'),
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
                                      tooltip: 'Then turn left'),
                                  ButtonSegment(
                                      value: false,
                                      icon: Icon(Icons.turn_right_rounded),
                                      tooltip: 'Then turn right'),
                                ],
                                selected: {r.left},
                                onSelectionChanged: (s) =>
                                    setState(() => r.left = s.first),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove wall',
                              onPressed: _walls.length > 3
                                  ? () => setState(() => _walls.removeAt(i))
                                  : null,
                              icon: const Icon(
                                  Icons.remove_circle_outline_rounded),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _walls.add(_WallRow())),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add wall'),
                      ),
                    ),
                  ],
                ],
              )),
              const SectionLabel('Height'),
              _section(
                LengthField(
                  controller: _height,
                  unit: unit,
                  label: 'Ceiling height (optional)',
                  optional: true,
                ),
              ),
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
    );
  }
}
