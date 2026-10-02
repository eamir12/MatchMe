/// restcountries.com v3.1 API has been deprecated and replaced with v5 which
/// requires an API key. Country names are now provided via the bundled map
/// in [country_localized_names.dart] (covers en, he, es) and Nominatim
/// fallback in [OnlineWorldMapScreen._resolveLocalizedNames].
Future<Map<String, String>?> fetchAndCacheLocalizedCountryNames(
  String langCode,
) async {
  return null;
}
