import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The kinds of saved measurements, one History tab each.
enum HistoryKind { room, door, window, line, surface, map }

extension HistoryKindStyle on HistoryKind {
  String get tab => switch (this) {
        HistoryKind.room => 'Rooms',
        HistoryKind.door => 'Doors',
        HistoryKind.window => 'Windows',
        HistoryKind.line => 'Lines',
        HistoryKind.surface => 'Surfaces',
        HistoryKind.map => 'Floor maps',
      };

  String get single => switch (this) {
        HistoryKind.room => 'Room',
        HistoryKind.door => 'Door',
        HistoryKind.window => 'Window',
        HistoryKind.line => 'Line',
        HistoryKind.surface => 'Surface',
        HistoryKind.map => 'Floor map',
      };

  IconData get icon => switch (this) {
        HistoryKind.room => Icons.space_dashboard_outlined,
        HistoryKind.door => Icons.door_front_door_outlined,
        HistoryKind.window => Icons.window_outlined,
        HistoryKind.line => Icons.open_in_full_rounded,
        HistoryKind.surface => Icons.texture_rounded,
        HistoryKind.map => Icons.map_outlined,
      };

  Color get color => switch (this) {
        HistoryKind.room => AppTheme.brand,
        HistoryKind.door => AppTheme.door,
        HistoryKind.window => AppTheme.window,
        HistoryKind.line => AppTheme.lineMark,
        HistoryKind.surface => AppTheme.surfaceMark,
        HistoryKind.map => AppTheme.scan,
      };
}

/// One saved measurement in the History list.
class HistoryItem {
  const HistoryItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.date,
    required this.onTap,
    this.value,
    this.estimated = false,
    this.thumbnail,
    this.menu = const [],
  });

  final HistoryKind kind;
  final String title;

  /// Secondary line: where it is (its room) or what it is.
  final String subtitle;

  /// The headline measurement (area, width × height, length …).
  final String? value;

  /// The value is approximate: shown with "≈" in amber.
  final bool estimated;
  final DateTime date;

  /// Opens it: its plan, its 2D drawing or its list.
  final VoidCallback onTap;

  /// A drawing (plan outline) instead of the kind's icon.
  final CustomPainter? thumbnail;

  /// Extra actions (label, icon, action), e.g. rename and delete.
  final List<(String, IconData, VoidCallback)> menu;
}

/// What an empty tab offers instead of a list.
class HistoryEmptyAction {
  const HistoryEmptyAction(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

/// Saved measurements by category: All, Rooms, Doors, Windows, Lines,
/// Surfaces and Floor maps, each a tab with its count, so any measurement
/// and its 2D drawing is one tap away.
class HistoryView extends StatefulWidget {
  const HistoryView({
    super.key,
    required this.items,
    required this.loading,
    required this.emptyActions,
    this.header,
  });

  final List<HistoryItem> items;
  final bool loading;

  /// The action an empty tab offers, per kind.
  final Map<HistoryKind, HistoryEmptyAction> emptyActions;

  /// Shown above the list in a tab (e.g. "New map" on Floor maps).
  final Widget? Function(HistoryKind? kind)? header;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> with SingleTickerProviderStateMixin {
  // null = All.
  static const _tabs = <HistoryKind?>[null, ...HistoryKind.values];
  late final TabController _controller = TabController(length: _tabs.length, vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<HistoryItem> _of(HistoryKind? k) {
    final list = k == null ? List.of(widget.items) : widget.items.where((i) => i.kind == k).toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TabBar(
          controller: _controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          dividerColor: Colors.transparent,
          indicator: const BoxDecoration(),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          tabs: [
            for (final (i, k) in _tabs.indexed)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final on = _controller.index == i;
                  final n = _of(k).length;
                  return Tab(
                    height: 44,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: on ? cs.onSurface : cs.surface,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: on ? cs.onSurface : cs.outlineVariant),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(k?.tab ?? 'All',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: on ? cs.surface : cs.onSurface)),
                        if (n > 0) ...[
                          const SizedBox(width: 6),
                          Text('$n',
                              style: theme.textTheme.labelMedium?.copyWith(
                                  color: on ? cs.surface.withValues(alpha: 0.7) : cs.onSurfaceVariant,
                                  fontFeatures: AppTheme.tabular)),
                        ],
                      ]),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: widget.loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _controller,
                children: [for (final k in _tabs) _list(context, k)],
              ),
      ),
    ]);
  }

  Widget _list(BuildContext context, HistoryKind? k) {
    final items = _of(k);
    final header = widget.header?.call(k);
    if (items.isEmpty) {
      return ListView(padding: EdgeInsets.fromLTRB(20, 12, 20, _bottom(context)), children: [
        ?header,
        _Empty(kind: k, action: k == null ? null : widget.emptyActions[k]),
      ]);
    }
    final children = <Widget>[?header];
    String? group;
    for (final item in items) {
      // The All tab is grouped by when things were measured.
      if (k == null) {
        final g = _group(item.date);
        if (g != group) {
          group = g;
          children.add(_GroupLabel(g));
        }
      }
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: HistoryTile(item: item, showKind: k == null),
      ));
    }
    return ListView(padding: EdgeInsets.fromLTRB(20, 8, 20, _bottom(context)), children: children);
  }

  /// Bottom padding: clear of a floating bar the page extends under (the
  /// Scaffold reports it in the media padding).
  double _bottom(BuildContext context) => MediaQuery.paddingOf(context).bottom + 24;


  static String _group(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return 'This week';
    return 'Earlier';
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.0)),
    );
  }
}

