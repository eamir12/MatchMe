import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/utils/currency_localized_names.dart';
import 'package:matchme/utils/currency_metadata.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CurrencyRateSnapshot {
  final String baseCurrency;
  final Map<String, double> ratesByQuote;
  final DateTime? fetchedAt;

  const CurrencyRateSnapshot({
    required this.baseCurrency,
    required this.ratesByQuote,
    required this.fetchedAt,
  });

  const CurrencyRateSnapshot.empty()
    : baseCurrency = 'USD',
      ratesByQuote = const <String, double>{},
      fetchedAt = null;

  bool get hasRates => ratesByQuote.isNotEmpty;

  bool get isStale {
    final ts = fetchedAt;
    if (ts == null) return true;
    return DateTime.now().toUtc().difference(ts.toUtc()) >
        const Duration(hours: 24);
  }
}

class CurrencyOption {
  final String code;
  final String symbol;
  final String nativeName;
  final String englishName;

  const CurrencyOption({
    required this.code,
    required this.symbol,
    required this.nativeName,
    required this.englishName,
  });
}

const _currencyRatesCacheKey = 'currency_exchange_rates_cache_v1';

final currencyCountryCodeProvider = FutureProvider<String?>((ref) async {
  final deviceLocale = ui.PlatformDispatcher.instance.locale;
  final deviceCountry = deviceLocale.countryCode?.trim().toUpperCase();
  if (deviceCountry != null && deviceCountry.length == 2) {
    return deviceCountry;
  }

  final storedPosition = ref.watch(currentLocationProvider);
  if (storedPosition != null) {
    final country = await getCountryCodeFromPosition(storedPosition);
    if (country != null && country.trim().isNotEmpty) {
      return country.trim().toUpperCase();
    }
  }

  final liveCountry = await getCountryCodeFromLocation();
  if (liveCountry != null && liveCountry.trim().isNotEmpty) {
    return liveCountry.trim().toUpperCase();
  }

  return null;
});

