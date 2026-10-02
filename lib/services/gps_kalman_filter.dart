// lib/services/gps_kalman_filter.dart
import 'package:geolocator/geolocator.dart';

/// Kalman Filter for GPS coordinates.
/// Smooths noisy GPS readings and provides accurate position estimates.
///
/// The filter maintains:
/// - Position estimate (lat/lon)
/// - Velocity estimate (rate of change)
/// - Uncertainty/error covariance
///
/// It works in two steps:
/// 1. Prediction: Estimate where you should be based on last position + velocity
/// 2. Update: Adjust estimate based on new GPS measurement, weighted by confidence
class GPSKalmanFilter {
  // State estimates
  double _latitude = 0.0;
  double _longitude = 0.0;
  double _velocityLat = 0.0; // degrees per second
  double _velocityLon = 0.0; // degrees per second

  // Error covariance (uncertainty in our estimates)
  double _latitudeError = 10.0;
  double _longitudeError = 10.0;
  double _velocityLatError = 1.0;
  double _velocityLonError = 1.0;

  // Tracking
  DateTime? _lastUpdate;
  bool _isInitialized = false;
  int _measurementCount = 0;

  final double _processNoisePosition;
  final double _processNoiseVelocity;
  final double _minAccuracyMeters;
  final double _maxAccuracyMeters;

  GPSKalmanFilter({
    double processNoisePosition = 0.0001,
    double processNoiseVelocity = 0.001,
    double minAccuracyMeters = 5.0,
    double maxAccuracyMeters = 200.0,
  }) : _processNoisePosition = processNoisePosition,
       _processNoiseVelocity = processNoiseVelocity,
       _minAccuracyMeters = minAccuracyMeters,
       _maxAccuracyMeters = maxAccuracyMeters;

  /// Reset the filter to uninitialized state.
  void reset() {
    _isInitialized = false;
    _lastUpdate = null;
    _measurementCount = 0;
    _latitude = 0.0;
    _longitude = 0.0;
    _velocityLat = 0.0;
    _velocityLon = 0.0;
    _latitudeError = 10.0;
    _longitudeError = 10.0;
    _velocityLatError = 1.0;
    _velocityLonError = 1.0;
  }

  /// Whether the filter has been initialized with at least one measurement.
  bool get isInitialized => _isInitialized;

  /// Number of measurements processed.
  int get measurementCount => _measurementCount;

  /// Current filtered latitude estimate.
  double get latitude => _latitude;

  /// Current filtered longitude estimate.
  double get longitude => _longitude;

  /// Current velocity estimate in degrees per second (latitude).
  double get velocityLat => _velocityLat;

  /// Current velocity estimate in degrees per second (longitude).
  double get velocityLon => _velocityLon;

  /// Current position error estimate in degrees.
  double get positionError => (_latitudeError + _longitudeError) / 2;

  /// Current position error estimate in meters (approximate).
  double get positionErrorMeters => positionError * 111000.0;

