/// Display units. All values are stored in metres; these only change how
/// they are shown and typed.
enum LengthUnit { meters, centimeters, feetInches, inches }

const _metresPerFoot = 0.3048;
const _metresPerInch = 0.0254;

extension LengthUnitInfo on LengthUnit {
  bool get isMetric =>
      this == LengthUnit.meters || this == LengthUnit.centimeters;

  /// Short label for unit pickers.
  String get label => switch (this) {
        LengthUnit.meters => 'm',
        LengthUnit.centimeters => 'cm',
        LengthUnit.feetInches => 'ft-in',
        LengthUnit.inches => 'in',
      };

  String get longLabel => switch (this) {
        LengthUnit.meters => 'Metres',
        LengthUnit.centimeters => 'Centimetres',
        LengthUnit.feetInches => 'Feet & inches',
        LengthUnit.inches => 'Inches',
      };

  /// Example of what the user can type, for input hints.
  String get inputHint => switch (this) {
        LengthUnit.meters => 'e.g. 3.45',
        LengthUnit.centimeters => 'e.g. 345',
        LengthUnit.feetInches => "e.g. 11' 4\" or 11.3",
        LengthUnit.inches => 'e.g. 136',
      };
}

String formatLength(double metres, LengthUnit unit) {
  switch (unit) {
    case LengthUnit.meters:
      return '${metres.toStringAsFixed(2)} m';
    case LengthUnit.centimeters:
      return '${(metres * 100).round()} cm';
    case LengthUnit.feetInches:
      final totalInches = (metres / _metresPerInch).round();
      final feet = totalInches ~/ 12, inches = totalInches % 12;
      return "$feet' $inches\"";
    case LengthUnit.inches:
      return '${(metres / _metresPerInch).toStringAsFixed(1)} in';
  }
}

/// A length as the user would type it back (no unit suffix for metric).
String editableLength(double metres, LengthUnit unit) => switch (unit) {
      LengthUnit.meters => metres.toStringAsFixed(2),
      LengthUnit.centimeters => (metres * 100).round().toString(),
      LengthUnit.feetInches => formatLength(metres, unit),
      LengthUnit.inches => (metres / _metresPerInch).toStringAsFixed(1),
    };

/// Areas: m² for metric units, ft² for imperial ones.
String formatArea(double squareMetres, LengthUnit unit) {
  if (unit.isMetric) return '${squareMetres.toStringAsFixed(2)} m²';
  final sqft = squareMetres / (_metresPerFoot * _metresPerFoot);
  return '${sqft.toStringAsFixed(1)} ft²';
}

/// Volumes: m³ for metric units, ft³ for imperial ones.
String formatVolume(double cubicMetres, LengthUnit unit) {
  if (unit.isMetric) return '${cubicMetres.toStringAsFixed(2)} m³';
  final cuft = cubicMetres / (_metresPerFoot * _metresPerFoot * _metresPerFoot);
  return '${cuft.toStringAsFixed(0)} ft³';
}

/// Parses a length the user typed, in the given unit. Returns metres.
/// Feet & inches accepts `12.5`, `12' 6"`, `12'6`, `12 6` or `12ft 6in`.
/// Any unit also accepts an explicit suffix: `3.2 m`, `320 cm`, `126 in`.
double? parseLength(String input, LengthUnit unit) {
  // Typographic quotes and primes (iOS turns ' and " into ’ and ” as you
  // type) mean feet and inches too.
  final s = input
      .trim()
      .replaceAll(',', '.')
      .replaceAll(RegExp('[‘’′]'), "'")
      .replaceAll(RegExp('[“”″]'), '"')
      .toLowerCase();
  if (s.isEmpty) return null;

  double? positive(double? v) => (v == null || v <= 0 || v.isNaN) ? null : v;

  // Explicit suffixes win over the selected unit.
  final suffixed = RegExp(r'^(\d+(?:\.\d+)?)\s*(mm|cm|m|in|")$').firstMatch(s);
  if (suffixed != null) {
    final v = double.parse(suffixed.group(1)!);
    return positive(switch (suffixed.group(2)) {
      'mm' => v / 1000,
      'cm' => v / 100,
      'm' => v,
      _ => v * _metresPerInch,
    });
  }

  switch (unit) {
    case LengthUnit.meters:
      return positive(double.tryParse(s));
    case LengthUnit.centimeters:
      final v = double.tryParse(s);
      return positive(v == null ? null : v / 100);
    case LengthUnit.inches:
      final v = double.tryParse(s);
      return positive(v == null ? null : v * _metresPerInch);
    case LengthUnit.feetInches:
      final m = RegExp(
              r"^(\d+(?:\.\d+)?)\s*(?:'|ft)?\s*(?:(\d+(?:\.\d+)?)\s*(?:\x22|in)?)?$")
          .firstMatch(s);
      if (m == null) return null;
      final feet = double.parse(m.group(1)!);
      final inches = m.group(2) != null ? double.parse(m.group(2)!) : 0.0;
      return positive((feet + inches / 12) * _metresPerFoot);
  }
}