final currencyExchangeRatesProvider = FutureProvider<CurrencyRateSnapshot>((
  ref,
) async {
  final prefs = await SharedPreferences.getInstance();

  Future<CurrencyRateSnapshot> fetchAndCache() async {
    final response = await publicReferenceDataService.fetchCurrencyRates();

    if (response.isEmpty) {
      return const CurrencyRateSnapshot.empty();
    }

    final rates = <String, double>{};
    DateTime? fetchedAt;

    for (final row in response) {
      final quote = (row['quote_currency'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      final rate = (row['rate'] as num?)?.toDouble();
      if (quote.length != 3 || rate == null || rate <= 0) continue;
      rates[quote] = rate;

      final rawFetchedAt = row['fetched_at']?.toString();
      final parsed = rawFetchedAt == null
          ? null
          : DateTime.tryParse(rawFetchedAt);
      if (parsed != null && (fetchedAt == null || parsed.isAfter(fetchedAt))) {
        fetchedAt = parsed;
      }
    }

    final snapshot = CurrencyRateSnapshot(
      baseCurrency: 'USD',
      ratesByQuote: rates,
      fetchedAt: fetchedAt,
    );
    await prefs.setString(
      _currencyRatesCacheKey,
      jsonEncode(_snapshotToJson(snapshot)),
    );
    _currencyRatesMemory = snapshot;
    _currencyRatesMemoryAt = DateTime.now();
    return snapshot;
  }

  // 1) Memory layer — instant.
  if (_currencyRatesMemory != null &&
      _currencyRatesMemory!.ratesByQuote.isNotEmpty) {
    if (!_isCurrencyRatesMemoryFresh() && !shouldSkipSupabaseCalls()) {
      unawaited(
        fetchAndCache()
            .then((fresh) {
              try {
                if (fresh.ratesByQuote.length !=
                    _currencyRatesMemory?.ratesByQuote.length) {
                  ref.invalidateSelf();
                }
              } catch (_) {}
            })
            .catchError((_) {}),
      );
    }
    return _currencyRatesMemory!;
  }

  // 2) Local-storage layer — fast, survives restarts. Displayed immediately.
  try {
    final cached = _loadCachedCurrencySnapshot(prefs);
    if (cached.ratesByQuote.isNotEmpty) {
      _currencyRatesMemory = cached;
      _currencyRatesMemoryAt = DateTime.now();
      if (!shouldSkipSupabaseCalls()) {
        unawaited(
          fetchAndCache()
              .then((fresh) {
                try {
                  if (fresh.ratesByQuote.length != cached.ratesByQuote.length) {
                    ref.invalidateSelf();
                  }
                } catch (_) {}
              })
              .catchError((_) {}),
        );
      }
      return cached;
    }
  } catch (_) {}

  if (shouldSkipSupabaseCalls()) {
    return _loadCachedCurrencySnapshot(prefs);
  }
  try {
    return await fetchAndCache();
  } catch (error) {
    if (!handleExpectedSupabaseOfflineFailure(error)) {
      print('Currency rates unavailable: $error');
    }
    return _loadCachedCurrencySnapshot(prefs);
  }
});

/// In-memory layer for currency rates (memory + SharedPreferences).
CurrencyRateSnapshot? _currencyRatesMemory;
DateTime? _currencyRatesMemoryAt;
const Duration _currencyRatesFreshFor = Duration(hours: 12);

bool _isCurrencyRatesMemoryFresh() {
  if (_currencyRatesMemory == null || _currencyRatesMemoryAt == null) {
    return false;
  }
  return DateTime.now().difference(_currencyRatesMemoryAt!) <
      _currencyRatesFreshFor;
}

final effectiveUserCurrencyProvider = FutureProvider<String>((ref) async {
  final explicit = ref.watch(userPreferredCurrencyProvider);
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }

  final country = await ref.watch(currencyCountryCodeProvider.future);
  return defaultCurrencyForCountry(country);
});

final prioritizedCurrencyCodesProvider = FutureProvider<List<String>>((
  ref,
) async {
  final recents = ref.watch(userRecentCurrenciesProvider);
  final country = await ref.watch(currencyCountryCodeProvider.future);
  final suggested = prioritizedCurrenciesForCountry(country);

  final ordered = <String>[];
  void addAll(Iterable<String> items) {
    for (final code in items) {
      final normalized = code.trim().toUpperCase();
      if (normalized.length != 3 || ordered.contains(normalized)) continue;
      ordered.add(normalized);
      if (ordered.length >= 12) return;
    }
  }

  addAll(recents);
  addAll(suggested);
  addAll(_globalTopCurrencies);

  return ordered;
});

final allCurrencyOptionsProvider = Provider<List<CurrencyOption>>((ref) {
  final options = _allCurrencyCodes
      .map((code) {
        final symbol = currencySymbolForCode(code);
        final nativeName = currencyNativeName(code);
        final englishName = currencyEnglishName(code);
        return CurrencyOption(
          code: code,
          symbol: symbol,
          nativeName: nativeName,
          englishName: englishName,
        );
      })
      .toList(growable: false);
  return options;
});

String currencySymbolForCode(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  try {
    return NumberFormat.simpleCurrency(
      locale: 'en_US',
      name: code,
    ).currencySymbol;
  } catch (_) {
    return code;
  }
}

String currencyDisplayLabel(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  final symbol = currencySymbolForCode(code);
  if (symbol.isEmpty || symbol == code) return code;
  return '$code ($symbol)';
}

String currencyEnglishName(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  return currencyNameMetadata[code]?.englishName ?? code;
}

String currencyNativeName(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  return currencyNameMetadata[code]?.nativeName ?? currencyEnglishName(code);
}

String currencyLocalizedName(String currencyCode, {String localeCode = 'en'}) {
  final code = currencyCode.trim().toUpperCase();
  final normalizedLocale = localeCode.trim().toLowerCase();
  if (normalizedLocale == 'en') {
    return currencyEnglishName(code);
  }
  final localizedName =
      localizedCurrencyNamesByLanguage[normalizedLocale]?[code];
  return localizedName ?? currencyEnglishName(code);
}

String currencyPickerLabel(String currencyCode, {String localeCode = 'en'}) {
  final code = currencyCode.trim().toUpperCase();
  final symbol = currencySymbolForCode(code);
  final name = currencyLocalizedName(code, localeCode: localeCode);
  if (symbol.isEmpty || symbol == code) return name;
  return '$name ($symbol)';
}

String currencySelectedLabel(String currencyCode, {String localeCode = 'en'}) {
  return currencyPickerLabel(currencyCode, localeCode: localeCode);
}

String currencyChooserSecondaryLabel(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  return '${currencyNativeName(code)} - $code';
}

String currencySearchText(String currencyCode, {String localeCode = 'en'}) {
  final code = currencyCode.trim().toUpperCase();
  return <String>[
    code,
    currencySymbolForCode(code),
    currencyLocalizedName(code, localeCode: localeCode),
    currencyNativeName(code),
    currencyEnglishName(code),
  ].join(' ').toLowerCase();
}

String formatCurrencyAmountWithCode(
  double amount,
  String currencyCode, {
  String locale = 'en',
}) {
  final code = currencyCode.trim().toUpperCase();
  final symbol = currencySymbolForCode(code);
  final decimals = _currencyDecimalDigits(code);
  final number = NumberFormat.decimalPattern(locale)
    ..minimumFractionDigits = decimals
    ..maximumFractionDigits = decimals;
  final formattedNumber = number.format(amount);
  if (symbol.isEmpty || symbol == code) {
    return '\u2066$formattedNumber $code\u2069';
  }
  return '\u2066$symbol$formattedNumber $code\u2069';
}

String defaultCurrencyForCountry(String? countryCode) {
  final normalized = countryCode?.trim().toUpperCase() ?? '';
  return _countryPrimaryCurrency[normalized] ?? 'USD';
}

List<String> prioritizedCurrenciesForCountry(String? countryCode) {
  final normalized = countryCode?.trim().toUpperCase() ?? '';
  final primary = _countryPrimaryCurrency[normalized];
  final ordered = <String>[];

  if (primary != null) {
    ordered.add(primary);
  }

  final regional = _regionalCurrencyPriority[normalized];
  if (regional != null) {
    for (final code in regional) {
      if (!ordered.contains(code)) {
        ordered.add(code);
      }
    }
  }

  for (final code in _globalTopCurrencies) {
    if (!ordered.contains(code)) {
      ordered.add(code);
    }
  }

  return ordered;
}

double? convertCurrencyAmount({
  required double amount,
  required String sourceCurrency,
  required String targetCurrency,
  required CurrencyRateSnapshot rates,
}) {
  final source = sourceCurrency.trim().toUpperCase();
  final target = targetCurrency.trim().toUpperCase();
  final base = rates.baseCurrency.trim().toUpperCase();

  if (amount.isNaN || amount.isInfinite) return null;
  if (source == target) return amount;

  final sourcePerBase = source == base ? 1.0 : rates.ratesByQuote[source];
  final targetPerBase = target == base ? 1.0 : rates.ratesByQuote[target];

  if (sourcePerBase == null || targetPerBase == null) return null;

  final amountInBase = amount / sourcePerBase;
  return amountInBase * targetPerBase;
}

String formatCurrencyAmount(
  double amount,
  String currencyCode, {
  String locale = 'en',
}) {
  final code = currencyCode.trim().toUpperCase();
  try {
    return NumberFormat.currency(locale: locale, name: code).format(amount);
  } catch (_) {
    final safe = amount.toStringAsFixed(2);
    return '$safe $code';
  }
}

const List<String> _globalTopCurrencies = <String>[
  'USD',
  'EUR',
  'GBP',
  'JPY',
  'CAD',
  'AUD',
  'ILS',
  'CHF',
  'CNY',
  'INR',
];

CurrencyRateSnapshot _loadCachedCurrencySnapshot(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(_currencyRatesCacheKey);
    if (raw == null || raw.isEmpty) {
      return const CurrencyRateSnapshot.empty();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return const CurrencyRateSnapshot.empty();
    }
    final baseCurrency =
        (decoded['base_currency'] as String?)?.trim().toUpperCase() ?? 'USD';
    final fetchedAt = decoded['fetched_at'] == null
        ? null
        : DateTime.tryParse(decoded['fetched_at'].toString());
    final rawRates = decoded['rates_by_quote'];
    final rates = <String, double>{};
    if (rawRates is Map) {
      for (final entry in rawRates.entries) {
        final code = entry.key.toString().trim().toUpperCase();
        final rate = (entry.value as num?)?.toDouble();
        if (code.length != 3 || rate == null || rate <= 0) continue;
        rates[code] = rate;
      }
    }
    if (rates.isEmpty) {
      return const CurrencyRateSnapshot.empty();
    }
    return CurrencyRateSnapshot(
      baseCurrency: baseCurrency,
      ratesByQuote: rates,
      fetchedAt: fetchedAt,
    );
  } catch (_) {
    return const CurrencyRateSnapshot.empty();
  }
}

