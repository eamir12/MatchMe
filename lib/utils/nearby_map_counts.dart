/// A grid cell of the nearby map.
///
/// The map never receives individual user positions: the server buckets the
/// users in range into cells and returns the number of users per cell.
class NearbyMapCell {
  final double lat;
  final double lng;
  final int count;

  const NearbyMapCell({
    required this.lat,
    required this.lng,
    required this.count,
  });
}

/// The number of users plotted on the nearby map.
///
/// The map draws one marker per cell and each cell carries the number of
/// users inside it, so the sum of the cell counts is exactly the number of
/// users shown on the map.
///
/// The "Showing ~N users" pill must use this value. It used to be taken
/// from a second, independently anchored query
/// (`get_nearby_users_count`, which centres on the server's own copy of the
/// user's position) while the markers came from
/// `get_visible_online_user_map_cells` (centred on the device's position).
/// When the two anchors disagreed the pill read 0 while a real user was
/// plotted right next to the "You" marker.
int nearbyUsersPlottedOnMap(Iterable<NearbyMapCell> cells) =>
    cells.fold<int>(0, (sum, cell) => sum + cell.count);
