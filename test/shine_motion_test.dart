import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/src/shine_motion.dart';
import 'package:sensors_plus/sensors_plus.dart';

const g = 9.81;

/// Accelerometer reading for a device rolled clockwise by [phi] radians
/// (natural portrait orientation, gravity included): g * (-sin phi, cos phi).
AccelerometerEvent rolled(double phi, {DateTime? at}) => AccelerometerEvent(
    -g * math.sin(phi), g * math.cos(phi), 0, at ?? DateTime(2026));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShineTiltFilter', () {
    test('upright device reads zero tilt', () {
      final filter = ShineTiltFilter();
      expect(filter.update(0, g, 0.02), 0);
    });

    test('first sample primes without smoothing lag', () {
      final filter = ShineTiltFilter();
      expect(filter.update(-g * math.sin(0.5), g * math.cos(0.5), 0.02),
          closeTo(0.5, 1e-9));
    });

    test('clockwise roll yields positive tilt of the same angle', () {
      for (final phi in [-2.5, -1.0, -0.3, 0.3, 1.0, 2.5]) {
        final filter = ShineTiltFilter();
        expect(filter.update(-g * math.sin(phi), g * math.cos(phi), 0.02),
            closeTo(phi, 1e-9),
            reason: 'phi = $phi');
      }
    });

    test('smoothing converges toward a step input without overshoot', () {
      final filter = ShineTiltFilter();
      filter.update(0, g, 0.02); // prime upright
      final after1 = filter.update(-g * math.sin(1.0), g * math.cos(1.0), 0.02);
      expect(after1, greaterThan(0));
      expect(after1, lessThan(0.5)); // one 20ms step of a 150ms time constant
      var tilt = after1;
      for (var i = 0; i < 100; i++) {
        tilt = filter.update(-g * math.sin(1.0), g * math.cos(1.0), 0.02);
      }
      expect(tilt, closeTo(1.0, 1e-3));
    });

    test('near-flat device holds the last confident tilt', () {
      final filter = ShineTiltFilter();
      filter.update(-g * math.sin(0.7), g * math.cos(0.7), 0.02);
      // Face-up: gravity leaves the screen plane; planar noise only. The
      // noise skews the angle slightly while the smoothed vector decays
      // through the confidence threshold, hence the loose tolerance.
      for (var i = 0; i < 200; i++) {
        filter.update(0.01, -0.02, 0.02);
      }
      expect(filter.tilt, closeTo(0.7, 0.05));
    });
  });

  group('ShineMotion', () {
    late StreamController<AccelerometerEvent> events;
    var listens = 0;

    setUp(() {
      listens = 0;
      events = StreamController<AccelerometerEvent>.broadcast(
          sync: true, onListen: () => listens++);
      ShineMotion.debugEventStream = events.stream;
      ShineMotion.instance.debugReset();
    });

    tearDown(() {
      ShineMotion.instance.debugReset();
      ShineMotion.debugEventStream = null;
      events.close();
    });

    test('retain subscribes once and events drive the tilt notifier', () {
      final motion = ShineMotion.instance;
      motion.retain();
      motion.retain();
      expect(listens, 1);
      expect(motion.debugListening, isTrue);

      events.add(rolled(0.4));
      expect(motion.tilt.value, closeTo(0.4, 1e-9));

      motion.release();
      expect(motion.debugListening, isTrue);
      motion.release();
      expect(motion.debugListening, isFalse);
    });

    test('sensor error latches static instead of crashing or retrying', () {
      final motion = ShineMotion.instance;
      motion.retain();
      events.add(rolled(0.4));
      events.addError(StateError('no accelerometer'));
      expect(motion.debugListening, isFalse);
      expect(motion.tilt.value, closeTo(0.4, 1e-9));

      // A later retain must not resubscribe after a hard failure.
      motion.release();
      motion.retain();
      expect(listens, 1);
      expect(motion.debugListening, isFalse);
      motion.release();
    });
  });
}