Map<String, dynamic> _snapshotToJson(CurrencyRateSnapshot snapshot) {
  return <String, dynamic>{
    'base_currency': snapshot.baseCurrency,
    'fetched_at': snapshot.fetchedAt?.toUtc().toIso8601String(),
    'rates_by_quote': snapshot.ratesByQuote,
  };
}

int _currencyDecimalDigits(String currencyCode) {
  switch (currencyCode.trim().toUpperCase()) {
    case 'BHD':
    case 'IQD':
    case 'JOD':
    case 'KWD':
    case 'LYD':
    case 'OMR':
    case 'TND':
      return 3;
    case 'BIF':
    case 'CLP':
    case 'DJF':
    case 'GNF':
    case 'ISK':
    case 'JPY':
    case 'KMF':
    case 'KRW':
    case 'PYG':
    case 'RWF':
    case 'UGX':
    case 'VND':
    case 'VUV':
    case 'XAF':
    case 'XOF':
    case 'XPF':
      return 0;
    default:
      return 2;
  }
}

const Map<String, String> _countryPrimaryCurrency = <String, String>{
  'AE': 'AED',
  'AR': 'ARS',
  'AT': 'EUR',
  'AU': 'AUD',
  'BE': 'EUR',
  'BG': 'BGN',
  'BH': 'BHD',
  'BR': 'BRL',
  'CA': 'CAD',
  'CH': 'CHF',
  'CL': 'CLP',
  'CN': 'CNY',
  'CO': 'COP',
  'CZ': 'CZK',
  'DE': 'EUR',
  'DK': 'DKK',
  'EG': 'EGP',
  'ES': 'EUR',
  'EU': 'EUR',
  'FI': 'EUR',
  'FR': 'EUR',
  'GB': 'GBP',
  'GR': 'EUR',
  'HK': 'HKD',
  'HU': 'HUF',
  'ID': 'IDR',
  'IE': 'EUR',
  'IL': 'ILS',
  'IN': 'INR',
  'IS': 'ISK',
  'IT': 'EUR',
  'JP': 'JPY',
  'KR': 'KRW',
  'KW': 'KWD',
  'MX': 'MXN',
  'MY': 'MYR',
  'NG': 'NGN',
  'NL': 'EUR',
  'NO': 'NOK',
  'NZ': 'NZD',
  'PE': 'PEN',
  'PH': 'PHP',
  'PL': 'PLN',
  'PT': 'EUR',
  'QA': 'QAR',
  'RO': 'RON',
  'RU': 'RUB',
  'SA': 'SAR',
  'SE': 'SEK',
  'SG': 'SGD',
  'TH': 'THB',
  'TR': 'TRY',
  'TW': 'TWD',
  'UA': 'UAH',
  'US': 'USD',
  'UY': 'UYU',
  'VN': 'VND',
  'ZA': 'ZAR',
};