/// One saved measurement: its drawing or icon, name, where it is, and its
/// headline value. Tapping opens it.
class HistoryTile extends StatelessWidget {
  const HistoryTile({super.key, required this.item, this.showKind = false});

  final HistoryItem item;

  /// Name the kind too (in the All tab, where kinds are mixed).
  final bool showKind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final k = item.kind;
    final c = k.color;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppTheme.radiusM),
              ),
              child: item.thumbnail != null
                  ? CustomPaint(painter: item.thumbnail)
                  : Icon(k.icon, color: c, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Name and measurement on one line, so the line below can
                // use the full width for where it is.
                Row(children: [
                  Expanded(
                    child: Text(item.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  ),
                  if (item.value != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${item.estimated ? '≈ ' : ''}${item.value}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: AppTheme.tabular,
                        color: item.estimated ? AppTheme.door : cs.onSurface,
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 4),
                Text(
                  showKind ? '${k.single}  ·  ${item.subtitle}' : item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ),
            if (item.menu.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: 'More',
                icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant, size: 20),
                onSelected: (i) => item.menu[i].$3(),
                itemBuilder: (_) => [
                  for (final (i, m) in item.menu.indexed)
                    PopupMenuItem(value: i, child: ListTile(leading: Icon(m.$2), title: Text(m.$1))),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 6),
                child: Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.kind, this.action});
  final HistoryKind? kind;
  final HistoryEmptyAction? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final k = kind;
    final text = switch (k) {
      null => 'Rooms, doors, windows and distances you measure appear here.',
      HistoryKind.room => 'Scanned and entered rooms appear here, with their floor plans.',
      HistoryKind.door => 'Doors you measure appear here, with their 2D drawings.',
      HistoryKind.window => 'Windows you measure appear here, with their 2D drawings.',
      HistoryKind.line => 'Distances between two points appear here.',
      HistoryKind.surface => 'Wall sections, worktops and floor areas measured in a scan appear here.',
      HistoryKind.map => 'Put rooms together into a map of a whole flat or floor.',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: (k?.color ?? AppTheme.brand).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppTheme.radiusL),
          ),
          child: Icon(k?.icon ?? Icons.history_rounded, color: k?.color ?? AppTheme.brand, size: 30),
        ),
        const SizedBox(height: 16),
        Text(k == null ? 'Nothing measured yet' : 'No ${k.tab.toLowerCase()} yet',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ),
        if (action != null) ...[
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: action!.onTap,
            icon: Icon(action!.icon, size: 18),
            label: Text(action!.label),
          ),
        ],
      ]),
    );
  }
}
