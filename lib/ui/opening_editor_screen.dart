import 'package:flutter/material.dart';

import '../engine/elevation.dart';
import '../engine/floor_plan_builder.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import 'app_theme.dart';
import 'common.dart';
import 'elevation_painter.dart';

/// What the editor hands back: the edited opening, or a request to delete it.
class OpeningEdit {
  const OpeningEdit.save(Opening this.opening) : delete = false;
  const OpeningEdit.delete()
      : opening = null,
        delete = true;
  final Opening? opening;
  final bool delete;
}

/// The front view of one door or window with all its dimensions. Its edges
/// can be dragged on the drawing, or the numbers typed in.
class OpeningEditorScreen extends StatefulWidget {
  const OpeningEditorScreen({
    super.key,
    required this.plan,
    required this.opening,
    required this.label,
  });

  final FloorPlan plan;
  final Opening opening;

  /// E.g. "D1" or "W2", as listed in the room.
  final String label;

  @override
  State<OpeningEditorScreen> createState() => _OpeningEditorScreenState();
}

class _OpeningEditorScreenState extends State<OpeningEditorScreen> {
  late Opening opening = widget.opening;
  late OpeningElevation e = OpeningElevation.of(widget.plan, opening);
  OpeningEdge? _drag;
  bool _changed = false;

  final _width = TextEditingController();
  final _height = TextEditingController();
  final _sill = TextEditingController();
  final _left = TextEditingController();

  LengthUnit get unit => AppSettings.unit.value;

  @override
  void initState() {
    super.initState();
    _fillFields();
  }