const Map<String, List<String>> _regionalCurrencyPriority =
    <String, List<String>>{
      'AE': <String>['AED', 'USD', 'EUR', 'SAR', 'GBP'],
      'AR': <String>['ARS', 'USD', 'EUR', 'BRL'],
      'AU': <String>['AUD', 'USD', 'NZD', 'EUR', 'GBP'],
      'BR': <String>['BRL', 'USD', 'EUR', 'ARS'],
      'CA': <String>['CAD', 'USD', 'EUR', 'GBP'],
      'CH': <String>['CHF', 'EUR', 'USD', 'GBP'],
      'CN': <String>['CNY', 'USD', 'EUR', 'JPY', 'HKD'],
      'DE': <String>['EUR', 'USD', 'GBP', 'CHF'],
      'EG': <String>['EGP', 'USD', 'EUR', 'SAR'],
      'ES': <String>['EUR', 'USD', 'GBP', 'CHF'],
      'FR': <String>['EUR', 'USD', 'GBP', 'CHF'],
      'GB': <String>['GBP', 'EUR', 'USD', 'CHF'],
      'HK': <String>['HKD', 'USD', 'CNY', 'EUR', 'JPY'],
      'IL': <String>['ILS', 'USD', 'EUR', 'GBP'],
      'IN': <String>['INR', 'USD', 'EUR', 'GBP', 'AED'],
      'JP': <String>['JPY', 'USD', 'EUR', 'GBP'],
      'KR': <String>['KRW', 'USD', 'JPY', 'EUR'],
      'MX': <String>['MXN', 'USD', 'EUR', 'CAD'],
      'NL': <String>['EUR', 'USD', 'GBP', 'CHF'],
      'NZ': <String>['NZD', 'AUD', 'USD', 'EUR'],
      'PL': <String>['PLN', 'EUR', 'USD', 'GBP'],
      'QA': <String>['QAR', 'USD', 'EUR', 'SAR'],
      'SA': <String>['SAR', 'USD', 'EUR', 'AED'],
      'SE': <String>['SEK', 'EUR', 'USD', 'NOK'],
      'SG': <String>['SGD', 'USD', 'EUR', 'MYR', 'JPY'],
      'TH': <String>['THB', 'USD', 'EUR', 'JPY'],
      'TR': <String>['TRY', 'USD', 'EUR', 'GBP'],
      'US': <String>['USD', 'CAD', 'EUR', 'GBP', 'MXN'],
      'ZA': <String>['ZAR', 'USD', 'EUR', 'GBP'],
    };

