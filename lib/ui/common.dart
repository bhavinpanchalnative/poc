import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../engine/units.dart';
import '../services/app_settings.dart';

/// Asks for a line of text. Returns null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String confirm = 'Save',
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text), child: Text(confirm)),
      ],
    ),
  );
}

/// A text field for a length in [unit] that validates as you type.
///
/// On iOS the number keyboard has no Done or Return key, so while the field
/// is focused a bar with a Done button sits on top of the keyboard.
class LengthField extends StatefulWidget {
  const LengthField({
    super.key,
    required this.controller,
    required this.unit,
    required this.label,
    this.helper,
    this.optional = false,
    this.allowZero = false,
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final LengthUnit unit;
  final String label;
  final String? helper;
  final bool optional;
  final bool allowZero;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  static bool isZero(String v) =>
      RegExp(r'''^0+([.,]0*)?\s*('|"|m|cm|in|ft)?$''').hasMatch(v.trim());

  /// Null when valid.
  static String? validate(String v, LengthUnit unit,
      {bool optional = false, bool allowZero = false}) {
    if (v.trim().isEmpty) return optional ? null : 'Required';
    if (allowZero && isZero(v)) return null;
    return parseLength(v, unit) == null ? 'Not a valid length' : null;
  }

  @override
  State<LengthField> createState() => _LengthFieldState();
}

class _LengthFieldState extends State<LengthField> {
  final _focus = FocusNode();
  OverlayEntry? _doneBar;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_focus.hasFocus) {
      _showDoneBar();
    } else {
      _hideDoneBar();
    }
  }

  void _showDoneBar() {
    if (_doneBar != null) return;
    _doneBar = OverlayEntry(
        builder: (_) => _KeyboardDoneBar(onDone: _focus.unfocus));
    Overlay.of(context, rootOverlay: true).insert(_doneBar!);
  }

  void _hideDoneBar() {
    _doneBar?.remove();
    _doneBar = null;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _hideDoneBar();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;
    return TextFormField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      keyboardType: unit == LengthUnit.feetInches
          ? TextInputType.text
          : const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: unit.inputHint,
        helperText: widget.helper,
        helperMaxLines: 3,
        suffixText: unit == LengthUnit.feetInches ? null : unit.label,
      ),
      validator: (v) => LengthField.validate(v ?? '', unit,
          optional: widget.optional, allowZero: widget.allowZero),
      onChanged: widget.onChanged,
    );
  }
}

/// A Done bar on top of the iOS keyboard; hidden while no keyboard shows.
class _KeyboardDoneBar extends StatelessWidget {
  const _KeyboardDoneBar({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboard == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: keyboard,
      child: Material(
        color: cs.surfaceContainerHigh,
        shape: Border(top: BorderSide(color: cs.outlineVariant)),
        child: SizedBox(
          height: 44,
          child: Row(children: [
            const Spacer(),
            TextButton(
              onPressed: onDone,
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}

/// Asks for one length. Returns metres, or `double.nan` when [optional]
/// and left empty; null when cancelled.
Future<double?> askLength(
  BuildContext context, {
  required String title,
  required LengthUnit unit,
  double? initial,
  String label = 'Length',
  String? helper,
  bool optional = false,
}) {
  final c = TextEditingController(
      text: initial == null ? '' : editableLength(initial, unit));
  final formKey = GlobalKey<FormState>();
  return showDialog<double>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (!formKey.currentState!.validate()) return;
        final v = c.text.trim();
        Navigator.pop(ctx, v.isEmpty ? double.nan : parseLength(v, unit));
      }

      return AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: LengthField(
            controller: c,
            unit: unit,
            label: label,
            helper: helper,
            optional: optional,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    },
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Delete',
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void showMessage(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// App-bar button that switches the display unit everywhere.
class UnitButton extends StatelessWidget {
  const UnitButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, unit, _) => PopupMenuButton<LengthUnit>(
        tooltip: 'Measurement unit',
        initialValue: unit,
        onSelected: AppSettings.setUnit,
        itemBuilder: (_) => [
          for (final u in LengthUnit.values)
            CheckedPopupMenuItem(
              value: u,
              checked: u == unit,
              child: Text(u.longLabel),
            ),
        ],
        child: Builder(builder: (context) {
          final theme = Theme.of(context);
          final cs = theme.colorScheme;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.straighten_rounded, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(unit.label,
                  style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurface)),
              Icon(Icons.expand_more_rounded, size: 16, color: cs.onSurfaceVariant),
            ]),
          );
        }),
      ),
    );
  }
}

/// A labelled value in a card, for the measurement summary.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.placeholder = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  /// Shows [value] as a muted call to action.
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 19, color: cs.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: placeholder ? cs.primary : cs.onSurface,
                        fontWeight:
                            placeholder ? FontWeight.w500 : FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.edit_outlined,
                  size: 16, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
          ]),
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 26, 2, 12),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        ),
        ?trailing,
      ]),
    );
  }
}
