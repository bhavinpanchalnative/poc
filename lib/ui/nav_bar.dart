import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// One page of the bottom dock.
class DockItem {
  const DockItem({required this.icon, required this.selectedIcon, required this.label});
  final IconData icon, selectedIcon;
  final String label;
}

/// The bottom navigation: a floating, frosted capsule with the pages on
/// either side of a raised scan button in the brand gradient. The selected
/// page is marked by a tinted pill that slides between items.
class PlanoraDock extends StatelessWidget {
  const PlanoraDock({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.onAction,
    required this.actionIcon,
    required this.actionLabel,
  }) : assert(items.length == 2);

  /// The two pages, left and right of the action.
  final List<DockItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  /// The centre button (start a scan).
  final VoidCallback? onAction;
  final IconData actionIcon;

  /// Spoken label and tooltip of the centre button.
  final String actionLabel;

  /// Height of the dock including its bottom margin, without the system's
  /// safe area: content behind it needs this much bottom padding.
  static const height = 64.0 + 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: SizedBox(
          height: 64,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            // The frosted capsule.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: (dark ? Colors.black : AppTheme.ink).withValues(alpha: dark ? 0.45 : 0.10),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surface.withValues(alpha: dark ? 0.78 : 0.86),
                        borderRadius: BorderRadius.circular(32),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: dark ? 0.9 : 0.8)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(children: [
              Expanded(child: _Tab(item: items[0], selected: selected == 0, onTap: () => onSelected(0))),
              // Room for the raised centre button.
              const SizedBox(width: 72),
              Expanded(child: _Tab(item: items[1], selected: selected == 1, onTap: () => onSelected(1))),
            ]),
            // The scan button, raised above the capsule.
            Positioned(
              top: -14,
              child: _ActionButton(icon: actionIcon, label: actionLabel, onTap: onAction),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.selected, required this.onTap});

  final DockItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!selected) HapticFeedback.selectionClick();
          onTap();
        },
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(horizontal: selected ? 16 : 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? cs.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Icon(selected ? item.selectedIcon : item.icon,
                    key: ValueKey(selected), size: 22, color: color),
              ),
              const SizedBox(width: 7),
              Text(item.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.label,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.label,
        excludeSemantics: true,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTap: enabled
              ? () {
                  HapticFeedback.mediumImpact();
                  widget.onTap!();
                }
              : null,
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: const Duration(milliseconds: 120),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppTheme.heroGradient,
                  // A ring in the page colour separates it from the dock.
                  border: Border.all(color: bg, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.brand.withValues(alpha: 0.30),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Icon(widget.icon, color: Colors.white, size: 26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