const List<String> _allCurrencyCodes = <String>[
  'AED',
  'AFN',
  'ALL',
  'AMD',
  'ANG',
  'AOA',
  'ARS',
  'AUD',
  'AWG',
  'AZN',
  'BAM',
  'BBD',
  'BDT',
  'BGN',
  'BHD',
  'BIF',
  'BMD',
  'BND',
  'BOB',
  'BRL',
  'BSD',
  'BTN',
  'BWP',
  'BYN',
  'BZD',
  'CAD',
  'CDF',
  'CHF',
  'CLP',
  'CNY',
  'COP',
  'CRC',
  'CUP',
  'CVE',
  'CZK',
  'DJF',
  'DKK',
  'DOP',
  'DZD',
  'EGP',
  'ERN',
  'ETB',
  'EUR',
  'FJD',
  'FKP',
  'GBP',
  'GEL',
  'GGP',
  'GHS',
  'GIP',
  'GMD',
  'GNF',
  'GTQ',
  'GYD',
  'HKD',
  'HNL',
  'HRK',
  'HTG',
  'HUF',
  'IDR',
  'ILS',
  'IMP',
  'INR',
  'IQD',
  'IRR',
  'ISK',
  'JEP',
  'JMD',
  'JOD',
  'JPY',
  'KES',
  'KGS',
  'KHR',
  'KMF',
  'KPW',
  'KRW',
  'KWD',
  'KYD',
  'KZT',
  'LAK',
  'LBP',
  'LKR',
  'LRD',
  'LSL',
  'LYD',
  'MAD',
  'MDL',
  'MGA',
  'MKD',
  'MMK',
  'MNT',
  'MOP',
  'MRU',
  'MUR',
  'MVR',
  'MWK',
  'MXN',
  'MYR',
  'MZN',
  'NAD',
  'NGN',
  'NIO',
  'NOK',
  'NPR',
  'NZD',
  'OMR',
  'PAB',
  'PEN',
  'PGK',
  'PHP',
  'PKR',
  'PLN',
  'PYG',
  'QAR',
  'RON',
  'RSD',
  'RUB',
  'RWF',
  'SAR',
  'SBD',
  'SCR',
  'SDG',
  'SEK',
  'SGD',
  'SHP',
  'SLE',
  'SOS',
  'SRD',
  'SSP',
  'STN',
  'SVC',
  'SYP',
  'SZL',
  'THB',
  'TJS',
  'TMT',
  'TND',
  'TOP',
  'TRY',
  'TTD',
  'TWD',
  'TZS',
  'UAH',
  'UGX',
  'USD',
  'UYU',
  'UZS',
  'VES',
  'VND',
  'VUV',
  'WST',
  'XAF',
  'XCD',
  'XOF',
  'XPF',
  'YER',
  'ZAR',
  'ZMW',
  'ZWL',
];
