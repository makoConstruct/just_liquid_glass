import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Low-pass filter turning raw accelerometer readings into a smoothed device
/// roll angle, in radians.
///
/// The gravity vector projected onto the screen plane tells us where "world
/// up" is relative to the device: with the sensor convention (x right,
/// y toward the top of the device, gravity included), holding the device
/// upright reads (0, +g) and rolling it clockwise by phi reads
/// g * (-sin phi, cos phi). So `tilt = atan2(-x, y) = phi`, and adding it to
/// a screen-space shine direction keeps the light anchored in world space.
///
/// Smoothing happens on the vector, not the angle, which avoids wrap-around
/// seams at +-pi. When the device lies nearly flat the planar component
/// shrinks below [minPlanarAcceleration] and the angle becomes noise, so the
/// last confident tilt is held instead.
class ShineTiltFilter {
  ShineTiltFilter({
    this.timeConstant = 0.15,
    this.minPlanarAcceleration = 0.8,
  });

  /// Exponential smoothing time constant, in seconds.
  final double timeConstant;

  /// Planar gravity magnitude (m/s^2) below which the tilt holds its last
  /// value rather than chasing noise from a face-up device.
  final double minPlanarAcceleration;

  double _x = 0;
  double _y = 0;
  double _tilt = 0;
  bool _primed = false;

  /// The current smoothed roll angle, in radians. 0 means upright.
  double get tilt => _tilt;

  /// Feeds one accelerometer sample (screen-plane components, m/s^2) taken
  /// [dtSeconds] after the previous one and returns the updated [tilt].
  double update(double x, double y, double dtSeconds) {
    if (_primed) {
      final a = 1 - math.exp(-dtSeconds.clamp(0.001, 0.5) / timeConstant);
      _x += (x - _x) * a;
      _y += (y - _y) * a;
    } else {
      // Snap to the first sample so the shine starts at the true angle
      // instead of swinging in from upright.
      _x = x;
      _y = y;
      _primed = true;
    }
    if (_x * _x + _y * _y >=
        minPlanarAcceleration * minPlanarAcceleration) {
      _tilt = math.atan2(-_x, _y);
    }
    return _tilt;
  }
}

/// Shared accelerometer listener driving motion-reactive shine.
///
/// All [GlassLayer]s with motion shine enabled retain the single instance,
/// which holds one sensor subscription and publishes the smoothed device
/// roll through [tilt]. The subscription is cancelled when the last layer
/// releases it or the app leaves the foreground, and never started at all on
/// platforms without an accelerometer — a sensor error latches [tilt] at its
/// current value, quietly leaving the shine static, in the same spirit as
/// glass mode downgrading to flat.
class ShineMotion with WidgetsBindingObserver {
  ShineMotion._();

  /// The process-wide instance.
  static final ShineMotion instance = ShineMotion._();

  /// Replaces the real sensor stream in tests. Set before the first
  /// [retain]; combine with [debugReset] between tests.
  @visibleForTesting
  static Stream<AccelerometerEvent>? debugEventStream;

  /// Smoothed device roll in radians, 0 while upright or unavailable.
  /// Added to [GlassOptions.shineDirection] at paint time.
  final ValueNotifier<double> tilt = ValueNotifier<double>(0);

  int _refCount = 0;
  StreamSubscription<AccelerometerEvent>? _subscription;
  ShineTiltFilter _filter = ShineTiltFilter();
  DateTime? _lastTimestamp;
  bool _failed = false;
  bool _observing = false;

  /// Whether the sensor subscription is currently live.
  @visibleForTesting
  bool get debugListening => _subscription != null;

  @visibleForTesting
  void debugReset() {
    _cancel();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _refCount = 0;
    _failed = false;
    _filter = ShineTiltFilter();
    tilt.value = 0;
  }

  /// Registers interest in tilt updates; the first retainer starts the
  /// sensor subscription. Balance with [release].
  void retain() {
    _refCount++;
    if (_refCount == 1) {
      // Tests may retain before a binding exists; motion then stays off.
      final binding = WidgetsBinding.instance;
      binding.addObserver(this);
      _observing = true;
      _listen();
    }
  }

  /// Releases one [retain]; the last release cancels the subscription.
  void release() {
    assert(_refCount > 0, 'ShineMotion.release without matching retain');
    _refCount--;
    if (_refCount == 0) {
      if (_observing) {
        WidgetsBinding.instance.removeObserver(this);
        _observing = false;
      }
      _cancel();
    }
  }

  void _listen() {
    if (_failed || _subscription != null || _refCount == 0) return;
    _filter = ShineTiltFilter();
    _lastTimestamp = null;
    try {
      final stream = debugEventStream ??
          accelerometerEventStream(
              samplingPeriod: SensorInterval.gameInterval);
      _subscription = stream.listen(
        _onEvent,
        // No accelerometer (desktop, some emulators, web without permission):
        // stay static forever rather than retrying.
        onError: (Object _) {
          _failed = true;
          _cancel();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _failed = true;
    }
  }

  void _cancel() {
    _subscription?.cancel();
    _subscription = null;
  }

  void _onEvent(AccelerometerEvent event) {
    final last = _lastTimestamp;
    _lastTimestamp = event.timestamp;
    var dt = last == null
        ? 0.02
        : event.timestamp.difference(last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.5) dt = 0.02;
    tilt.value = _filter.update(event.x, event.y, dt);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        _listen();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _cancel();
    }
  }
}
