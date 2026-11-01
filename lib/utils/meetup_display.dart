import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/providers/locale_provider.dart';

/// Built-in venue zones are stored as stable tokens so both devices can show
/// the zone in their own language. Custom zones are shown as entered.
String meetupZoneDisplay(String zone, LocalizationState l10n) {
  switch (zone.trim()) {
    case 'main_entrance':
      return l10n.getString('meetupEventZoneMainEntrance');
    case 'box_office':
      return l10n.getString('meetupEventZoneBoxOffice');
    case 'bar':
      return l10n.getString('meetupEventZoneBar');
    case 'cloakroom':
      return l10n.getString('meetupEventZoneCloakroom');
    case 'seating':
      return l10n.getString('meetupEventZoneSeating');
    default:
      return zone;
  }
}

String meetupGestureLabelKey(String gesture) {
  switch (gesture) {
    case kMeetupGestureHandsUp:
      return 'meetupGestureHandsUp';
    case kMeetupGestureJumping:
      return 'meetupGestureJumping';
    case kMeetupGestureArmsWide:
      return 'meetupGestureArmsWide';
    case kMeetupGestureWave:
    default:
      return 'meetupGestureWave';
  }
}

String meetupGestureDisplay(String gesture, LocalizationState l10n) =>
    l10n.getString(meetupGestureLabelKey(gesture));

String meetupOutfitColorLabelKey(String color) {
  switch (color) {
    case 'black':
      return 'meetupColorBlack';
    case 'white':
      return 'meetupColorWhite';
    case 'gray':
      return 'meetupColorGray';
    case 'beige':
      return 'meetupColorBeige';
    case 'brown':
      return 'meetupColorBrown';
    case 'navy':
      return 'meetupColorNavy';
    case 'blue':
      return 'meetupColorBlue';
    case 'light_blue':
      return 'meetupColorLightBlue';
    case 'green':
      return 'meetupColorGreen';
    case 'olive':
      return 'meetupColorOlive';
    case 'red':
      return 'meetupColorRed';
    case 'burgundy':
      return 'meetupColorBurgundy';
    case 'pink':
      return 'meetupColorPink';
    case 'yellow':
      return 'meetupColorYellow';
    case 'orange':
      return 'meetupColorOrange';
    case 'purple':
      return 'meetupColorPurple';
    case 'gold':
      return 'meetupColorGold';
    case 'silver':
      return 'meetupColorSilver';
    case 'multicolor':
      return 'meetupColorMulticolor';
    default:
      return '';
  }
}

/// Renders a stored color token in the reader's language. Cards created
/// before colors became tokens may hold free text; that text is shown as-is.
String meetupOutfitColorDisplay(String color, LocalizationState l10n) {
  final key = meetupOutfitColorLabelKey(color.trim());
  return key.isEmpty ? color : l10n.getString(key);
}
