import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/services/laser_meter.dart';

List<int> float32(double v) {
  final b = ByteData(4)..setFloat32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  const distance = '3ab10101-f831-4395-b29d-570977d5bf94';
  const distanceX = '3AB1010D-F831-4395-B29D-570977D5BF94';
  const unit = '3ab10102-f831-4395-b29d-570977d5bf94';

  test('a DISTO distance is a little-endian float in metres', () {
    expect(LaserMeter.parseDistance(distance, float32(3.217))!, closeTo(3.217, 1e-5));
    // X3 / X4 characteristic, any case, with extra bytes after the float.
    expect(LaserMeter.parseDistance(distanceX, [...float32(12.5), 0, 1])!, closeTo(12.5, 1e-5));
  });

  test('other characteristics and implausible values are ignored', () {
    expect(LaserMeter.parseDistance(unit, float32(3.2)), isNull);
    expect(LaserMeter.parseDistance(distance, [1, 2]), isNull);
    expect(LaserMeter.parseDistance(distance, float32(0)), isNull);
    expect(LaserMeter.parseDistance(distance, float32(double.nan)), isNull);
    expect(LaserMeter.parseDistance(distance, float32(5000)), isNull);
  });
}
