import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../engine/elevation.dart';
import '../engine/floor_map.dart';
import '../engine/floor_plan_builder.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../ui/app_theme.dart';
import '../ui/brand.dart';
import '../ui/elevation_painter.dart';
import '../ui/floor_map_painter.dart';
import '../ui/plan_painter.dart';
import 'scan_store.dart';

/// Renders a plan off-screen and writes it as PNG or PDF.
class PlanExporter {
  static Future<Uint8List> renderPng(
    FloorPlan plan,
    LengthUnit unit, {
    String? title,
    Size size = const Size(1600, 1200),
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    PlanPainter(plan: plan, unit: unit, title: title).paint(canvas, size);
    final image = await recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// The front view of one door or window, with all its dimensions.
  static Future<Uint8List> renderElevationPng(
    OpeningElevation e,
    LengthUnit unit, {
    String? title,
    Size size = const Size(1000, 720),
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    ElevationPainter(e: e, unit: unit, title: title).paint(canvas, size);
    final image = await recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// "Door 1", "Window 2": numbered per type, in plan order.
  static List<String> openingLabels(List<Opening> openings) {
    final count = <OpeningType, int>{};
    return [
      for (final o in openings)
        '${o.type.label} ${count[o.type] = (count[o.type] ?? 0) + 1}',
    ];
  }

  // ---------------------------------------------------------------- brand

  static pw.ThemeData? _theme;
  static Uint8List? _logo;

  /// Inter for the PDF text, as in the app (and it has ≈, × and ²).
  /// Falls back to the PDF's built-in font if the files can't be read.
  static Future<pw.ThemeData> _pdfTheme() async {
    if (_theme != null) return _theme!;
    try {
      final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-Regular.ttf'));
      final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-Bold.ttf'));
      _theme = pw.ThemeData.withFont(base: regular, bold: bold);
    } catch (_) {
      _theme = pw.ThemeData();
    }
    return _theme!;
  }

  static Future<Uint8List> _logoPng() async {
    if (_logo != null) return _logo!;
    const px = 96;
    final recorder = ui.PictureRecorder();
    const PlanoraMarkPainter().paint(Canvas(recorder), const Size(96, 96));
    final image = await recorder.endRecording().toImage(px, px);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return _logo = bytes!.buffer.asUint8List();
  }

  static final _ink = PdfColor.fromInt(AppTheme.ink.toARGB32());
  static final _brand = PdfColor.fromInt(AppTheme.brand.toARGB32());
  static const _muted = PdfColor.fromInt(0xFF66708A);
  static const _hairline = PdfColor.fromInt(0xFFE3E7EF);

  /// Logo and name at the top of every page, the document title on the
  /// right.
  static pw.Widget _header(pw.Context ctx, Uint8List logo, String title) => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 14),
        padding: const pw.EdgeInsets.only(bottom: 10),
        decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _hairline, width: 1))),
        child: pw.Row(children: [
          pw.Image(pw.MemoryImage(logo), width: 18, height: 18),
          pw.SizedBox(width: 6),
          pw.Text(AppTheme.appName,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.Spacer(),
          pw.Text(title, style: const pw.TextStyle(fontSize: 9, color: _muted)),
        ]),
      );