  @override
  void dispose() {
    for (final c in [_width, _height, _sill, _left]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fillFields() {
    _width.text = editableLength(e.width, unit);
    _height.text = editableLength(e.height, unit);
    _sill.text = editableLength(e.sill, unit);
    _left.text = editableLength(e.left, unit);
  }

  void _set(OpeningElevation next, {bool fields = true}) {
    setState(() {
      e = next;
      _changed = true;
      if (fields) _fillFields();
    });
  }

  /// Snap to whole centimetres so dragged values read cleanly.
  double _snap(double m) => (m * 100).roundToDouble() / 100;

  void _applyField(TextEditingController c, OpeningEdge? edge) {
    final v = parseLength(c.text, unit);
    if (v == null || v.isNaN || v < 0) {
      _fillFields();
      return;
    }
    switch (c) {
      case final x when x == _width:
        _set(e.withEdge(OpeningEdge.right, e.left + v));
      case final x when x == _height:
        _set(e.withEdge(OpeningEdge.top, e.sill + v));
      case final x when x == _sill:
        // Moving the sill keeps the window's height.
        final h = e.height;
        _set(e.copyWith(sill: v.clamp(0.0, e.wallHeight - h)));
      case final x when x == _left:
        _set(e.copyWith(left: v.clamp(0.0, e.wallLength - e.width)));
    }
  }

  void _setType(OpeningType t) {
    if (t == opening.type) return;
    opening = opening.copyWith(
      type: t,
      // A window needs a sill; a door stands on the floor.
      sill: t == OpeningType.window ? OpeningElevation.typicalSill : null,
      clearSill: t != OpeningType.window,
      clearHeight: true,
    );
    _set(OpeningElevation.of(widget.plan, opening));
  }

  void _save() {
    Navigator.pop(context, OpeningEdit.save(e.toOpening(opening)));
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: 'Delete ${widget.label}?',
        message: 'This ${opening.type.label.toLowerCase()} is removed from the plan.');
    if (ok && mounted) Navigator.pop(context, const OpeningEdit.delete());
  }

  Future<bool> _confirmDiscard() async {
    if (!_changed) return true;
    return confirm(context,
        title: 'Discard changes?',
        message: 'The edited measurements will not be saved.');
  }

  // ---------------------------------------------------------------- drawing

  Widget _drawing() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final l = ElevationLayout(e, size);
        return GestureDetector(
          onPanStart: (d) {
            OpeningEdge? best;
            var bestD = 36.0;
            for (final edge in l.edges) {
              final dist = (l.handle(edge) - d.localPosition).distance;
              if (dist < bestD) {
                bestD = dist;
                best = edge;
              }
            }
            setState(() => _drag = best);
          },
          onPanUpdate: (d) {
            final edge = _drag;
            if (edge == null) return;
            final p = d.localPosition;
            final v = edge == OpeningEdge.left || edge == OpeningEdge.right
                ? l.toWallX(p.dx)
                : l.toWallY(p.dy);
            _set(e.withEdge(edge, _snap(v)));
          },
          onPanEnd: (_) => setState(() => _drag = null),
          child: CustomPaint(
            size: size,
            painter: ElevationPainter(
              e: e,
              unit: unit,
              editing: true,
              activeEdge: _drag,
            ),
          ),
        );
      }),
    );
  }

  Widget _field(String label, TextEditingController c, {String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focus(
        onFocusChange: (has) {
          if (!has) _applyField(c, null);
        },
        child: LengthField(
          controller: c,
          unit: unit,
          label: label,
          helper: helper,
          allowZero: c == _sill || c == _left,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = opening;
    final notes = [
      o.method.label,
      if (e.estimated) 'size estimated: check with a tape',
      if (e.heightAssumed) 'height not measured (typical shown)',
      if (e.sillAssumed) 'sill not measured (typical shown)',
      if (e.wallHeightAssumed) 'ceiling height not measured',
    ];
    final cs = theme.colorScheme;
    final accent = switch (o.type) {
      OpeningType.door => AppTheme.door,
      OpeningType.window => AppTheme.window,
      OpeningType.opening => cs.onSurfaceVariant,
    };
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusS),
              ),
              child: Icon(
                  switch (o.type) {
                    OpeningType.door => Icons.door_front_door_outlined,
                    OpeningType.window => Icons.window_outlined,
                    OpeningType.opening => Icons.crop_free_rounded,
                  },
                  size: 20,
                  color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label, overflow: TextOverflow.ellipsis),
                  Text(
                    '${o.type.label} on wall W${e.wallIndex + 1}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ]),
          actions: [
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              color: AppTheme.danger,
              onPressed: _delete,
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 760;
          final drawing = Padding(
            padding: EdgeInsets.fromLTRB(16, 4, wide ? 8 : 16, wide ? 16 : 4),
            child: _drawing(),
          );
          final form = ListView(
            padding: EdgeInsets.fromLTRB(wide ? 8 : 20, 12, 20, 24),
            children: [
              SegmentedButton<OpeningType>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: OpeningType.door, label: Text('Door')),
                  ButtonSegment(value: OpeningType.window, label: Text('Window')),
                  ButtonSegment(value: OpeningType.opening, label: Text('Gap')),
                ],
                selected: {o.type},
                onSelectionChanged: (s) => _setType(s.first),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.touch_app_outlined,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Drag the round handles on the drawing to move an edge, or '
                    'type the measurements.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ]),
              const SectionLabel('Size'),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('Width', _width)),
                const SizedBox(width: 12),
                Expanded(child: _field('Height', _height)),
              ]),
              if (e.isWindow)
                _field('Sill height', _sill, helper: 'From the floor to the bottom of the window'),
              const SectionLabel('Position'),
              _field('From the left corner', _left,
                  helper: 'Wall W${e.wallIndex + 1} is ${formatLength(e.wallLength, unit)} long'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: (e.estimated ? AppTheme.door : cs.onSurfaceVariant)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppTheme.radiusM),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        e.estimated
                            ? Icons.warning_amber_rounded
                            : Icons.info_outline_rounded,
                        size: 16,
                        color: e.estimated
                            ? AppTheme.door
                            : cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(notes.join('  ·  '),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: e.estimated
                                  ? AppTheme.door
                                  : cs.onSurfaceVariant)),
                    ),
                  ],
                ),
              ),
            ],
          );
          return wide
              ? Row(children: [
                  Expanded(child: drawing),
                  SizedBox(width: 380, child: form),
                ])
              : Column(children: [
                  Expanded(flex: 10, child: drawing),
                  Expanded(flex: 11, child: form),
                ]);
        }),
        bottomNavigationBar: Material(
          color: cs.surface,
          shape: Border(top: BorderSide(color: cs.outlineVariant)),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    // Apply a value still being typed.
                    FocusScope.of(context).unfocus();
                    WidgetsBinding.instance.addPostFrameCallback((_) => _save());
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Save'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
