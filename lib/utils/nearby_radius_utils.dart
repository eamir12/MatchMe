int resolveNearbyRadiusMeters(
  int configuredRadiusMeters,
  Object? profileValue,
) {
  if (profileValue is num) {
    return profileValue.toInt();
  }
  return configuredRadiusMeters;
}

double nearbyRadiusKilometers(int radiusMeters) => radiusMeters / 1000.0;