  static pw.Widget _footer(pw.Context ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 12),
        child: pw.Row(children: [
          pw.Text('${AppTheme.appName} · ${AppTheme.tagline}',
              style: const pw.TextStyle(fontSize: 8, color: _muted)),
          pw.Spacer(),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: _muted)),
        ]),
      );

  /// A one-page PDF with one drawing (e.g. a door's front view), branded
  /// like the other exports.
  static Future<Uint8List> imagePdf(Uint8List png, String title) async {
    final doc = pw.Document(title: title);
    final theme = await _pdfTheme();
    final logo = await _logoPng();
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      theme: theme,
      build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        _header(ctx, logo, title),
        pw.Text(title,
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 14),
        pw.Image(pw.MemoryImage(png)),
      ]),
    ));
    return doc.save();
  }

  static String safeName(String s) {
    final n =
        s.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim().replaceAll(' ', '_');
    return n.isEmpty ? 'room' : n;
  }

  static Future<File> savePng(
      RoomScan scan, FloorPlan plan, LengthUnit unit) async {
    final png = await renderPng(plan, unit, title: scan.name);
    final dir = await ScanStore.exportsDir();
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${safeName(scan.name)}_${scan.id}.png');
    await f.writeAsBytes(png);
    return f;
  }

  /// Summary rows shared by the PDF and the app.
  static List<(String, String)> summary(FloorPlan plan, LengthUnit unit) {
    final size = plan.overallSize;
    return [
      ('Floor area', formatArea(plan.area, unit)),
      ('Perimeter', formatLength(plan.perimeter, unit)),
      (
        'Overall size',
        '${formatLength(size.width, unit)} × ${formatLength(size.depth, unit)}'
      ),
      if (plan.height != null)
        ('Ceiling height', formatLength(plan.height!, unit)),
      if (plan.volume != null) ('Volume', formatVolume(plan.volume!, unit)),
      if (plan.netWallArea != null)
        ('Wall area (net)', formatArea(plan.netWallArea!, unit)),
      ('Walls', '${plan.wallCount}'),
    ];
  }

  static Future<Uint8List> buildPdf(
      RoomScan scan, FloorPlan plan, LengthUnit unit) async {
    final png = await renderPng(plan, unit);
    final labels = openingLabels(plan.openings);
    final fronts = <Uint8List>[
      for (var k = 0; k < plan.openings.length; k++)
        if (plan.openings[k].wallIndex < plan.wallCount)
          await renderElevationPng(
              OpeningElevation.of(plan, plan.openings[k]), unit,
              title: '${labels[k]} · wall W${plan.openings[k].wallIndex + 1}'),
    ];
    final doc = pw.Document(title: scan.name);
    final theme = await _pdfTheme();
    final logo = await _logoPng();
    final docTitle = scan.name;
    final bold = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);
    const cell = pw.TextStyle(fontSize: 10);
    // Section headings with a short brand-blue bar, as in the app.
    pw.Widget heading(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 18, bottom: 8),
          child: pw.Row(children: [
            pw.Container(width: 3, height: 13, color: _brand),
            pw.SizedBox(width: 6),
            pw.Text(t,
                style: pw.TextStyle(
                    fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
          ]),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      theme: theme,
      header: (ctx) => _header(ctx, logo, docTitle),
      footer: _footer,
      build: (_) => [
        pw.Text(scan.name,
            style: pw.TextStyle(
                fontSize: 22, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 4),
        pw.Text(
            '${scan.source.label} · ${scan.createdAt.toLocal().toString().substring(0, 16)}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.Image(pw.MemoryImage(png)),
        heading('Summary'),
        pw.TableHelper.fromTextArray(
          data: [
            for (final (k, v) in summary(plan, unit)) [k, v],
          ],
          cellStyle: cell,
          border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _hairline, width: 0.5),
              top: pw.BorderSide(color: _hairline, width: 0.5),
              bottom: pw.BorderSide(color: _hairline, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDF1FF)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
        heading('Walls'),
        pw.TableHelper.fromTextArray(
          headers: ['Wall', 'Length', 'Corner angle'],
          data: [
            for (var i = 0; i < plan.wallCount; i++)
              [
                'W${i + 1}',
                formatLength(plan.wallLength(i), unit),
                '${plan.interiorAngleDeg(i).toStringAsFixed(0)}°',
              ],
          ],
          cellStyle: cell,
          headerStyle: bold,
          border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _hairline, width: 0.5),
              top: pw.BorderSide(color: _hairline, width: 0.5),
              bottom: pw.BorderSide(color: _hairline, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDF1FF)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
        if (plan.openings.isNotEmpty) ...[
          heading('Doors and windows'),
          pw.TableHelper.fromTextArray(
            headers: ['', 'Wall', 'Width', 'Height', 'Sill', 'Measured'],
            data: [
              for (var k = 0; k < plan.openings.length; k++)
                () {
                  final o = plan.openings[k];
                  // The PDF's built-in font has no ≈.
                  final approx = o.estimated ? '~ ' : '';
                  return [
                    labels[k],
                    'W${o.wallIndex + 1}',
                    '$approx${formatLength(o.width, unit)}',
                    o.height != null ? '$approx${formatLength(o.height!, unit)}' : '-',
                    o.sill != null ? formatLength(o.sill!, unit) : '-',
                    switch (o.method) {
                      OpeningMethod.auto => 'detected',
                      OpeningMethod.touch => 'touch',
                      OpeningMethod.manual => 'marked',
                      OpeningMethod.typed => 'typed',
                    },
                  ];
                }(),
            ],
            cellStyle: cell,
            headerStyle: bold,
            border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _hairline, width: 0.5),
              top: pw.BorderSide(color: _hairline, width: 0.5),
              bottom: pw.BorderSide(color: _hairline, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDF1FF)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          ),
        ],
        if (fronts.isNotEmpty) ...[
          heading('Doors and windows: front views'),
          pw.Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final f in fronts)
                pw.Container(
                  width: (PdfPageFormat.a4.width - 64 - 10) / 2,
                  decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey300, width: 0.5)),
                  child: pw.Image(pw.MemoryImage(f)),
                ),
            ],
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
                'Values marked ~ are estimates; grey values in the drawings were not measured.',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          ),
        ],
        if (plan.surfaces.isNotEmpty) ...[
          heading('Measured surfaces'),
          pw.TableHelper.fromTextArray(
            headers: ['Name', 'Type', 'Size', 'Area', 'Above floor'],
            data: [
              for (final m in plan.surfaces)
                [
                  m.name,
                  m.kind.label,
                  '${formatLength(m.width, unit)} × ${formatLength(m.height, unit)}',
                  formatArea(m.area, unit),
                  m.elevation != null ? formatLength(m.elevation!, unit) : '-',
                ],
            ],
            cellStyle: cell,
            headerStyle: bold,
            border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _hairline, width: 0.5),
              top: pw.BorderSide(color: _hairline, width: 0.5),
              bottom: pw.BorderSide(color: _hairline, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDF1FF)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          ),
        ],
      ],
    ));
    return doc.save();
  }

  static Future<File> savePdf(
      RoomScan scan, FloorPlan plan, LengthUnit unit) async {
    final bytes = await buildPdf(scan, plan, unit);
    final dir = await ScanStore.exportsDir();
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${safeName(scan.name)}_${scan.id}.pdf');
    await f.writeAsBytes(bytes);
    return f;
  }

  // ---------------------------------------------------------------- maps

  static Future<Uint8List> renderMapPng(
    List<PlacedRoom> rooms,
    LengthUnit unit, {
    String? title,
    Size size = const Size(1800, 1300),
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    FloorMapPainter(rooms: rooms, unit: unit, title: title).paint(canvas, size);
    final image = await recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  static Future<File> saveMapPng(
      FloorMap map, List<PlacedRoom> rooms, LengthUnit unit) async {
    final png = await renderMapPng(rooms, unit, title: map.name);
    final dir = await ScanStore.exportsDir();
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${safeName(map.name)}_${map.id}.png');
    await f.writeAsBytes(png);
    return f;
  }

  static Future<Uint8List> buildMapPdf(
      FloorMap map, List<PlacedRoom> rooms, LengthUnit unit) async {
    final png = await renderMapPng(rooms, unit);
    final doc = pw.Document(title: map.name);
    final theme = await _pdfTheme();
    final logo = await _logoPng();
    final docTitle = map.name;
    final bold = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);
    const cell = pw.TextStyle(fontSize: 10);
    int count(PlacedRoom r, OpeningType t) =>
        r.plan.openings.where((o) => o.type == t).length;
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      theme: theme,
      header: (ctx) => _header(ctx, logo, docTitle),
      footer: _footer,
      build: (_) => [
        pw.Text(map.name,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(
            '${rooms.length} rooms · total floor area ${formatArea(totalArea(rooms), unit)}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.Image(pw.MemoryImage(png)),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: ['Room', 'Area', 'Size', 'Height', 'Doors', 'Windows'],
          data: [
            for (final r in rooms)
              [
                r.scan.name,
                formatArea(r.plan.area, unit),
                '${formatLength(r.plan.overallSize.width, unit)} × '
                    '${formatLength(r.plan.overallSize.depth, unit)}',
                r.plan.height != null ? formatLength(r.plan.height!, unit) : '-',
                '${count(r, OpeningType.door)}',
                '${count(r, OpeningType.window)}',
              ],
            ['Total', formatArea(totalArea(rooms), unit), '', '', '', ''],
          ],
          cellStyle: cell,
          headerStyle: bold,
          border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(color: _hairline, width: 0.5),
              top: pw.BorderSide(color: _hairline, width: 0.5),
              bottom: pw.BorderSide(color: _hairline, width: 0.5)),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDF1FF)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
      ],
    ));
    return doc.save();
  }

  static Future<File> saveMapPdf(
      FloorMap map, List<PlacedRoom> rooms, LengthUnit unit) async {
    final bytes = await buildMapPdf(map, rooms, unit);
    final dir = await ScanStore.exportsDir();
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${safeName(map.name)}_${map.id}.pdf');
    await f.writeAsBytes(bytes);
    return f;
  }
}