  /// Process a new GPS measurement and return the filtered position.
  ///
  /// The filter will:
  /// 1. Initialize on first measurement
  /// 2. Predict current position based on time elapsed and velocity
  /// 3. Update estimate by fusing prediction with GPS measurement
  /// 4. Update velocity estimate
  ///
  /// Returns a new Position with filtered coordinates and improved accuracy.
  Position filter(Position measurement) {
    final now = measurement.timestamp;

    // Clamp accuracy to reasonable bounds
    final accuracy = measurement.accuracy.clamp(
      _minAccuracyMeters,
      _maxAccuracyMeters,
    );

    // Convert accuracy from meters to degrees (approximate at equator)
    // 1 degree latitude ≈ 111km, so 1 meter ≈ 1/111000 degrees
    final accuracyDegrees = accuracy / 111000.0;
    final measurementNoise = accuracyDegrees * accuracyDegrees; // Variance

    // Initialize on first measurement
    if (!_isInitialized) {
      _latitude = measurement.latitude;
      _longitude = measurement.longitude;
      _velocityLat = 0.0;
      _velocityLon = 0.0;
      _latitudeError = measurementNoise;
      _longitudeError = measurementNoise;
      _velocityLatError = 1.0;
      _velocityLonError = 1.0;
      _lastUpdate = now;
      _isInitialized = true;
      _measurementCount = 1;

      return _createFilteredPosition(measurement, accuracy);
    }

    // Calculate time delta
    final dt = now.difference(_lastUpdate!).inMilliseconds / 1000.0;
    _lastUpdate = now;

    // Clamp dt to reasonable bounds (0.1s to 120s)
    final dtClamped = dt.clamp(0.1, 120.0);

    // === PREDICTION STEP ===
    // Predict position based on velocity
    final predictedLat = _latitude + _velocityLat * dtClamped;
    final predictedLon = _longitude + _velocityLon * dtClamped;

    // Predict error growth due to process noise
    final predictedLatError =
        _latitudeError + _processNoisePosition * dtClamped;
    final predictedLonError =
        _longitudeError + _processNoisePosition * dtClamped;
    final predictedVelLatError =
        _velocityLatError + _processNoiseVelocity * dtClamped;
    final predictedVelLonError =
        _velocityLonError + _processNoiseVelocity * dtClamped;

    // === UPDATE STEP (Latitude) ===
    // Calculate Kalman gain: how much to trust measurement vs prediction
    final kalmanGainLat =
        predictedLatError / (predictedLatError + measurementNoise);

    // Update estimate: blend prediction with measurement
    final innovationLat = measurement.latitude - predictedLat;
    _latitude = predictedLat + kalmanGainLat * innovationLat;

    // Update error: reduce uncertainty after incorporating measurement
    _latitudeError = (1.0 - kalmanGainLat) * predictedLatError;

    // Update velocity estimate based on innovation
    final velocityGainLat =
        predictedVelLatError /
        (predictedVelLatError + measurementNoise / dtClamped);
    _velocityLat =
        _velocityLat +
        velocityGainLat * (innovationLat / dtClamped - _velocityLat);
    _velocityLatError = (1.0 - velocityGainLat) * predictedVelLatError;

    // === UPDATE STEP (Longitude) ===
    final kalmanGainLon =
        predictedLonError / (predictedLonError + measurementNoise);

    final innovationLon = measurement.longitude - predictedLon;
    _longitude = predictedLon + kalmanGainLon * innovationLon;

    _longitudeError = (1.0 - kalmanGainLon) * predictedLonError;

    final velocityGainLon =
        predictedVelLonError /
        (predictedVelLonError + measurementNoise / dtClamped);
    _velocityLon =
        _velocityLon +
        velocityGainLon * (innovationLon / dtClamped - _velocityLon);
    _velocityLonError = (1.0 - velocityGainLon) * predictedVelLonError;

    _measurementCount++;

    // Calculate improved accuracy estimate
    final filteredAccuracy = positionErrorMeters.clamp(
      _minAccuracyMeters,
      accuracy,
    );

    return _createFilteredPosition(measurement, filteredAccuracy);
  }

  /// Create a Position object with filtered coordinates.
  Position _createFilteredPosition(Position original, double filteredAccuracy) {
    return Position(
      latitude: _latitude,
      longitude: _longitude,
      timestamp: original.timestamp,
      accuracy: filteredAccuracy,
      altitude: original.altitude,
      altitudeAccuracy: original.altitudeAccuracy,
      heading: original.heading,
      headingAccuracy: original.headingAccuracy,
      speed: original.speed,
      speedAccuracy: original.speedAccuracy,
    );
  }

  /// Predict current position without a new measurement.
  /// Useful for estimating position between GPS updates.
  Position predict() {
    if (!_isInitialized) {
      throw StateError('Cannot predict before filter is initialized');
    }

    final now = DateTime.now();
    final dt = now.difference(_lastUpdate!).inMilliseconds / 1000.0;
    final dtClamped = dt.clamp(0.0, 120.0);

    final predictedLat = _latitude + _velocityLat * dtClamped;
    final predictedLon = _longitude + _velocityLon * dtClamped;

    // Error grows with time when predicting
    final predictedError = positionError + _processNoisePosition * dtClamped;
    final predictedErrorMeters = predictedError * 111000.0;

    return Position(
      latitude: predictedLat,
      longitude: predictedLon,
      timestamp: now,
      accuracy: predictedErrorMeters,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
  }
}
