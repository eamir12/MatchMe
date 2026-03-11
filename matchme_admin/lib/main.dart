import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:matchme_admin/utils/open_attachment.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = await _resolveSupabaseRuntimeConfig();
  final supabaseUrl = config.url;
  final supabaseAnonKey = config.anonKey;

  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  }

  runApp(const ProviderScope(child: AdminApp()));
}

void _disposeTextControllersLater(List<TextEditingController> controllers) {
  unawaited(
    Future<void>.delayed(const Duration(milliseconds: 250)).then((_) {
      for (final c in controllers) {
        c.dispose();
      }
    }),
  );
}

class _AdminCacheHit<T> {
  final T data;
  final bool isFresh;

  const _AdminCacheHit({
    required this.data,
    required this.isFresh,
  });
}

class _AdminCacheEntry {
  final int tsMs;
  final Object? data;

  const _AdminCacheEntry({
    required this.tsMs,
    required this.data,
  });
}

class _AdminCache {
  static const Duration ttl = Duration(minutes: 5);
  static final Map<String, _AdminCacheEntry> _memory = {};

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static bool _isFresh(int tsMs) {
    return (_nowMs() - tsMs) <= ttl.inMilliseconds;
  }

  static Future<_AdminCacheEntry?> _readPersisted(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final ts = decoded['ts'];
      final data = decoded['data'];
      final tsMs = ts is int ? ts : int.tryParse(ts.toString());
      if (tsMs == null) return null;
      return _AdminCacheEntry(tsMs: tsMs, data: data);
    } catch (_) {
      return null;
    }
  }

  static Future<_AdminCacheEntry?> readRaw(String key) async {
    final mem = _memory[key];
    if (mem != null) return mem;
    final entry = await _readPersisted(key);
    if (entry == null) return null;
    _memory[key] = entry;
    return entry;
  }

  static Future<void> writeRaw(String key, Object? data) async {
    final entry = _AdminCacheEntry(tsMs: _nowMs(), data: data);
    _memory[key] = entry;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(<String, Object?>{'ts': entry.tsMs, 'data': data}),
    );
  }

  static Future<_AdminCacheHit<T>?> read<T>(
    String key,
    T Function(Object? raw) decode,
  ) async {
    final entry = await readRaw(key);
    if (entry == null) return null;
    try {
      return _AdminCacheHit<T>(
        data: decode(entry.data),
        isFresh: _isFresh(entry.tsMs),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write<T>(
    String key,
    Object? Function(T value) encode,
    T value,
  ) async {
    await writeRaw(key, encode(value));
  }
}

String uiLanguageNameFallback(LocalizationState l10n, String code) {
  final normalized = code.trim().toLowerCase();
  return switch (normalized) {
    'en' => l10n.getString('adminIntentsInterestsLocaleEn'),
    'es' => l10n.getString('adminIntentsInterestsLocaleEs'),
    'he' => l10n.getString('adminIntentsInterestsLocaleHe'),
    _ => normalized.toUpperCase(),
  };
}

String maskUserDisplayName(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  final parts = s
      .split(RegExp(r'\s+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return s;
  if (parts.length == 1) return parts.first;
  final first = parts.first;
  final last = parts.last;
  if (last.isEmpty) return first;
  return '$first ${last[0].toUpperCase()}.';
}

Future<Map<String, String>> loadUiLanguageDisplayNames() async {
  Map<String, String> decode(Object? raw) {
    if (raw is! Map) return const {};
    final m = Map<String, dynamic>.from(raw);
    final out = <String, String>{};
    for (final entry in m.entries) {
      final k = entry.key.toString().trim().toLowerCase();
      final v = (entry.value ?? '').toString().trim();
      if (k.isEmpty || v.isEmpty) continue;
      out[k] = v;
    }
    return out;
  }

  const cacheKey = 'admin_cache:app_languages:v1:display_name:en_es_he';
  final cached = await _AdminCache.read<Map<String, String>>(cacheKey, decode);
  if (cached != null) {
    if (cached.isFresh) return cached.data;
    unawaited(_AdminCache.readRaw(cacheKey).then((_) {}));
  }

  try {
    final rowsRaw = await Supabase.instance.client
        .from('app_languages')
        .select('language_code, display_name')
        .inFilter('language_code', const ['en', 'es', 'he'])
        .timeout(const Duration(seconds: 8));

    final rows = List<Map<String, dynamic>>.from(rowsRaw as List);
    final out = <String, String>{};
    for (final m in rows) {
      final code = (m['language_code'] ?? '').toString().trim().toLowerCase();
      final name = (m['display_name'] ?? '').toString().trim();
      if (code.isEmpty || name.isEmpty) continue;
      out[code] = name;
    }

    await _AdminCache.write<Map<String, String>>(cacheKey, (v) => v, out);
    return out;
  } catch (_) {
    return cached?.data ?? const {};
  }
}

class _SupabaseRuntimeConfig {
  final String url;
  final String anonKey;
  const _SupabaseRuntimeConfig({required this.url, required this.anonKey});
}

String _stripOptionalQuotes(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

String _sanitizeSupabaseAnonKey(String value) {
  return _stripOptionalQuotes(value).replaceAll(RegExp(r'\s+'), '');
}

Map<String, String> _parseDotEnvString(String raw) {
  final map = <String, String>{};
  for (final line in raw.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final key = trimmed.substring(0, eq).trim();
    final value = trimmed.substring(eq + 1).trim();
    if (key.isEmpty) continue;
    map[key] = _stripOptionalQuotes(value);
  }
  return map;
}

Future<Map<String, String>> _loadDotEnvFromAssets() async {
  try {
    final raw = await rootBundle.loadString('assets/.env');
    return _parseDotEnvString(raw);
  } catch (_) {
    return const {};
  }
}

Future<_SupabaseRuntimeConfig> _resolveSupabaseRuntimeConfig() async {
  var url = const String.fromEnvironment('SUPABASE_URL');
  var anonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');

  final qp = Uri.base.queryParameters;
  if (url.isEmpty) {
    url = qp['SUPABASE_URL'] ?? qp['supabase_url'] ?? '';
  }
  if (anonKey.isEmpty) {
    anonKey = qp['SUPABASE_ANON_KEY'] ?? qp['supabase_anon_key'] ?? '';
  }

  if (url.isEmpty || anonKey.isEmpty) {
    final env = await _loadDotEnvFromAssets();
    if (url.isEmpty) url = env['SUPABASE_URL'] ?? '';
    if (anonKey.isEmpty) anonKey = env['SUPABASE_ANON_KEY'] ?? '';
  }

  return _SupabaseRuntimeConfig(
    url: _stripOptionalQuotes(url),
    anonKey: _sanitizeSupabaseAnonKey(anonKey),
  );
}

class LocalizationState {
  final Locale locale;
  final TextDirection textDirection;
  final Map<String, String> strings;
  final bool isLoading;

  const LocalizationState({
    required this.locale,
    required this.textDirection,
    required this.strings,
    required this.isLoading,
  });

  factory LocalizationState.initial() => const LocalizationState(
        locale: Locale('en'),
        textDirection: TextDirection.ltr,
        strings: {},
        isLoading: true,
      );

  LocalizationState copyWith({
    Locale? locale,
    TextDirection? textDirection,
    Map<String, String>? strings,
    bool? isLoading,
  }) {
    return LocalizationState(
      locale: locale ?? this.locale,
      textDirection: textDirection ?? this.textDirection,
      strings: strings ?? this.strings,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  String getString(String key) {
    final translation = strings[key];
    if (translation != null && translation.isNotEmpty) return translation;
    final fallback = _defaultTranslations[key];
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return '$key...';
  }
}

DateFormat _adminDateTimeFormat(LocalizationState l10n) {
  final code = l10n.locale.languageCode.trim();
  final locale = code.isEmpty ? 'en' : code;
  return DateFormat.yMMMd(locale).add_jm();
}

String _formatAdminDateTime(LocalizationState l10n, DateTime dt) {
  return _adminDateTimeFormat(l10n).format(dt.toLocal());
}

class LocalizationNotifier extends Notifier<LocalizationState> {
  int _loadSeq = 0;

  @override
  LocalizationState build() {
    final platformLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final initial = supportedLocales.firstWhere(
      (l) => l.languageCode == platformLocale.languageCode,
      orElse: () => const Locale('en'),
    );
    Future.microtask(() => setLocale(initial.languageCode));
    return LocalizationState.initial();
  }

  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('he'),
  ];

  Future<void> setLocale(String languageCode, {bool force = false}) async {
    final locale = supportedLocales.firstWhere(
      (l) => l.languageCode == languageCode,
      orElse: () => const Locale('en'),
    );

    if (!force && state.locale.languageCode == locale.languageCode && !state.isLoading) {
      return;
    }

    final requestId = ++_loadSeq;
    final direction =
        (locale.languageCode == 'he') ? TextDirection.rtl : TextDirection.ltr;

    Map<String, String> decodeStringMap(Object? raw) {
      if (raw is! Map) return const {};
      final out = <String, String>{};
      for (final e in raw.entries) {
        final k = e.key.toString();
        final v = e.value?.toString() ?? '';
        if (k.isNotEmpty) out[k] = v;
      }
      return out;
    }

    final cacheKey = 'admin_cache:l10n:${locale.languageCode}';
    final cached = await _AdminCache.read<Map<String, String>>(
      cacheKey,
      decodeStringMap,
    );
    if (requestId != _loadSeq) return;

    state = state.copyWith(
      locale: locale,
      textDirection: direction,
      strings: cached?.data ?? const {},
      isLoading: cached == null,
    );

    if (!force && cached != null && cached.isFresh) return;

    final strings = await _fetchTranslations(locale.languageCode);
    if (requestId != _loadSeq) return;

    state = state.copyWith(
      strings: strings,
      isLoading: false,
    );
    await _AdminCache.write<Map<String, String>>(
      cacheKey,
      (v) => v,
      strings,
    );
  }

  Future<void> patchTranslationValue({
    required String locale,
    required String key,
    required String value,
  }) async {
    Map<String, String> decodeStringMap(Object? raw) {
      if (raw is! Map) return const {};
      final out = <String, String>{};
      for (final e in raw.entries) {
        final k = e.key.toString();
        final v = e.value?.toString() ?? '';
        if (k.isNotEmpty) out[k] = v;
      }
      return out;
    }

    final trimmedLocale = locale.trim().toLowerCase();
    final trimmedKey = key.trim();
    if (trimmedLocale.isEmpty || trimmedKey.isEmpty) return;

    final cacheKey = 'admin_cache:l10n:$trimmedLocale';
    final cached = await _AdminCache.read<Map<String, String>>(
      cacheKey,
      decodeStringMap,
    );
    if (cached != null) {
      final updated = Map<String, String>.from(cached.data);
      updated[trimmedKey] = value;
      await _AdminCache.write<Map<String, String>>(cacheKey, (v) => v, updated);
    }

    if (state.locale.languageCode == trimmedLocale) {
      final updated = Map<String, String>.from(state.strings);
      updated[trimmedKey] = value;
      state = state.copyWith(strings: updated);
    }
  }

  Future<Map<String, String>> _fetchTranslations(String languageCode) async {
    try {
      final client = Supabase.instance.client;
      final allStrings = <String, String>{};
      var offset = 0;
      const batchSize = 1000;
      while (true) {
        final batch = await client
            .from('translations')
            .select('key, value')
            .eq('locale', languageCode)
            .range(offset, offset + batchSize - 1);

        final rows = List<Map<String, dynamic>>.from(batch);
        for (final row in rows) {
          final k = row['key'] as String?;
          final v = row['value'] as String?;
          if (k != null && k.isNotEmpty && v != null) {
            allStrings[k] = v;
          }
        }

        if (rows.length < batchSize) break;
        offset += batchSize;
      }
      return allStrings;
    } catch (_) {
      return const {};
    }
  }
}

final localizationProvider =
    NotifierProvider<LocalizationNotifier, LocalizationState>(() {
  return LocalizationNotifier();
});

final sessionProvider = StreamProvider<Session?>((ref) {
  final controller = StreamController<Session?>();
  final auth = Supabase.instance.client.auth;

  controller.add(auth.currentSession);

  final sub = auth.onAuthStateChange.listen((event) {
    controller.add(event.session);
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

final isAdminProvider = FutureProvider<bool>((ref) async {
  final sessionAsync = ref.watch(sessionProvider);
  final session = sessionAsync.asData?.value;
  if (session == null) return false;

  final userId = session.user.id;
  bool decodeBool(Object? raw) {
    if (raw == true) return true;
    if (raw == false) return false;
    return raw.toString().toLowerCase() == 'true';
  }

  final cacheKey = 'admin_cache:is_admin:v1:$userId';
  final cached = await _AdminCache.read<bool>(
    cacheKey,
    decodeBool,
  );
  if (cached != null && cached.isFresh) return cached.data;

  try {
    final row = await Supabase.instance.client
        .from('users')
        .select('is_admin')
        .eq('id', userId)
        .maybeSingle();
    final isAdmin = row != null && row['is_admin'] == true;
    await _AdminCache.write<bool>(cacheKey, (v) => v, isAdmin);
    return isAdmin;
  } catch (_) {
    return cached?.data ?? false;
  }
});

class _AdminLoginBannerKeyNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setKey(String? key) {
    state = key;
  }
}

final adminLoginBannerKeyProvider =
    NotifierProvider<_AdminLoginBannerKeyNotifier, String?>(
  _AdminLoginBannerKeyNotifier.new,
);

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    return MaterialApp(
      title: l10n.getString('adminAppTitle'),
      locale: l10n.locale,
      supportedLocales: LocalizationNotifier.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return Directionality(
          textDirection: l10n.textDirection,
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        scrollbarTheme: ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(6),
          radius: Radius.circular(8),
          thumbVisibility: WidgetStatePropertyAll(false),
        ),
      ),
      home: const _BootstrapGate(),
    );
  }
}

class _BootstrapGate extends ConsumerWidget {
  const _BootstrapGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);

    var isSupabaseReady = true;
    try {
      Supabase.instance.client;
    } catch (_) {
      isSupabaseReady = false;
    }
    if (!isSupabaseReady) {
      return _MessageScaffold(
        title: l10n.getString('adminAppTitle'),
        body: l10n.getString('supabaseConfigMissing'),
      );
    }

    if (l10n.isLoading) {
      return _MessageScaffold(
        title: l10n.getString('adminAppTitle'),
        body: l10n.getString('generalLoading'),
        showSpinner: true,
      );
    }

    return const _AuthGate();
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionAsync = ref.watch(sessionProvider);
    return sessionAsync.when(
      data: (session) {
        if (session == null) return const _LoginScreen();
        final isAdminAsync = ref.watch(isAdminProvider);
        return isAdminAsync.when(
          data: (isAdmin) {
            if (!isAdmin) {
              return const _KickoutToLogin(messageKey: 'adminNotAuthorized');
            }
            return const _AdminShell();
          },
          loading: () {
            final l10n = ref.watch(localizationProvider);
            return _MessageScaffold(
              title: l10n.getString('adminAppTitle'),
              body: l10n.getString('generalLoading'),
              showSpinner: true,
            );
          },
          error: (err, st) {
            final l10n = ref.watch(localizationProvider);
            return _MessageScaffold(
              title: l10n.getString('adminAppTitle'),
              body: l10n.getString('adminAuthCheckFailed'),
            );
          },
        );
      },
      loading: () {
        final l10n = ref.watch(localizationProvider);
        return _MessageScaffold(
          title: l10n.getString('adminAppTitle'),
          body: l10n.getString('generalLoading'),
          showSpinner: true,
        );
      },
      error: (err, st) {
        final l10n = ref.watch(localizationProvider);
        return _MessageScaffold(
          title: l10n.getString('adminAppTitle'),
          body: l10n.getString('authStreamError'),
        );
      },
    );
  }
}

class _KickoutToLogin extends ConsumerStatefulWidget {
  final String messageKey;

  const _KickoutToLogin({required this.messageKey});

  @override
  ConsumerState<_KickoutToLogin> createState() => _KickoutToLoginState();
}

class _KickoutToLoginState extends ConsumerState<_KickoutToLogin> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_run);
  }

  Future<void> _run() async {
    if (_started) return;
    _started = true;
    ref.read(adminLoginBannerKeyProvider.notifier).setKey(widget.messageKey);
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    return _MessageScaffold(
      title: l10n.getString('adminAppTitle'),
      body: l10n.getString('generalLoading'),
      showSpinner: true,
    );
  }
}

class _MessageScaffold extends StatelessWidget {
  final String title;
  final String body;
  final bool showSpinner;

  const _MessageScaffold({
    required this.title,
    required this.body,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSpinner) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    body,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginScreen extends ConsumerStatefulWidget {
  const _LoginScreen();

  @override
  ConsumerState<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<_LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;
  String? _errorKey;

  late final Future<Map<String, String>> _uiLanguageNamesFuture =
      loadUiLanguageDisplayNames();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_isSubmitting) return;
    final l10n = ref.read(localizationProvider);
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) return;

    setState(() {
      _isSubmitting = true;
      _errorKey = null;
    });
    ref.read(adminLoginBannerKeyProvider.notifier).setKey(null);

    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        _errorKey = 'authLoginFailed';
      } else {
        final row = await Supabase.instance.client
            .from('users')
            .select('is_admin')
            .eq('id', userId)
            .maybeSingle();
        final isAdmin = row != null && row['is_admin'] == true;
        if (!isAdmin) {
          ref
              .read(adminLoginBannerKeyProvider.notifier)
              .setKey('adminNotAuthorized');
          try {
            await Supabase.instance.client.auth.signOut();
          } catch (_) {}
        }
      }
    } catch (_) {
      _errorKey = 'authLoginFailed';
    }

    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
    });

    final nextErrorKey = _errorKey;
    if (nextErrorKey != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString(nextErrorKey))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final locale = l10n.locale.languageCode;
    final bannerKey = ref.watch(adminLoginBannerKeyProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('adminLoginTitle')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonHideUnderline(
              child: FutureBuilder<Map<String, String>>(
                future: _uiLanguageNamesFuture,
                builder: (context, snapshot) {
                  final names = snapshot.data ?? const <String, String>{};
                  String displayName(String code) {
                    final normalized = code.trim().toLowerCase();
                    return names[normalized] ??
                        uiLanguageNameFallback(l10n, normalized);
                  }

                  return DropdownButton<String>(
                    value: locale,
                    items: [
                      DropdownMenuItem(
                        value: 'en',
                        child: Text(displayName('en')),
                      ),
                      DropdownMenuItem(
                        value: 'es',
                        child: Text(displayName('es')),
                      ),
                      DropdownMenuItem(
                        value: 'he',
                        child: Text(displayName('he')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      ref.read(localizationProvider.notifier).setLocale(value);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bannerKey != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l10n.getString(bannerKey),
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onErrorContainer,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.getString('generalClose'),
                                  onPressed: () {
                                    ref
                                        .read(adminLoginBannerKeyProvider.notifier)
                                        .setKey(null);
                                  },
                                  icon: Icon(
                                    Icons.close,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: l10n.getString('authEmail'),
                        prefixIcon: const Icon(Icons.email_outlined),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return l10n.getString('authEmailRequired');
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: l10n.getString('authPassword'),
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      validator: (v) {
                        if (v == null || v.isEmpty) {
                          return l10n.getString('authPasswordRequired');
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _signIn(),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _signIn,
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(l10n.getString('authLogin')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AdminSection {
  dashboard,
  appConfig,
  translations,
  subscriptions,
  broadcasts,
  intentsInterests,
  userVerification,
  profileEdits,
}

class _LazyIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const _LazyIndexedStack({
    required this.index,
    required this.children,
  });

  @override
  State<_LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<_LazyIndexedStack> {
  late final List<bool> _built = List<bool>.filled(widget.children.length, false);

  @override
  void initState() {
    super.initState();
    if (widget.children.isNotEmpty) {
      final i = widget.index.clamp(0, widget.children.length - 1);
      _built[i] = true;
    }
  }

  @override
  void didUpdateWidget(covariant _LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.children.length != oldWidget.children.length) {
      final old = List<bool>.from(_built);
      _built
        ..clear()
        ..addAll(List<bool>.filled(widget.children.length, false));
      for (var i = 0; i < old.length && i < _built.length; i++) {
        _built[i] = old[i];
      }
    }

    if (widget.children.isNotEmpty) {
      final i = widget.index.clamp(0, widget.children.length - 1);
      if (!_built[i]) {
        _built[i] = true;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();

    final i = widget.index.clamp(0, widget.children.length - 1);
    return Stack(
      children: [
        for (var idx = 0; idx < widget.children.length; idx++)
          Offstage(
            offstage: idx != i,
            child: TickerMode(
              enabled: idx == i,
              child: _built[idx] ? widget.children[idx] : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

class _AdminShell extends ConsumerStatefulWidget {
  const _AdminShell();

  @override
  ConsumerState<_AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<_AdminShell> {
  _AdminSection _selected = _AdminSection.dashboard;

  late final Future<Map<String, String>> _languagePickerNamesFuture =
      loadUiLanguageDisplayNames();

  Future<void> _signOut() async {
    try {
      ref.read(adminLoginBannerKeyProvider.notifier).setKey(null);
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
  }

  String _sectionTitle(LocalizationState l10n, _AdminSection section) {
    return switch (section) {
      _AdminSection.dashboard => l10n.getString('adminNavDashboard'),
      _AdminSection.appConfig => l10n.getString('adminNavAppConfig'),
      _AdminSection.translations => l10n.getString('adminNavTranslations'),
      _AdminSection.subscriptions => l10n.getString('adminNavSubscriptions'),
      _AdminSection.broadcasts => l10n.getString('adminNavBroadcasts'),
      _AdminSection.intentsInterests => l10n.getString('adminNavIntentsInterests'),
      _AdminSection.userVerification => l10n.getString('adminNavVerification'),
      _AdminSection.profileEdits => l10n.getString('adminNavProfileEdits'),
    };
  }

  List<NavigationRailDestination> _railDestinations(LocalizationState l10n) {
    final destinations = <_AdminSection, NavigationRailDestination>{
      _AdminSection.dashboard: NavigationRailDestination(
        icon: const Icon(Icons.dashboard_outlined),
        selectedIcon: const Icon(Icons.dashboard),
        label: Text(l10n.getString('adminNavDashboard')),
      ),
      _AdminSection.appConfig: NavigationRailDestination(
        icon: const Icon(Icons.tune_outlined),
        selectedIcon: const Icon(Icons.tune),
        label: Text(l10n.getString('adminNavAppConfig')),
      ),
      _AdminSection.translations: NavigationRailDestination(
        icon: const Icon(Icons.translate_outlined),
        selectedIcon: const Icon(Icons.translate),
        label: Text(l10n.getString('adminNavTranslations')),
      ),
      _AdminSection.subscriptions: NavigationRailDestination(
        icon: const Icon(Icons.workspace_premium_outlined),
        selectedIcon: const Icon(Icons.workspace_premium),
        label: Text(l10n.getString('adminNavSubscriptions')),
      ),
      _AdminSection.broadcasts: NavigationRailDestination(
        icon: const Icon(Icons.campaign_outlined),
        selectedIcon: const Icon(Icons.campaign),
        label: Text(l10n.getString('adminNavBroadcasts')),
      ),
      _AdminSection.intentsInterests: NavigationRailDestination(
        icon: const Icon(Icons.category_outlined),
        selectedIcon: const Icon(Icons.category),
        label: Text(l10n.getString('adminNavIntentsInterests')),
      ),
      _AdminSection.userVerification: NavigationRailDestination(
        icon: const Icon(Icons.verified_outlined),
        selectedIcon: const Icon(Icons.verified),
        label: Text(l10n.getString('adminNavVerification')),
      ),
      _AdminSection.profileEdits: NavigationRailDestination(
        icon: const Icon(Icons.fact_check_outlined),
        selectedIcon: const Icon(Icons.fact_check),
        label: Text(l10n.getString('adminNavProfileEdits')),
      ),
    };

    return _AdminSection.values
        .map((s) => destinations[s]!)
        .toList(growable: false);
  }

  List<NavigationDrawerDestination> _drawerDestinations(LocalizationState l10n) {
    return [
      NavigationDrawerDestination(
        icon: const Icon(Icons.dashboard_outlined),
        selectedIcon: const Icon(Icons.dashboard),
        label: Text(l10n.getString('adminNavDashboard')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.tune_outlined),
        selectedIcon: const Icon(Icons.tune),
        label: Text(l10n.getString('adminNavAppConfig')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.translate_outlined),
        selectedIcon: const Icon(Icons.translate),
        label: Text(l10n.getString('adminNavTranslations')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.workspace_premium_outlined),
        selectedIcon: const Icon(Icons.workspace_premium),
        label: Text(l10n.getString('adminNavSubscriptions')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.campaign_outlined),
        selectedIcon: const Icon(Icons.campaign),
        label: Text(l10n.getString('adminNavBroadcasts')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.category_outlined),
        selectedIcon: const Icon(Icons.category),
        label: Text(l10n.getString('adminNavIntentsInterests')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.verified_outlined),
        selectedIcon: const Icon(Icons.verified),
        label: Text(l10n.getString('adminNavVerification')),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.fact_check_outlined),
        selectedIcon: const Icon(Icons.fact_check),
        label: Text(l10n.getString('adminNavProfileEdits')),
      ),
    ];
  }

  List<Widget> _appBarActions(LocalizationState l10n) {
    return [
      FutureBuilder<Map<String, String>>(
        future: _languagePickerNamesFuture,
        builder: (context, snapshot) {
          final names = snapshot.data ?? const <String, String>{};
          String displayName(String code) {
            final normalized = code.trim().toLowerCase();
            return names[normalized] ??
                uiLanguageNameFallback(l10n, normalized);
          }

          return PopupMenuButton<String>(
            tooltip: l10n.getString('adminChangeLanguage'),
            icon: const Icon(Icons.translate),
            initialValue: l10n.locale.languageCode,
            onSelected: (value) {
              ref.read(localizationProvider.notifier).setLocale(value);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'en',
                child: Text(displayName('en')),
              ),
              PopupMenuItem(
                value: 'es',
                child: Text(displayName('es')),
              ),
              PopupMenuItem(
                value: 'he',
                child: Text(displayName('he')),
              ),
            ],
          );
        },
      ),
      IconButton(
        tooltip: l10n.getString('authSignOut'),
        onPressed: _signOut,
        icon: l10n.textDirection == TextDirection.rtl
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
                child: const Icon(Icons.logout),
              )
            : const Icon(Icons.logout),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Directionality(
      textDirection: l10n.textDirection,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final selectedIndex = _AdminSection.values.indexOf(_selected);
          final content = _LazyIndexedStack(
            index: selectedIndex,
            children: const [
              _DashboardScreen(),
              _AppConfigScreen(),
              _TranslationsScreen(),
              _SubscriptionsScreen(),
              _BroadcastsScreen(),
              _IntentsInterestsScreen(),
              _UserVerificationScreen(),
              _ProfileEditRequestsScreen(),
            ],
          );
          final useDrawerLayout =
              constraints.maxWidth < 720 || constraints.maxHeight < 520;
          if (useDrawerLayout) {
            return Scaffold(
              appBar: AppBar(
                title: Text(
                  _sectionTitle(l10n, _selected),
                  overflow: TextOverflow.ellipsis,
                ),
                actions: _appBarActions(l10n),
              ),
              drawer: NavigationDrawer(
                selectedIndex: selectedIndex,
                onDestinationSelected: (index) {
                  setState(() {
                    _selected = _AdminSection.values[index];
                  });
                  Navigator.of(context).pop();
                },
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                    child: Text(
                      l10n.getString('adminAppTitle'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const Divider(height: 1),
                  ..._drawerDestinations(l10n),
                ],
              ),
              body: SafeArea(child: content),
            );
          }

          final isWide = constraints.maxWidth >= 1000;
          final rail = NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
              setState(() {
                _selected = _AdminSection.values[index];
              });
            },
            destinations: _railDestinations(l10n),
            extended: isWide,
          );

          return Scaffold(
            appBar: AppBar(
              title: Text(
                l10n.getString('adminAppTitle'),
                overflow: TextOverflow.ellipsis,
              ),
              actions: _appBarActions(l10n),
            ),
            body: SafeArea(
              child: Row(
                children: [
                  rail,
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DashboardScreen extends ConsumerStatefulWidget {
  const _DashboardScreen();

  @override
  ConsumerState<_DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<_DashboardScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  String? _errorKey;
  Map<String, dynamic>? _data;
  String _window = '24h';
  bool _isFetching = false;
  Timer? _autoRefreshTimer;
  Timer? _scheduledReload;
  Timer? _scheduledFullReload;
  DateTime _lastReloadAt = DateTime.fromMillisecondsSinceEpoch(0);
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupRealtime();
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _scheduleReload(),
    );
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleReload();
    }
  }

  void _setupRealtime() {
    try {
      final channel = Supabase.instance.client.channel('admin-dashboard');

      void onAnyChange(PostgresChangePayload payload) {
        final table = ((payload.newRecord['last_table'] ?? payload.oldRecord['last_table']) ??
                '')
            .toString();
        final op =
            ((payload.newRecord['last_op'] ?? payload.oldRecord['last_op']) ?? '')
                .toString();

        if (table == 'chat_messages' && op == 'INSERT') {
          if (_applyMessageIncrement()) {
            _scheduleFullReload();
            return;
          }
        }

        if (op == 'INSERT') {
          if (_applyInsertIncrement(table)) {
            _scheduleFullReload();
            return;
          }
        }

        _scheduleReload();
      }

      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'admin_dashboard_tick',
        callback: onAnyChange,
      );

      channel.subscribe();
      _channel = channel;
    } catch (_) {}
  }

  void _scheduleReload() {
    if (!mounted) return;
    _scheduledReload?.cancel();
    _scheduledReload = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      final now = DateTime.now();
      if (now.difference(_lastReloadAt) < const Duration(seconds: 2)) {
        return;
      }
      _lastReloadAt = now;
      unawaited(_load(force: true, showLoading: false));
    });
  }

  void _scheduleFullReload() {
    if (!mounted) return;
    _scheduledFullReload?.cancel();
    _scheduledFullReload = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      unawaited(_load(force: true, showLoading: false));
    });
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }

  bool _applyMessageIncrement() {
    final current = _data;
    if (current == null || current.isEmpty) return false;
    final engagement = current['engagement'];
    if (engagement is! Map) return false;

    final next = Map<String, dynamic>.from(current);
    final nextEngagement = Map<String, dynamic>.from(engagement);
    nextEngagement['messages_sent'] = _toInt(nextEngagement['messages_sent']) + 1;
    next['engagement'] = nextEngagement;

    final series = current['engagement_series'];
    if (series is List && series.isNotEmpty) {
      final last = series.last;
      if (last is Map) {
        final nextSeries = series
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
            .toList(growable: false);
        final lastMap = Map<String, dynamic>.from(last);
        lastMap['messages'] = _toInt(lastMap['messages']) + 1;
        nextSeries[nextSeries.length - 1] = lastMap;
        next['engagement_series'] = nextSeries;
      }
    }

    if (!mounted) return false;
    setState(() {
      _data = next;
    });
    return true;
  }

  bool _applyInsertIncrement(String table) {
    final current = _data;
    if (current == null || current.isEmpty) return false;

    final engagement = current['engagement'];
    final operations = current['operations'];
    if (engagement is! Map || operations is! Map) return false;

    final next = Map<String, dynamic>.from(current);
    final nextEngagement = Map<String, dynamic>.from(engagement);
    final nextOperations = Map<String, dynamic>.from(operations);

    bool bumpEngagementKey(String key) {
      nextEngagement[key] = _toInt(nextEngagement[key]) + 1;
      next['engagement'] = nextEngagement;
      return true;
    }

    bool bumpOperationsKey(String key) {
      nextOperations[key] = _toInt(nextOperations[key]) + 1;
      next['operations'] = nextOperations;
      return true;
    }

    bool bumpSeriesKey(String key) {
      final series = current['engagement_series'];
      if (series is! List || series.isEmpty) return false;
      final last = series.last;
      if (last is! Map) return false;
      final nextSeries = series
          .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
          .toList(growable: false);
      final lastMap = Map<String, dynamic>.from(last);
      lastMap[key] = _toInt(lastMap[key]) + 1;
      nextSeries[nextSeries.length - 1] = lastMap;
      next['engagement_series'] = nextSeries;
      return true;
    }

    bool applied = false;

    switch (table) {
      case 'matches':
        applied = bumpEngagementKey('matches_created');
        applied = bumpSeriesKey('matches') || applied;
        break;
      case 'users':
        applied = bumpEngagementKey('new_users');
        applied = bumpSeriesKey('signups') || applied;
        break;
      case 'profile_edit_requests':
        applied = bumpOperationsKey('profile_edits_pending');
        break;
      case 'admin_broadcasts':
        applied = bumpOperationsKey('broadcasts_draft');
        break;
      case 'notification_queue':
        applied = bumpOperationsKey('notifications_pending');
        break;
    }

    if (!applied || !mounted) return false;
    setState(() {
      _data = next;
    });
    return true;
  }

  Future<void> _load({bool force = false, bool showLoading = true}) async {
    if (_isFetching) return;
    Map<String, dynamic> decodeMap(Object? raw) {
      if (raw is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(raw);
    }

    final cacheKey = 'admin_cache:dashboard:v1:$_window';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<Map<String, dynamic>>(cacheKey, decodeMap);
      if (!mounted) return;
      if (cached != null && cached.data.isNotEmpty) {
        setState(() {
          _data = cached.data;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      final hasExisting = (_data != null && (_data?.isNotEmpty ?? false));
      _isLoading = showLoading && !(hadCached || hasExisting);
      _errorKey = null;
    });

    try {
      _isFetching = true;
      final res = await Supabase.instance.client
          .rpc('admin_get_dashboard_stats', params: {'p_window': _window}).timeout(
        const Duration(seconds: 20),
      );

      final map = decodeMap(res);
      await _AdminCache.write<Map<String, dynamic>>(cacheKey, (v) => v, map);

      if (!mounted) return;
      setState(() {
        _data = map;
        _isLoading = false;
        _errorKey = null;
      });
    } catch (_) {
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminDashboardLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminDashboardLoadFailed';
          _isLoading = false;
        });
      }
    } finally {
      _isFetching = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    _scheduledReload?.cancel();
    _scheduledFullReload?.cancel();
    final channel = _channel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    if (_isLoading) {
      return _MessageScaffold(
        title: l10n.getString('adminNavDashboard'),
        body: l10n.getString('generalLoading'),
        showSpinner: true,
      );
    }

    if (_errorKey != null) {
      return _MessageScaffold(
        title: l10n.getString('adminNavDashboard'),
        body: l10n.getString(_errorKey!),
      );
    }

    final data = _data ?? const <String, dynamic>{};
    final engagement = (data['engagement'] as Map?) ?? const {};
    final operations = (data['operations'] as Map?) ?? const {};
    final revenue = (data['revenue'] as Map?) ?? const {};
    final ai = (data['ai'] as Map?) ?? const {};
    final edgeFunctions = (data['edge_functions'] as Map?) ?? const {};

    List<Map<String, dynamic>> decodeListOfMaps(Object? raw) {
      if (raw is! List) return const <Map<String, dynamic>>[];
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }

    final aiUsage = decodeListOfMaps(ai['usage']);
    final aiRecentErrors = decodeListOfMaps(ai['recent_errors']);
    final aiQuotaStatus = (ai['quota_status'] is Map)
        ? Map<String, dynamic>.from(ai['quota_status'] as Map)
        : const <String, dynamic>{};
    final aiQuotaProviders = decodeListOfMaps(aiQuotaStatus['providers']);
    final aiQuotaUpdatedAt = DateTime.tryParse(
      (aiQuotaStatus['updated_at'] ?? '').toString(),
    );
    final edgeUsage = decodeListOfMaps(edgeFunctions['usage']);
    final edgeRecentErrors = decodeListOfMaps(edgeFunctions['recent_errors']);

    final series = (data['engagement_series'] is List)
        ? List<Map<String, dynamic>>.from(
            (data['engagement_series'] as List).whereType<Map>().map(
                  (e) => Map<String, dynamic>.from(e),
                ),
          )
        : const <Map<String, dynamic>>[];

    final windowLabelKey =
        _window == '7d' ? 'adminDashboardWindow7d' : 'adminDashboardWindow24h';
    final bucketKey =
        _window == '7d' ? 'adminDashboardBucketDay' : 'adminDashboardBucketHour';
    final barsKey = _window == '7d'
        ? 'adminDashboardSeriesBucketsDaily'
        : 'adminDashboardSeriesBucketsHourly';

    final numFmt = NumberFormat.compact(locale: l10n.locale.languageCode);
    String fmtInt(dynamic v) {
      final n = (v is num) ? v.toInt() : int.tryParse((v ?? '').toString()) ?? 0;
      return numFmt.format(n);
    }

    String fmtNum(dynamic v) {
      final n = (v is num) ? v : num.tryParse((v ?? '').toString()) ?? 0;
      return numFmt.format(n);
    }

    String aiProviderLabel(String provider) {
      final p = provider.trim().toLowerCase();
      if (p == 'deepl') return l10n.getString('adminAiProviderDeepL');
      if (p == 'gemini') return l10n.getString('adminAiProviderGemini');
      return provider;
    }

    String aiQuotaWindowLabel(String window) {
      final w = window.trim().toLowerCase();
      if (w == 'billing_period') {
        return l10n.getString('adminDashboardAIQuotaWindowBillingPeriod');
      }
      if (w == '24h') return l10n.getString('adminDashboardWindow24h');
      if (w == '7d') return l10n.getString('adminDashboardWindow7d');
      return window;
    }

    String aiQuotaStatusLabel(String status) {
      final s = status.trim().toLowerCase();
      return switch (s) {
        'ok' => l10n.getString('adminAiQuotaStatusOk'),
        'warn' => l10n.getString('adminAiQuotaStatusWarn'),
        'critical' => l10n.getString('adminAiQuotaStatusCritical'),
        _ => l10n.getString('adminAiQuotaStatusUnknown'),
      };
    }

    List<int> seriesInts(String key) {
      return series
          .map((e) {
            final v = e[key];
            if (v is num) return v.toInt();
            return int.tryParse((v ?? '').toString()) ?? 0;
          })
          .toList(growable: false);
    }

    List<DateTime> seriesTimes() {
      return series
          .map((e) => DateTime.tryParse((e['t'] ?? '').toString()))
          .whereType<DateTime>()
          .toList(growable: false);
    }

    final bucketStarts = seriesTimes();

    final paidByTier = (revenue['paid_by_tier'] is Map)
        ? Map<String, dynamic>.from(revenue['paid_by_tier'] as Map)
        : const <String, dynamic>{};
    final earningsByCurrency = (revenue['earnings_by_currency'] is Map)
        ? Map<String, dynamic>.from(revenue['earnings_by_currency'] as Map)
        : const <String, dynamic>{};

    final generatedAtRaw = (data['generated_at'] ?? '').toString();
    final generatedAt = DateTime.tryParse(generatedAtRaw);

    void openDrilldown({
      required String titleKey,
      required String metric,
      String? param,
    }) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _AdminDashboardDrilldownScreen(
            titleKey: titleKey,
            window: _window,
            metric: metric,
            param: param,
          ),
        ),
      );
    }

    String formatEarnings(Map<String, dynamic> byCurrency) {
      if (byCurrency.isEmpty) return fmtInt(0);
      const currencyLocale = 'en_US';
      final currencyEntries = byCurrency.entries
          .map((e) {
            final code = e.key.toString().trim();
            final v = e.value;
            final amount = (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0;
            if (code.isEmpty) return null;
            try {
              String symbol = '';
              int? decimalDigits;
              try {
                final fmt = NumberFormat.simpleCurrency(
                  locale: currencyLocale,
                  name: code,
                );
                symbol = fmt.currencySymbol;
                decimalDigits = fmt.decimalDigits;
              } catch (_) {}

              if (symbol.trim().toUpperCase() == code.toUpperCase()) {
                symbol = '';
              }

              final numeric = NumberFormat.currency(
                locale: currencyLocale,
                name: code,
                symbol: '',
                decimalDigits: decimalDigits,
              ).format(amount).trim();

              if (symbol.isEmpty) return '$numeric $code';
              return '$symbol$numeric $code';
            } catch (_) {
              final n = NumberFormat('#,##0.00', currencyLocale).format(amount);
              return '$n $code';
            }
          })
          .whereType<String>()
          .toList(growable: false);
      if (currencyEntries.isEmpty) return fmtInt(0);
      final combined = currencyEntries.join(' • ');
      return '\u2066$combined\u2069';
    }

    Widget metricCard({
      required String labelKey,
      required String value,
      required IconData icon,
      required Color accent,
      VoidCallback? onTap,
    }) {
      final scheme = Theme.of(context).colorScheme;
      final surface = scheme.surface;
      final bg = Color.alphaBlend(accent.withAlpha(26), surface);
      return Card(
        color: bg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: accent.withAlpha(56)),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const iconSize = 34.0;
              const normalVPad = 12.0;
              const tightVPad = 8.0;
              final innerHeightWithNormalPad =
                  constraints.maxHeight - (normalVPad * 2);
              final useCompactLayout =
                  innerHeightWithNormalPad < (iconSize + 12);

              final vPad = useCompactLayout ? tightVPad : normalVPad;
              final labelStyle = useCompactLayout
                  ? Theme.of(context).textTheme.labelMedium
                  : Theme.of(context).textTheme.labelLarge;
              final valueStyle = (useCompactLayout
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.headlineSmall)
                  ?.copyWith(fontWeight: FontWeight.w700);

              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: vPad,
                ),
                child: Row(
                  children: [
                    Container(
                      width: iconSize,
                      height: iconSize,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(41),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 18, color: accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: useCompactLayout
                          ? Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l10n.getString(labelKey),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.start,
                                    style: labelStyle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(value, style: valueStyle),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.max,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Text(
                                      l10n.getString(labelKey),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.start,
                                      style: labelStyle,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 1,
                                  child: Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: AlignmentDirectional.centerStart,
                                      child: Text(value, style: valueStyle),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    Widget sectionCard({
      required String titleKey,
      required Widget child,
    }) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.getString(titleKey),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('adminNavDashboard'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: '24h',
                    label: Text(l10n.getString('adminDashboardWindow24h')),
                  ),
                  ButtonSegment(
                    value: '7d',
                    label: Text(l10n.getString('adminDashboardWindow7d')),
                  ),
                ],
                selected: {_window},
                onSelectionChanged: (value) {
                  final next = value.isEmpty ? '24h' : value.first;
                  if (next == _window) return;
                  setState(() {
                    _window = next;
                  });
                  unawaited(_load(force: false));
                },
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.getString('generalRefresh')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (generatedAt != null)
            Text(
              l10n
                  .getString('adminDashboardLastUpdated')
                  .replaceAll('{time}', _formatAdminDateTime(l10n, generatedAt)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                Builder(
                  builder: (context) {
                    final size = MediaQuery.sizeOf(context);
                    final w = size.width;
                    final h = size.height;
                    final isPhone = size.shortestSide < 600;
                    final isPortrait = h >= w;

                    int columns;
                    if (isPhone && isPortrait) {
                      columns = 2;
                    } else {
                      final minTileWidth = isPhone ? 170.0 : 240.0;
                      final estimated = ((w + 12) / (minTileWidth + 12)).floor();
                      columns = estimated.clamp(2, 4);
                    }

                    final tileExtent = isPhone ? 92.0 : 96.0;
                    final onlineUsers = _toInt(engagement['online_users']);
                    final visibleUsers = _toInt(
                      engagement['visible_users'] ?? engagement['nearby_users_10km'],
                    );
                    final matchesCreated = _toInt(engagement['matches_created']);
                    final messagesSent = _toInt(engagement['messages_sent']);
                    final newUsers = _toInt(engagement['new_users']);
                    final activeMatches = _toInt(engagement['active_matches']);
                    final tiles = [
                      metricCard(
                        labelKey: 'adminDashboardOnlineUsers',
                        value: fmtInt(onlineUsers),
                        icon: Icons.wifi_tethering,
                        accent: Colors.green,
                        onTap: onlineUsers > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardOnlineUsers',
                                  metric: 'online_users',
                                )
                            : null,
                      ),
                      metricCard(
                        labelKey: 'adminDashboardVisibleUsers',
                        value: fmtInt(visibleUsers),
                        icon: Icons.visibility,
                        accent: Colors.indigo,
                        onTap: visibleUsers > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardVisibleUsers',
                                  metric: 'visible_users',
                                )
                            : null,
                      ),
                      metricCard(
                        labelKey: 'adminDashboardMatchesCreated',
                        value: fmtInt(matchesCreated),
                        icon: Icons.favorite,
                        accent: Colors.pink,
                        onTap: matchesCreated > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardMatchesCreated',
                                  metric: 'matches_created',
                                )
                            : null,
                      ),
                      metricCard(
                        labelKey: 'adminDashboardMessagesSent',
                        value: fmtInt(messagesSent),
                        icon: Icons.chat_bubble,
                        accent: Colors.blue,
                        onTap: messagesSent > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardMessagesSent',
                                  metric: 'messages_sent',
                                )
                            : null,
                      ),
                      metricCard(
                        labelKey: 'adminDashboardNewUsers',
                        value: fmtInt(newUsers),
                        icon: Icons.person_add,
                        accent: Colors.teal,
                        onTap: newUsers > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardNewUsers',
                                  metric: 'new_users',
                                )
                            : null,
                      ),
                      metricCard(
                        labelKey: 'adminDashboardActiveMatches',
                        value: fmtInt(activeMatches),
                        icon: Icons.bolt,
                        accent: Colors.orange,
                        onTap: activeMatches > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardActiveMatches',
                                  metric: 'active_matches',
                                )
                            : null,
                      ),
                    ];

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: tileExtent,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemCount: tiles.length,
                      itemBuilder: (context, index) => tiles[index],
                    );
                  },
                ),
                const SizedBox(height: 12),
                sectionCard(
                  titleKey: 'adminDashboardEngagement',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n
                            .getString('adminDashboardSeriesCaption')
                            .replaceAll('{window}', l10n.getString(windowLabelKey)),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.getString(barsKey),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n
                            .getString('adminDashboardSeriesExplanation')
                            .replaceAll('{bucket}', l10n.getString(bucketKey)),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (MediaQuery.sizeOf(context).width < 600) ...[
                        const SizedBox(height: 4),
                        Text(
                          l10n.getString('adminDashboardSeriesScrollHint'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      _AdminSparkBars(
                        values: seriesInts('matches'),
                        color: Theme.of(context).colorScheme.primary,
                        label: l10n.getString('adminDashboardMatchesCreated'),
                        oldestLabel: l10n.getString('adminDashboardSeriesOldest'),
                        newestLabel: l10n.getString('adminDashboardSeriesNewest'),
                        bucketStarts: bucketStarts,
                        bucketWindow: _window,
                        tooltipTemplate: l10n.getString('adminDashboardSeriesTooltip'),
                        l10n: l10n,
                      ),
                      const SizedBox(height: 12),
                      _AdminSparkBars(
                        values: seriesInts('messages'),
                        color: Theme.of(context).colorScheme.tertiary,
                        label: l10n.getString('adminDashboardMessagesSent'),
                        oldestLabel: l10n.getString('adminDashboardSeriesOldest'),
                        newestLabel: l10n.getString('adminDashboardSeriesNewest'),
                        bucketStarts: bucketStarts,
                        bucketWindow: _window,
                        tooltipTemplate: l10n.getString('adminDashboardSeriesTooltip'),
                        l10n: l10n,
                      ),
                      const SizedBox(height: 12),
                      _AdminSparkBars(
                        values: seriesInts('signups'),
                        color: Theme.of(context).colorScheme.secondary,
                        label: l10n.getString('adminDashboardNewUsers'),
                        oldestLabel: l10n.getString('adminDashboardSeriesOldest'),
                        newestLabel: l10n.getString('adminDashboardSeriesNewest'),
                        bucketStarts: bucketStarts,
                        bucketWindow: _window,
                        tooltipTemplate: l10n.getString('adminDashboardSeriesTooltip'),
                        l10n: l10n,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                sectionCard(
                  titleKey: 'adminDashboardOperations',
                  child: Column(
                    children: [
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardVerificationPending'),
                        value: fmtInt(operations['verification_pending']),
                        onTap: _toInt(operations['verification_pending']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardVerificationPending',
                                  metric: 'verification_pending',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardVerificationAnalyzing'),
                        value: fmtInt(operations['verification_analyzing']),
                        onTap: _toInt(operations['verification_analyzing']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardVerificationAnalyzing',
                                  metric: 'verification_analyzing',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardProfileEditsPending'),
                        value: fmtInt(operations['profile_edits_pending']),
                        onTap: _toInt(operations['profile_edits_pending']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardProfileEditsPending',
                                  metric: 'profile_edits_pending',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardBroadcastsDraft'),
                        value: fmtInt(operations['broadcasts_draft']),
                        onTap: _toInt(operations['broadcasts_draft']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardBroadcastsDraft',
                                  metric: 'broadcasts_draft',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardBroadcastsScheduled'),
                        value: fmtInt(operations['broadcasts_scheduled']),
                        onTap: _toInt(operations['broadcasts_scheduled']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardBroadcastsScheduled',
                                  metric: 'broadcasts_scheduled',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardNotificationsPending'),
                        value: fmtInt(operations['notifications_pending']),
                        onTap: _toInt(operations['notifications_pending']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardNotificationsPending',
                                  metric: 'notifications_pending',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardNotificationsFailed'),
                        value: fmtInt(operations['notifications_failed']),
                        onTap: _toInt(operations['notifications_failed']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardNotificationsFailed',
                                  metric: 'notifications_failed',
                                )
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                sectionCard(
                  titleKey: 'adminDashboardRevenue',
                  child: Column(
                    children: [
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardEarnings'),
                        value: formatEarnings(earningsByCurrency),
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardPaidActiveUsers'),
                        value: fmtInt(revenue['paid_active_users']),
                        onTap: _toInt(revenue['paid_active_users']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardPaidActiveUsers',
                                  metric: 'paid_active_users',
                                )
                            : null,
                      ),
                      _AdminKeyValueRow(
                        label: l10n.getString('adminDashboardPaidExpiring7d'),
                        value: fmtInt(revenue['paid_expiring_7d']),
                        onTap: _toInt(revenue['paid_expiring_7d']) > 0
                            ? () => openDrilldown(
                                  titleKey: 'adminDashboardPaidExpiring7d',
                                  metric: 'paid_expiring_7d',
                                )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardPaidByTier'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: paidByTier.entries
                            .map(
                              (e) {
                                final count = _toInt(e.value);
                                return ActionChip(
                                  label: Text('${e.key}: ${fmtInt(count)}'),
                                  onPressed: count > 0
                                      ? () => openDrilldown(
                                            titleKey: 'adminDashboardPaidByTier',
                                            metric: 'paid_by_tier',
                                            param: e.key,
                                          )
                                      : null,
                                );
                              },
                            )
                            .toList(growable: false),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                sectionCard(
                  titleKey: 'adminDashboardAI',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardAIUsageTitle'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (aiUsage.isEmpty)
                        Text(l10n.getString('adminDashboardAIUsageEmpty'))
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIProvider')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIModel')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAITask')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardAICalls')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardAIFailures')),
                              ),
                            ],
                            rows: aiUsage.map((row) {
                              final provider = (row['provider'] ?? '').toString();
                              final model = (row['model'] ?? '').toString();
                              final task = (row['task'] ?? '').toString();
                              final calls = _toInt(row['calls']);
                              final failures = _toInt(row['failures']);
                              final param = '$provider|$model|$task';
                              return DataRow(
                                cells: [
                                  DataCell(Text(provider)),
                                  DataCell(Text(model)),
                                  DataCell(Text(task)),
                                  DataCell(
                                    Text(fmtInt(calls)),
                                    onTap: calls > 0
                                        ? () => openDrilldown(
                                              titleKey:
                                                  'adminDashboardAIUsageTitle',
                                              metric: 'ai_usage',
                                              param: param,
                                            )
                                        : null,
                                  ),
                                  DataCell(
                                    Text(fmtInt(failures)),
                                    onTap: failures > 0
                                        ? () => openDrilldown(
                                              titleKey:
                                                  'adminDashboardAIUsageTitle',
                                              metric: 'ai_usage',
                                              param: param,
                                            )
                                        : null,
                                  ),
                                ],
                              );
                            }).toList(growable: false),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardAIQuotaTitle'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (aiQuotaUpdatedAt != null)
                        _AdminKeyValueRow(
                          label: l10n.getString('adminDashboardAIQuotaUpdatedAt'),
                          value: _formatAdminDateTime(l10n, aiQuotaUpdatedAt),
                        ),
                      if (aiQuotaProviders.isEmpty)
                        Text(l10n.getString('adminDashboardAIQuotaEmpty'))
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIProvider')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIQuotaMetric')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIQuotaWindow')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardAIQuotaUsed')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardAIQuotaLimit')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardAIQuotaPercent')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardAIQuotaStatus')),
                              ),
                            ],
                            rows: aiQuotaProviders.expand((pRow) {
                              final providerRaw = (pRow['provider'] ?? '').toString();
                              final provider = aiProviderLabel(providerRaw);
                              final metrics = decodeListOfMaps(pRow['metrics']);
                              return metrics.map((mRow) {
                                final metric = (mRow['metric'] ?? '').toString();
                                final window = aiQuotaWindowLabel((mRow['window'] ?? '').toString());
                                final used = (mRow['used'] as num?)?.toDouble() ??
                                    double.tryParse((mRow['used'] ?? '').toString());
                                final limit = (mRow['limit'] as num?)?.toDouble() ??
                                    double.tryParse((mRow['limit'] ?? '').toString());
                                final unit = (mRow['unit'] ?? '').toString();
                                final status = aiQuotaStatusLabel((mRow['status'] ?? '').toString());
                                final percent = (used != null && limit != null && limit > 0)
                                    ? '${(used / limit * 100).round()}%'
                                    : '';
                                return DataRow(
                                  cells: [
                                    DataCell(Text(provider)),
                                    DataCell(
                                      SizedBox(
                                        width: 260,
                                        child: Text(
                                          metric,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    DataCell(Text(window)),
                                    DataCell(
                                      Text(
                                        used == null ? '' : '${fmtNum(used)} ${unit.trim()}'.trim(),
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        limit == null ? '' : '${fmtNum(limit)} ${unit.trim()}'.trim(),
                                      ),
                                    ),
                                    DataCell(Text(percent)),
                                    DataCell(Text(status)),
                                  ],
                                );
                              });
                            }).toList(growable: false),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardAIRecentErrorsTitle'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (aiRecentErrors.isEmpty)
                        Text(l10n.getString('adminDashboardNoRecentErrors'))
                      else
                        Column(
                          children: aiRecentErrors.map((row) {
                            final timeRaw = (row['t'] ?? '').toString();
                            final when = DateTime.tryParse(timeRaw);
                            final functionName = (row['function'] ?? '').toString();
                            final provider = (row['provider'] ?? '').toString();
                            final model = (row['model'] ?? '').toString();
                            final task = (row['task'] ?? '').toString();
                            final status = (row['http_status'] ?? '').toString();
                            final errorType = (row['error_type'] ?? '').toString();
                            final errorMessage = (row['error_message'] ?? '').toString();
                            final titleParts = <String>[
                              if (when != null) _formatAdminDateTime(l10n, when),
                              if (functionName.isNotEmpty) functionName,
                              if (provider.isNotEmpty) provider,
                              if (model.isNotEmpty) model,
                              if (task.isNotEmpty) task,
                              if (status.isNotEmpty) status,
                            ];
                            final title = titleParts.join(' • ');
                            final subtitleParts = <String>[
                              if (errorType.isNotEmpty) errorType,
                              if (errorMessage.isNotEmpty) errorMessage,
                            ];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: subtitleParts.isEmpty
                                  ? null
                                  : Text(
                                      subtitleParts.join('\n'),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            );
                          }).toList(growable: false),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                sectionCard(
                  titleKey: 'adminDashboardEdgeFunctions',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardEdgeFunctionsUsageTitle'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (edgeUsage.isEmpty)
                        Text(l10n.getString('adminDashboardEdgeFunctionsUsageEmpty'))
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardEdgeFunctionName')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardEdgeFunctionCalls')),
                              ),
                              DataColumn(
                                numeric: true,
                                label: Text(l10n.getString('adminDashboardEdgeFunctionFailures')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminDashboardEdgeFunctionLastErrorAt')),
                              ),
                            ],
                            rows: edgeUsage.map((row) {
                              final name = (row['function'] ?? row['function_name'] ?? '').toString();
                              final calls = _toInt(row['calls']);
                              final failures = _toInt(row['failures']);
                              final lastErrorAtRaw = (row['last_error_at'] ?? '').toString();
                              final lastErrorAt = DateTime.tryParse(lastErrorAtRaw);
                              return DataRow(
                                cells: [
                                  DataCell(Text(name)),
                                  DataCell(
                                    Text(fmtInt(calls)),
                                    onTap: calls > 0
                                        ? () => openDrilldown(
                                              titleKey:
                                                  'adminDashboardEdgeFunctionsUsageTitle',
                                              metric: 'edge_function_usage',
                                              param: name,
                                            )
                                        : null,
                                  ),
                                  DataCell(
                                    Text(fmtInt(failures)),
                                    onTap: failures > 0
                                        ? () => openDrilldown(
                                              titleKey:
                                                  'adminDashboardEdgeFunctionsUsageTitle',
                                              metric: 'edge_function_usage',
                                              param: name,
                                            )
                                        : null,
                                  ),
                                  DataCell(
                                    Text(lastErrorAt == null ? '' : _formatAdminDateTime(l10n, lastErrorAt)),
                                  ),
                                ],
                              );
                            }).toList(growable: false),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10n.getString('adminDashboardEdgeFunctionsRecentErrorsTitle'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (edgeRecentErrors.isEmpty)
                        Text(l10n.getString('adminDashboardNoRecentErrors'))
                      else
                        Column(
                          children: edgeRecentErrors.map((row) {
                            final timeRaw = (row['t'] ?? '').toString();
                            final when = DateTime.tryParse(timeRaw);
                            final functionName = (row['function'] ?? row['function_name'] ?? '').toString();
                            final status = (row['http_status'] ?? '').toString();
                            final errorType = (row['error_type'] ?? '').toString();
                            final errorMessage = (row['error_message'] ?? '').toString();
                            final titleParts = <String>[
                              if (when != null) _formatAdminDateTime(l10n, when),
                              if (functionName.isNotEmpty) functionName,
                              if (status.isNotEmpty) status,
                            ];
                            final title = titleParts.join(' • ');
                            final subtitleParts = <String>[
                              if (errorType.isNotEmpty) errorType,
                              if (errorMessage.isNotEmpty) errorMessage,
                            ];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: subtitleParts.isEmpty
                                  ? null
                                  : Text(
                                      subtitleParts.join('\n'),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            );
                          }).toList(growable: false),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminDrilldownColumn {
  final String key;
  final String labelKey;
  final bool numeric;

  const _AdminDrilldownColumn({
    required this.key,
    required this.labelKey,
    this.numeric = false,
  });
}

class _AdminDashboardDrilldownScreen extends ConsumerStatefulWidget {
  final String titleKey;
  final String window;
  final String metric;
  final String? param;

  const _AdminDashboardDrilldownScreen({
    required this.titleKey,
    required this.window,
    required this.metric,
    this.param,
  });

  @override
  ConsumerState<_AdminDashboardDrilldownScreen> createState() =>
      _AdminDashboardDrilldownScreenState();
}

class _AdminDashboardDrilldownScreenState
    extends ConsumerState<_AdminDashboardDrilldownScreen> {
  static const _pageSize = 200;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  String? _errorKey;
  int _offset = 0;
  List<Map<String, dynamic>> _rows = const [];

  List<Map<String, dynamic>> _decodeListOfMaps(Object? raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  Future<void> _load({required bool more}) async {
    if (more && (!_hasMore || _isLoadingMore)) return;
    if (!more && _isLoading) return;

    if (!mounted) return;
    setState(() {
      if (more) {
        _isLoadingMore = true;
      } else {
        _isLoading = true;
        _errorKey = null;
        _offset = 0;
        _rows = const [];
      }
    });

    try {
      final nextOffset = more ? _offset : 0;
      final raw = await Supabase.instance.client
          .rpc('admin_get_dashboard_drilldown', params: {
        'p_window': widget.window,
        'p_metric': widget.metric,
        'p_param': widget.param,
        'p_limit': _pageSize,
        'p_offset': nextOffset,
      }).timeout(const Duration(seconds: 20));

      final map = (raw is Map) ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final rows = _decodeListOfMaps(map['rows']);
      final hasMore = map['has_more'] == true;

      if (!mounted) return;
      setState(() {
        _hasMore = hasMore;
        _offset = nextOffset + rows.length;
        if (more) {
          _rows = [..._rows, ...rows];
        } else {
          _rows = rows;
        }
        _errorKey = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorKey = 'adminDrilldownLoadFailed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
        });
      }
    }
  }

  List<_AdminDrilldownColumn> _columnsForMetric(String metric) {
    switch (metric) {
      case 'online_users':
      case 'visible_users':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(
            key: 'last_activity_at',
            labelKey: 'adminDrilldownLastActivity',
          ),
        ];
      case 'new_users':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(key: 'created_at', labelKey: 'adminDrilldownCreatedAt'),
        ];
      case 'messages_sent':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(
            key: 'messages',
            labelKey: 'adminDrilldownMessages',
            numeric: true,
          ),
        ];
      case 'matches_created':
        return const [
          _AdminDrilldownColumn(key: 'user1_name', labelKey: 'adminDrilldownUserA'),
          _AdminDrilldownColumn(key: 'user2_name', labelKey: 'adminDrilldownUserB'),
          _AdminDrilldownColumn(key: 'matched_at', labelKey: 'adminDrilldownMatchedAt'),
          _AdminDrilldownColumn(key: 'basis', labelKey: 'adminDrilldownBasis'),
          _AdminDrilldownColumn(key: 'matched_intent', labelKey: 'adminDrilldownSharedIntent'),
          _AdminDrilldownColumn(key: 'event_name', labelKey: 'adminDrilldownEvent'),
        ];
      case 'active_matches':
        return const [
          _AdminDrilldownColumn(key: 'user1_name', labelKey: 'adminDrilldownUserA'),
          _AdminDrilldownColumn(key: 'user2_name', labelKey: 'adminDrilldownUserB'),
          _AdminDrilldownColumn(key: 'matched_at', labelKey: 'adminDrilldownMatchedAt'),
          _AdminDrilldownColumn(
            key: 'last_activity_at',
            labelKey: 'adminDrilldownLastActivity',
          ),
          _AdminDrilldownColumn(key: 'basis', labelKey: 'adminDrilldownBasis'),
          _AdminDrilldownColumn(key: 'matched_intent', labelKey: 'adminDrilldownSharedIntent'),
          _AdminDrilldownColumn(key: 'event_name', labelKey: 'adminDrilldownEvent'),
        ];
      case 'verification_pending':
      case 'verification_analyzing':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(
            key: 'verification_submitted_at',
            labelKey: 'adminDrilldownSubmittedAt',
          ),
        ];
      case 'profile_edits_pending':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(key: 'created_at', labelKey: 'adminDrilldownCreatedAt'),
        ];
      case 'broadcasts_draft':
      case 'broadcasts_scheduled':
        return const [
          _AdminDrilldownColumn(key: 'title', labelKey: 'adminDrilldownTitle'),
          _AdminDrilldownColumn(key: 'status', labelKey: 'adminDrilldownStatus'),
          _AdminDrilldownColumn(
            key: 'scheduled_at',
            labelKey: 'adminDrilldownScheduledAt',
          ),
          _AdminDrilldownColumn(key: 'created_at', labelKey: 'adminDrilldownCreatedAt'),
        ];
      case 'notifications_pending':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'title', labelKey: 'adminDrilldownTitle'),
          _AdminDrilldownColumn(key: 'status', labelKey: 'adminDrilldownStatus'),
          _AdminDrilldownColumn(
            key: 'attempts',
            labelKey: 'adminDrilldownAttempts',
            numeric: true,
          ),
          _AdminDrilldownColumn(
            key: 'created_at',
            labelKey: 'adminDrilldownCreatedAt',
          ),
        ];
      case 'notifications_failed':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'title', labelKey: 'adminDrilldownTitle'),
          _AdminDrilldownColumn(key: 'status', labelKey: 'adminDrilldownStatus'),
          _AdminDrilldownColumn(
            key: 'attempts',
            labelKey: 'adminDrilldownAttempts',
            numeric: true,
          ),
          _AdminDrilldownColumn(
            key: 'failure_reason',
            labelKey: 'adminDrilldownFailureReason',
          ),
          _AdminDrilldownColumn(
            key: 'created_at',
            labelKey: 'adminDrilldownCreatedAt',
          ),
        ];
      case 'paid_active_users':
      case 'paid_expiring_7d':
      case 'paid_by_tier':
        return const [
          _AdminDrilldownColumn(key: 'user_name', labelKey: 'adminDrilldownUser'),
          _AdminDrilldownColumn(key: 'user_id', labelKey: 'adminDrilldownUserId'),
          _AdminDrilldownColumn(
            key: 'subscription_tier',
            labelKey: 'adminDrilldownSubscriptionTier',
          ),
          _AdminDrilldownColumn(
            key: 'earnings',
            labelKey: 'adminDashboardEarnings',
          ),
          _AdminDrilldownColumn(
            key: 'subscription_expires_at',
            labelKey: 'adminDrilldownExpiresAt',
          ),
        ];
      case 'edge_function_usage':
        return const [
          _AdminDrilldownColumn(key: 'function_name', labelKey: 'adminDrilldownFunction'),
          _AdminDrilldownColumn(key: 'invoked_at', labelKey: 'adminDrilldownInvokedAt'),
          _AdminDrilldownColumn(key: 'success', labelKey: 'adminDrilldownSuccess'),
          _AdminDrilldownColumn(
            key: 'http_status',
            labelKey: 'adminDrilldownHttpStatus',
            numeric: true,
          ),
          _AdminDrilldownColumn(
            key: 'duration_ms',
            labelKey: 'adminDrilldownDurationMs',
            numeric: true,
          ),
          _AdminDrilldownColumn(key: 'error_type', labelKey: 'adminDrilldownErrorType'),
          _AdminDrilldownColumn(key: 'error_message', labelKey: 'adminDrilldownErrorMessage'),
          _AdminDrilldownColumn(key: 'ai_used', labelKey: 'adminDrilldownAIUsed'),
          _AdminDrilldownColumn(key: 'ai_provider', labelKey: 'adminDrilldownProvider'),
          _AdminDrilldownColumn(key: 'ai_model', labelKey: 'adminDrilldownModel'),
          _AdminDrilldownColumn(key: 'ai_task', labelKey: 'adminDrilldownTask'),
        ];
      case 'ai_usage':
        return const [
          _AdminDrilldownColumn(key: 'invoked_at', labelKey: 'adminDrilldownInvokedAt'),
          _AdminDrilldownColumn(key: 'function_name', labelKey: 'adminDrilldownFunction'),
          _AdminDrilldownColumn(key: 'ai_provider', labelKey: 'adminDrilldownProvider'),
          _AdminDrilldownColumn(key: 'ai_model', labelKey: 'adminDrilldownModel'),
          _AdminDrilldownColumn(key: 'ai_task', labelKey: 'adminDrilldownTask'),
          _AdminDrilldownColumn(key: 'success', labelKey: 'adminDrilldownSuccess'),
          _AdminDrilldownColumn(
            key: 'http_status',
            labelKey: 'adminDrilldownHttpStatus',
            numeric: true,
          ),
          _AdminDrilldownColumn(
            key: 'duration_ms',
            labelKey: 'adminDrilldownDurationMs',
            numeric: true,
          ),
          _AdminDrilldownColumn(key: 'error_type', labelKey: 'adminDrilldownErrorType'),
          _AdminDrilldownColumn(key: 'error_message', labelKey: 'adminDrilldownErrorMessage'),
        ];
    }

    return const [
      _AdminDrilldownColumn(key: 'id', labelKey: 'adminDrilldownUserId'),
    ];
  }

  Widget _cellValue(LocalizationState l10n, String metric, String key, Object? raw) {
    if (raw == null) return const SizedBox.shrink();
    if (raw is bool) {
      return raw
          ? const Icon(Icons.check, size: 18)
          : const Icon(Icons.close, size: 18);
    }
    if (key == 'earnings') {
      Map<String, dynamic> map = const <String, dynamic>{};
      if (raw is Map) {
        map = Map<String, dynamic>.from(raw);
      } else if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            map = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      final locale = l10n.locale.languageCode.trim();
      final safeLocale = locale.isEmpty ? 'en' : locale;
      final zero = NumberFormat.compact(locale: safeLocale).format(0);
      if (map.isEmpty) return Text(zero);
      final parts = map.entries
          .map((e) {
            final code = e.key.toString().trim();
            final v = e.value;
            final amount = (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0;
            if (code.isEmpty) return null;
            try {
              String symbol = '';
              try {
                symbol = NumberFormat.simpleCurrency(locale: safeLocale, name: code).currencySymbol;
              } catch (_) {}

              if (symbol.trim().toUpperCase() == code.toUpperCase()) {
                symbol = '';
              }

              final numeric = NumberFormat.currency(
                locale: safeLocale,
                name: code,
                symbol: '',
              ).format(amount).trim();

              if (symbol.isEmpty) return '$numeric $code';
              return '$symbol$numeric $code';
            } catch (_) {
              final n = NumberFormat('#,##0.00', safeLocale).format(amount);
              return '$n $code';
            }
          })
          .whereType<String>()
          .toList(growable: false);

      if (parts.isEmpty) return Text(zero);
      return Text(parts.join(' • '), maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    if (key == 'user_name' ||
        key == 'user1_name' ||
        key == 'user2_name' ||
        key == 'reviewer_name') {
      final s = raw.toString();
      return Text(maskUserDisplayName(s), maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    if (key == 'basis' && raw is List) {
      String labelFor(String code) {
        switch (code) {
          case 'proximity':
            return l10n.getString('adminDrilldownBasisProximity');
          case 'event':
            return l10n.getString('adminDrilldownBasisEvent');
          case 'shared_intent':
            return l10n.getString('adminDrilldownBasisSharedIntent');
          case 'shared_interest':
            return l10n.getString('adminDrilldownBasisSharedInterest');
          default:
            return l10n.getString('adminDrilldownUnknown');
        }
      }

      final labels = raw
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .map(labelFor)
          .toList(growable: false);
      if (labels.isEmpty) return const SizedBox.shrink();
      return Text(labels.join(', '));
    }
    final s = raw.toString();
    if (key.endsWith('_at') || key.endsWith('_at_utc')) {
      final dt = DateTime.tryParse(s);
      if (dt != null) {
        return Text(_formatAdminDateTime(l10n, dt));
      }
    }
    if (raw is num) return Text(raw.toString());
    return Text(s, maxLines: 2, overflow: TextOverflow.ellipsis);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load(more: false));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final displayParam = () {
      final raw = widget.param;
      if (raw == null) return null;
      if (widget.metric == 'ai_usage' && raw.contains('|')) {
        final parts = raw
            .split('|')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        if (parts.isNotEmpty) return parts.join(' • ');
      }
      return raw;
    }();
    final title = displayParam == null
        ? l10n.getString(widget.titleKey)
        : '${l10n.getString(widget.titleKey)}: $displayParam';
    final rows = _rows;
    final columns = _columnsForMetric(widget.metric);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: l10n.getString('generalRefresh'),
            onPressed: () => _load(more: false),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errorKey != null)
                Text(l10n.getString(_errorKey!))
              else if (_isLoading)
                Expanded(
                  child: Center(
                    child: Text(l10n.getString('generalLoading')),
                  ),
                )
              else if (rows.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(l10n.getString('adminDrilldownEmpty')),
                  ),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: columns
                            .map(
                              (c) => DataColumn(
                                numeric: c.numeric,
                                label: Text(l10n.getString(c.labelKey)),
                              ),
                            )
                            .toList(growable: false),
                        rows: rows
                            .map(
                              (row) => DataRow(
                                cells: columns
                                    .map(
                                      (c) => DataCell(
                                        _cellValue(
                                          l10n,
                                          widget.metric,
                                          c.key,
                                          row[c.key],
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ),
                ),
              if (_errorKey == null && !_isLoading)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _hasMore
                              ? () => _load(more: true)
                              : null,
                          child: _isLoadingMore
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(l10n.getString('generalLoadMore')),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminKeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _AdminKeyValueRow({
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ],
      ),
    );

    final callback = onTap;
    if (callback == null) return row;

    return InkWell(
      onTap: callback,
      borderRadius: BorderRadius.circular(10),
      child: row,
    );
  }
}

class _AdminSparkBars extends StatelessWidget {
  final List<int> values;
  final Color color;
  final String label;
  final String? oldestLabel;
  final String? newestLabel;
  final List<DateTime>? bucketStarts;
  final String? bucketWindow;
  final String? tooltipTemplate;
  final LocalizationState l10n;

  const _AdminSparkBars({
    required this.values,
    required this.color,
    required this.label,
    required this.l10n,
    this.oldestLabel,
    this.newestLabel,
    this.bucketStarts,
    this.bucketWindow,
    this.tooltipTemplate,
  });

  String _bucketRange(DateTime bucketStartUtc, String window) {
    final start = bucketStartUtc.toLocal();
    if (window == '24h') {
      final fmt = DateFormat.Hm(l10n.locale.languageCode);
      final end = start.add(const Duration(hours: 1));
      return '${fmt.format(start)}–${fmt.format(end)}';
    }
    final fmt = DateFormat.Md(l10n.locale.languageCode);
    return fmt.format(start);
  }

  String _bucketXAxisLabel(DateTime bucketStartUtc, String window) {
    final start = bucketStartUtc.toLocal();
    if (window == '24h') {
      final fmt = DateFormat.Hm(l10n.locale.languageCode);
      return fmt.format(start);
    }
    final fmt = DateFormat.Md(l10n.locale.languageCode);
    return fmt.format(start);
  }

  @override
  Widget build(BuildContext context) {
    final maxValue = values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b);
    final barCount = values.isEmpty ? 1 : values.length;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final oldest = oldestLabel ?? '';
    final newest = newestLabel ?? '';
    final starts = bucketStarts;
    final window = bucketWindow ?? '24h';
    final template = tooltipTemplate ?? '{label}: {value} ({range})';
    final barWidth = window == '24h' ? 46.0 : 64.0;
    final labelLines = 1;
    final labelHeight = 16.0;
    final chartHeight = 96.0 + 6.0 + labelHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: chartHeight,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: !isRtl,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: barWidth * barCount),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < barCount; i++)
                    SizedBox(
                      width: barWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Tooltip(
                              message: () {
                                final value = values.isEmpty ? 0 : values[i];
                                final range = (starts != null &&
                                        starts.length == values.length &&
                                        i < starts.length)
                                    ? _bucketRange(starts[i], window)
                                    : '';
                                return template
                                    .replaceAll('{label}', label)
                                    .replaceAll('{value}', value.toString())
                                    .replaceAll('{range}', range);
                              }(),
                              child: Container(
                                height: (values.isEmpty || maxValue <= 0)
                                    ? 2
                                    : (96 * (values[i] / maxValue))
                                        .clamp(2, 96)
                                        .toDouble(),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              height: labelHeight,
                              child: Center(
                                child: Text(
                                  (starts != null &&
                                          starts.length == values.length &&
                                          i < starts.length)
                                      ? _bucketXAxisLabel(starts[i], window)
                                      : '',
                                  textAlign: TextAlign.center,
                                  maxLines: labelLines,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (oldest.isNotEmpty && newest.isNotEmpty) ...[
          const SizedBox(height: 6),
          DefaultTextStyle(
            style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant) ??
                const TextStyle(),
            child: Row(
              children: [
                Text(isRtl ? newest : oldest),
                const Spacer(),
                Text(isRtl ? oldest : newest),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

enum _TaxonomyEntity {
  intents,
  interests,
}

enum _TaxonomyScope {
  all,
  social,
  business,
}

class _AdminTaxonomyRow {
  final int id;
  final String key;
  final int? parentId;
  final String translationKey;
  final int sortOrder;
  final bool isSocial;
  final bool isBusiness;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const _AdminTaxonomyRow({
    required this.id,
    required this.key,
    required this.parentId,
    required this.translationKey,
    required this.sortOrder,
    required this.isSocial,
    required this.isBusiness,
    required this.createdAt,
    required this.updatedAt,
  });

  static DateTime? _tryDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 't' || s == 'yes' || s == 'y';
  }

  factory _AdminTaxonomyRow.fromRow(Map<String, dynamic> row) {
    final parentRaw = row['parent_id'];
    final parent = parentRaw == null ? null : _toInt(parentRaw);
    return _AdminTaxonomyRow(
      id: _toInt(row['id']),
      key: (row['key'] ?? '').toString(),
      parentId: parent == 0 ? null : parent,
      translationKey: (row['translation_key'] ?? '').toString(),
      sortOrder: _toInt(row['sort_order']),
      isSocial: _toBool(row['is_social']),
      isBusiness: _toBool(row['is_business']),
      createdAt: _tryDate(row['created_at']),
      updatedAt: _tryDate(row['updated_at']),
    );
  }
}

class _IntentsInterestsScreen extends ConsumerStatefulWidget {
  const _IntentsInterestsScreen();

  @override
  ConsumerState<_IntentsInterestsScreen> createState() =>
      _IntentsInterestsScreenState();
}

class _IntentsInterestsScreenState extends ConsumerState<_IntentsInterestsScreen> {
  bool _isLoading = true;
  String? _errorKey;

  _TaxonomyEntity _entity = _TaxonomyEntity.intents;
  _TaxonomyScope _scope = _TaxonomyScope.all;
  String _query = '';

  List<_AdminTaxonomyRow> _intents = const [];
  List<_AdminTaxonomyRow> _interests = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorKey = null;
    });

    try {
      final client = Supabase.instance.client;
      final rpcName = _entity == _TaxonomyEntity.intents
          ? 'admin_list_intents'
          : 'admin_list_interests';
      final raw = await client.rpc(rpcName, params: const <String, dynamic>{});
      final list = raw is List ? raw : const [];
      final rows = List<Map<String, dynamic>>.from(list)
          .map((r) => Map<String, dynamic>.from(r))
          .map(_AdminTaxonomyRow.fromRow)
          .where((r) => r.id != 0 && r.key.isNotEmpty)
          .toList(growable: false);

      rows.sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        return a.key.compareTo(b.key);
      });

      if (!mounted) return;
      setState(() {
        if (_entity == _TaxonomyEntity.intents) {
          _intents = rows;
        } else {
          _interests = rows;
        }
        _isLoading = false;
        _errorKey = null;
      });
    } on PostgrestException catch (e, st) {
      developer.log(
        'taxonomy list PostgREST error',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      final msg = '${e.message} ${e.hint ?? ''} ${e.details ?? ''}';
      final lower = msg.toLowerCase();
      final key = lower.contains('not authorized')
          ? 'adminNotAuthorized'
          : msg.contains('No API key found') || msg.contains('apikey') || msg.contains('No `apikey`')
              ? 'supabaseConfigMissing'
              : lower.contains('could not find the function') ||
                      lower.contains('schema cache') ||
                      lower.contains('pgrst202') ||
                      lower.contains('function') && lower.contains('admin_list_')
                  ? 'adminIntentsInterestsRpcMissing'
                  : 'adminIntentsInterestsLoadFailed';
      setState(() {
        _isLoading = false;
        _errorKey = key;
      });
    } catch (e, st) {
      developer.log(
        'taxonomy list failed',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorKey = 'adminIntentsInterestsLoadFailed';
      });
    }
  }

  List<_AdminTaxonomyRow> _visibleRows(LocalizationState l10n) {
    final rows = _entity == _TaxonomyEntity.intents ? _intents : _interests;
    final q = _query.trim().toLowerCase();

    bool matchesScope(_AdminTaxonomyRow r) {
      return switch (_scope) {
        _TaxonomyScope.all => true,
        _TaxonomyScope.social => r.isSocial,
        _TaxonomyScope.business => r.isBusiness,
      };
    }

    bool matchesQuery(_AdminTaxonomyRow r) {
      if (q.isEmpty) return true;
      final localized = l10n.getString(r.translationKey).toLowerCase();
      return r.key.toLowerCase().contains(q) ||
          r.translationKey.toLowerCase().contains(q) ||
          localized.contains(q);
    }

    return rows
        .where((r) => matchesScope(r) && matchesQuery(r))
        .toList(growable: false);
  }

  Future<void> _upsertRow({
    required _TaxonomyEntity entity,
    _AdminTaxonomyRow? existing,
    int? fixedParentId,
  }) async {
    final l10n = ref.read(localizationProvider);
    final formKey = GlobalKey<FormState>();

    final isEditing = existing != null;
    final keyController = TextEditingController(text: existing?.key ?? '');
    final translationKeyController =
        TextEditingController(text: existing?.translationKey ?? '');
    final sortOrderController =
        TextEditingController(text: (existing?.sortOrder ?? 0).toString());
    final enController = TextEditingController();
    final esController = TextEditingController();
    final heController = TextEditingController();

    var parentId = fixedParentId ?? existing?.parentId;
    var isSocial = existing?.isSocial ?? true;
    var isBusiness = existing?.isBusiness ?? false;

    final rows = entity == _TaxonomyEntity.intents ? _intents : _interests;
    final parents = rows
        .where((r) => r.parentId == null)
        .toList(growable: false)
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        return a.key.compareTo(b.key);
      });

    var isSubmitting = false;

    String titleKey() {
      if (entity == _TaxonomyEntity.intents) {
        return isEditing
            ? 'adminIntentsInterestsEditIntent'
            : 'adminIntentsInterestsAddIntent';
      }
      return isEditing
          ? 'adminIntentsInterestsEditInterest'
          : 'adminIntentsInterestsAddInterest';
    }

    var didLoadText = false;
    var isTextLoading = false;
    var textLoadFailed = false;

    Future<void> loadText(
      NavigatorState dialogNavigator,
      void Function(void Function()) setDialogState,
    ) async {
      final translationKey = translationKeyController.text.trim();
      if (translationKey.isEmpty) return;

      if (!dialogNavigator.mounted) return;
      setDialogState(() {
        isTextLoading = true;
        textLoadFailed = false;
      });

      try {
        final rowsRaw = await Supabase.instance.client
            .from('translations')
            .select('locale, value')
            .eq('key', translationKey)
            .inFilter('locale', const ['en', 'es', 'he'])
            .timeout(const Duration(seconds: 8));

        final rows = List<Map<String, dynamic>>.from(rowsRaw as List);
        final byLocale = <String, String>{};
        for (final r in rows) {
          final locale = (r['locale'] ?? '').toString().trim().toLowerCase();
          final value = (r['value'] ?? '').toString();
          if (locale.isNotEmpty) byLocale[locale] = value;
        }

        if (!dialogNavigator.mounted) return;
        setDialogState(() {
          enController.text = byLocale['en'] ?? '';
          esController.text = byLocale['es'] ?? '';
          heController.text = byLocale['he'] ?? '';
          isTextLoading = false;
          textLoadFailed = false;
        });
      } catch (_) {
        if (!dialogNavigator.mounted) return;
        setDialogState(() {
          isTextLoading = false;
          textLoadFailed = true;
        });
      }
    }

    Future<void> submit(
      BuildContext dialogCtx,
      void Function(void Function()) setDialogState,
    ) async {
      if (!(formKey.currentState?.validate() ?? false)) return;

      final sortOrder = int.tryParse(sortOrderController.text.trim()) ?? 0;
      final key = keyController.text.trim();
      final translationKey = translationKeyController.text.trim();

      if (!dialogCtx.mounted) return;
      setDialogState(() {
        isSubmitting = true;
      });

      try {
        final client = Supabase.instance.client;
        final rpcName = entity == _TaxonomyEntity.intents
            ? 'admin_upsert_intent'
            : 'admin_upsert_interest';
        await client.rpc(
          rpcName,
          params: {
            'p_id': existing?.id,
            'p_key': key,
            'p_parent_id': parentId,
            'p_translation_key': translationKey,
            'p_sort_order': sortOrder,
            'p_is_social': isSocial,
            'p_is_business': isBusiness,
          },
        );

        await client.rpc(
          'admin_bulk_upsert_translations',
          params: {
            'p_items': [
              {'locale': 'en', 'key': translationKey, 'value': enController.text},
              {'locale': 'es', 'key': translationKey, 'value': esController.text},
              {'locale': 'he', 'key': translationKey, 'value': heController.text},
            ],
          },
        );

        final notifier = ref.read(localizationProvider.notifier);
        await notifier.patchTranslationValue(
          locale: 'en',
          key: translationKey,
          value: enController.text,
        );
        await notifier.patchTranslationValue(
          locale: 'es',
          key: translationKey,
          value: esController.text,
        );
        await notifier.patchTranslationValue(
          locale: 'he',
          key: translationKey,
          value: heController.text,
        );

        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
        unawaited(_load(force: true));
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() {
          isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminIntentsInterestsSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!didLoadText) {
            didLoadText = true;
            final dialogNavigator = Navigator.of(ctx);
            Future.microtask(() => loadText(dialogNavigator, setDialogState));
          }

          final parentEnabled = !isEditing && fixedParentId == null;
          return AlertDialog(
            title: Text(l10n.getString(titleKey())),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: keyController,
                        enabled: !isEditing,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsKey'),
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return l10n.getString('adminIntentsInterestsKeyRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: translationKeyController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.getString('adminIntentsInterestsTranslationKey'),
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return l10n
                                .getString('adminIntentsInterestsTranslationKeyRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: sortOrderController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsSortOrder'),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 12),
                      DropdownMenu<int?>(
                        enabled: parentEnabled,
                        initialSelection: parentId,
                        label: Text(l10n.getString('adminIntentsInterestsParent')),
                        dropdownMenuEntries: [
                          DropdownMenuEntry(
                            value: null,
                            label: l10n.getString('adminIntentsInterestsNoParent'),
                          ),
                          ...parents.map(
                            (p) => DropdownMenuEntry(
                              value: p.id,
                              label:
                                  '${l10n.getString(p.translationKey)} (${p.key})',
                            ),
                          ),
                        ],
                        onSelected: parentEnabled
                            ? (v) => setDialogState(() => parentId = v)
                            : null,
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: isSocial,
                        onChanged: (v) => setDialogState(() => isSocial = v ?? false),
                        title: Text(l10n.getString('adminIntentsInterestsIsSocial')),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      CheckboxListTile(
                        value: isBusiness,
                        onChanged: (v) =>
                            setDialogState(() => isBusiness = v ?? false),
                        title: Text(l10n.getString('adminIntentsInterestsIsBusiness')),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.getString('adminIntentsInterestsEditText'),
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.getString('generalRefresh'),
                            onPressed:
                                isTextLoading
                                    ? null
                                    : () => loadText(
                                          Navigator.of(ctx),
                                          setDialogState,
                                        ),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      if (textLoadFailed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            l10n.getString('adminIntentsInterestsLoadFailed'),
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(ctx).colorScheme.error,
                                ),
                          ),
                        ),
                      TextFormField(
                        controller: enController,
                        enabled: !isTextLoading,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleEn'),
                        ),
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: esController,
                        enabled: !isTextLoading,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleEs'),
                        ),
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: heController,
                        enabled: !isTextLoading,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleHe'),
                        ),
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        maxLines: null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              FilledButton(
                onPressed: isSubmitting ? null : () => submit(ctx, setDialogState),
                child: isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('generalSave')),
              ),
            ],
          );
        },
      ),
    );

    _disposeTextControllersLater([
      keyController,
      translationKeyController,
      sortOrderController,
      enController,
      esController,
      heController,
    ]);
  }

  Future<void> _deleteRow({
    required _TaxonomyEntity entity,
    required _AdminTaxonomyRow row,
  }) async {
    final l10n = ref.read(localizationProvider);

    final titleKey = entity == _TaxonomyEntity.intents
        ? 'adminIntentsInterestsDeleteIntentTitle'
        : 'adminIntentsInterestsDeleteInterestTitle';
    final bodyKey = entity == _TaxonomyEntity.intents
        ? 'adminIntentsInterestsDeleteIntentBody'
        : 'adminIntentsInterestsDeleteInterestBody';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString(titleKey)),
        content: Text(
          l10n.getString(bodyKey).replaceAll('{key}', row.key),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final client = Supabase.instance.client;
      final rpcName = entity == _TaxonomyEntity.intents
          ? 'admin_delete_intent'
          : 'admin_delete_interest';
      await client.rpc(rpcName, params: {'p_id': row.id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminIntentsInterestsDeleteFailed'))),
      );
    }
  }

  Future<void> _editTranslationText(_AdminTaxonomyRow row) async {
    final l10n = ref.read(localizationProvider);
    final translationKey = row.translationKey.trim();
    if (translationKey.isEmpty) return;

    final enController = TextEditingController();
    final esController = TextEditingController();
    final heController = TextEditingController();

    var didLoad = false;
    var isLoading = true;
    var loadFailed = false;
    var isSubmitting = false;

    Future<void> load(NavigatorState dialogNavigator, StateSetter setDialogState) async {
      try {
        final rowsRaw = await Supabase.instance.client
            .from('translations')
            .select('locale, value')
            .eq('key', translationKey)
            .inFilter('locale', const ['en', 'es', 'he']);

        final rows = List<Map<String, dynamic>>.from(rowsRaw as List);
        final byLocale = <String, String>{};
        for (final r in rows) {
          final locale = (r['locale'] ?? '').toString().trim().toLowerCase();
          final value = (r['value'] ?? '').toString();
          if (locale.isNotEmpty) byLocale[locale] = value;
        }

        if (!dialogNavigator.mounted) return;
        setDialogState(() {
          enController.text = byLocale['en'] ?? '';
          esController.text = byLocale['es'] ?? '';
          heController.text = byLocale['he'] ?? '';
          isLoading = false;
          loadFailed = false;
        });
      } catch (_) {
        if (!dialogNavigator.mounted) return;
        setDialogState(() {
          isLoading = false;
          loadFailed = true;
        });
      }
    }

    Future<void> submit(BuildContext dialogCtx, StateSetter setDialogState) async {
      if (!dialogCtx.mounted) return;
      setDialogState(() => isSubmitting = true);
      try {
        await Supabase.instance.client.rpc(
          'admin_bulk_upsert_translations',
          params: {
            'p_items': [
              {'locale': 'en', 'key': translationKey, 'value': enController.text},
              {'locale': 'es', 'key': translationKey, 'value': esController.text},
              {'locale': 'he', 'key': translationKey, 'value': heController.text},
            ],
          },
        ).timeout(const Duration(seconds: 20));

        final notifier = ref.read(localizationProvider.notifier);
        await notifier.patchTranslationValue(
          locale: 'en',
          key: translationKey,
          value: enController.text,
        );
        await notifier.patchTranslationValue(
          locale: 'es',
          key: translationKey,
          value: esController.text,
        );
        await notifier.patchTranslationValue(
          locale: 'he',
          key: translationKey,
          value: heController.text,
        );

        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() => isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminIntentsInterestsSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!didLoad) {
            didLoad = true;
            final dialogNavigator = Navigator.of(ctx);
            Future.microtask(() => load(dialogNavigator, setDialogState));
          }

          return AlertDialog(
            title: Text(
              l10n
                  .getString('adminIntentsInterestsEditTextTitle')
                  .replaceAll('{key}', translationKey),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.getString('adminIntentsInterestsTranslationKey'),
                      style: Theme.of(ctx).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(translationKey),
                    const SizedBox(height: 12),
                    if (isLoading)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(l10n.getString('generalLoading')),
                      )
                    else ...[
                      if (loadFailed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            l10n.getString('adminIntentsInterestsLoadFailed'),
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(ctx).colorScheme.error,
                                ),
                          ),
                        ),
                      TextFormField(
                        controller: enController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleEn'),
                        ),
                        minLines: 1,
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: esController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleEs'),
                        ),
                        minLines: 1,
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: heController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminIntentsInterestsLocaleHe'),
                        ),
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        minLines: 1,
                        maxLines: null,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              FilledButton(
                onPressed: (isSubmitting || isLoading)
                    ? null
                    : () => submit(ctx, setDialogState),
                child: isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('generalSave')),
              ),
            ],
          );
        },
      ),
    );

    _disposeTextControllersLater([enController, esController, heController]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final rows = _visibleRows(l10n);

    final parents = rows.where((r) => r.parentId == null).toList(growable: false)
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        return a.key.compareTo(b.key);
      });

    final childrenByParent = <int, List<_AdminTaxonomyRow>>{};
    for (final r in rows) {
      final pid = r.parentId;
      if (pid == null) continue;
      (childrenByParent[pid] ??= <_AdminTaxonomyRow>[]).add(r);
    }
    for (final entry in childrenByParent.entries) {
      entry.value.sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        return a.key.compareTo(b.key);
      });
    }

    Widget body() {
      if (_isLoading) {
        return Center(child: Text(l10n.getString('generalLoading')));
      }
      if (_errorKey != null) {
        return Center(
          child: Text(
            l10n.getString(_errorKey!),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        );
      }
      if (parents.isEmpty) {
        return Center(child: Text(l10n.getString('adminIntentsInterestsEmpty')));
      }

      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          for (final p in parents) ...[
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(
                  Icons.label_important_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  l10n.getString(p.translationKey),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                subtitle: Text(p.key),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'add_child') {
                      await _upsertRow(
                        entity: _entity,
                        fixedParentId: p.id,
                      );
                      return;
                    }
                    if (value == 'edit') {
                      await _upsertRow(entity: _entity, existing: p);
                      return;
                    }
                    if (value == 'edit_text') {
                      await _editTranslationText(p);
                      return;
                    }
                    if (value == 'delete') {
                      await _deleteRow(entity: _entity, row: p);
                      return;
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'add_child',
                      child: Text(l10n.getString('adminIntentsInterestsAddChild')),
                    ),
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(l10n.getString('generalEdit')),
                    ),
                    PopupMenuItem(
                      value: 'edit_text',
                      child: Text(l10n.getString('adminIntentsInterestsEditText')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l10n.getString('generalDelete')),
                    ),
                  ],
                ),
              ),
            ),
            for (final c in childrenByParent[p.id] ?? const <_AdminTaxonomyRow>[])
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16),
                child: Card(
                  child: ListTile(
                    title: Text(
                      l10n.getString(c.translationKey),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(c.key),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') {
                          await _upsertRow(entity: _entity, existing: c);
                          return;
                        }
                        if (value == 'edit_text') {
                          await _editTranslationText(c);
                          return;
                        }
                        if (value == 'delete') {
                          await _deleteRow(entity: _entity, row: c);
                          return;
                        }
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(l10n.getString('generalEdit')),
                        ),
                        PopupMenuItem(
                          value: 'edit_text',
                          child: Text(l10n.getString('adminIntentsInterestsEditText')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(l10n.getString('generalDelete')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      );
    }

    String entityLabel(_TaxonomyEntity e) {
      return switch (e) {
        _TaxonomyEntity.intents => l10n.getString('adminIntentsInterestsTabIntents'),
        _TaxonomyEntity.interests =>
          l10n.getString('adminIntentsInterestsTabInterests'),
      };
    }

    String scopeLabel(_TaxonomyScope s) {
      return switch (s) {
        _TaxonomyScope.all => l10n.getString('adminIntentsInterestsFilterAll'),
        _TaxonomyScope.social =>
          l10n.getString('adminIntentsInterestsFilterSocial'),
        _TaxonomyScope.business =>
          l10n.getString('adminIntentsInterestsFilterBusiness'),
      };
    }

    final addKey = _entity == _TaxonomyEntity.intents
        ? 'adminIntentsInterestsAddIntent'
        : 'adminIntentsInterestsAddInterest';

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 980;
        final padding = EdgeInsets.all(isWide ? 24 : 12);

        return Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    l10n.getString('adminNavIntentsInterests'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  SegmentedButton<_TaxonomyEntity>(
                    segments: [
                      ButtonSegment(
                        value: _TaxonomyEntity.intents,
                        label: Text(entityLabel(_TaxonomyEntity.intents)),
                      ),
                      ButtonSegment(
                        value: _TaxonomyEntity.interests,
                        label: Text(entityLabel(_TaxonomyEntity.interests)),
                      ),
                    ],
                    selected: {_entity},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) return;
                      final next = selection.first;
                      if (next == _entity) return;
                      setState(() {
                        _entity = next;
                        _errorKey = null;
                      });
                      unawaited(_load(force: true));
                    },
                  ),
                  SegmentedButton<_TaxonomyScope>(
                    segments: [
                      ButtonSegment(
                        value: _TaxonomyScope.all,
                        label: Text(scopeLabel(_TaxonomyScope.all)),
                      ),
                      ButtonSegment(
                        value: _TaxonomyScope.social,
                        label: Text(scopeLabel(_TaxonomyScope.social)),
                      ),
                      ButtonSegment(
                        value: _TaxonomyScope.business,
                        label: Text(scopeLabel(_TaxonomyScope.business)),
                      ),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) return;
                      setState(() => _scope = selection.first);
                    },
                  ),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      decoration: InputDecoration(
                        labelText:
                            l10n.getString('adminIntentsInterestsSearchHint'),
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => _upsertRow(entity: _entity),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.getString(addKey)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _load(force: true),
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.getString('generalRefresh')),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: body()),
            ],
          ),
        );
      },
    );
  }
}

class _AdminBroadcastRow {
  final String id;
  final String title;
  final String message;
  final String messageType;
  final String? actionUrl;
  final String actionUrlText;
  final DateTime? scheduledAt;
  final DateTime? sentAt;
  final String status;
  final Map<String, dynamic> filterCriteria;
  final int? targetUserCount;
  final int actualSentCount;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const _AdminBroadcastRow({
    required this.id,
    required this.title,
    required this.message,
    required this.messageType,
    required this.actionUrl,
    required this.actionUrlText,
    required this.scheduledAt,
    required this.sentAt,
    required this.status,
    required this.filterCriteria,
    required this.targetUserCount,
    required this.actualSentCount,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  static DateTime? _tryDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  factory _AdminBroadcastRow.fromRow(Map<String, dynamic> row) {
    final rawCriteria = row['filter_criteria'];
    final criteria = rawCriteria is Map
        ? Map<String, dynamic>.from(rawCriteria)
        : <String, dynamic>{};
    return _AdminBroadcastRow(
      id: (row['id'] ?? '').toString(),
      title: (row['title'] ?? '').toString(),
      message: (row['message'] ?? '').toString(),
      messageType: (row['message_type'] ?? 'info').toString(),
      actionUrl: row['action_url']?.toString(),
      actionUrlText: (row['action_url_text'] ?? '').toString(),
      scheduledAt: _tryDate(row['scheduled_at']),
      sentAt: _tryDate(row['sent_at']),
      status: (row['status'] ?? 'draft').toString(),
      filterCriteria: criteria,
      targetUserCount: row['target_user_count'] as int?,
      actualSentCount: (row['actual_sent_count'] as int?) ?? 0,
      createdBy: row['created_by']?.toString(),
      createdAt: _tryDate(row['created_at']),
      updatedAt: _tryDate(row['updated_at']),
    );
  }
}

class _BroadcastsScreen extends ConsumerStatefulWidget {
  const _BroadcastsScreen();

  @override
  ConsumerState<_BroadcastsScreen> createState() => _BroadcastsScreenState();
}

class _BroadcastsScreenState extends ConsumerState<_BroadcastsScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_AdminBroadcastRow> _rows = const [];

  String _query = '';
  String _status = 'all';
  String _timeFilter = 'all';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    List<Map<String, dynamic>> decodeListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final cacheKey = 'admin_cache:broadcasts:v1';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<List<Map<String, dynamic>>>(
        cacheKey,
        decodeListMap,
      );
      if (!mounted) return;
      if (cached != null) {
        final list = cached.data
            .map((r) => _AdminBroadcastRow.fromRow(r))
            .toList(growable: false);
        setState(() {
          _rows = list;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final rows = await Supabase.instance.client
          .from('admin_broadcasts')
          .select(
            'id, title, message, message_type, action_url, action_url_text, scheduled_at, sent_at, status, filter_criteria, target_user_count, actual_sent_count, created_by, created_at, updated_at',
          )
          .order('created_at', ascending: false)
          .limit(500)
          .timeout(const Duration(seconds: 12));

      final raw = rows
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList(growable: false);
      await _AdminCache.write<List<Map<String, dynamic>>>(
        cacheKey,
        (v) => v,
        raw,
      );

      final list = raw
          .map((r) => _AdminBroadcastRow.fromRow(r))
          .toList(growable: false);

      if (!mounted) return;
      setState(() {
        _rows = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminBroadcastsLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminBroadcastsLoadFailed';
          _isLoading = false;
        });
      }
    }
  }

  String _timeFilterLabel(LocalizationState l10n, String value) {
    return switch (value) {
      'all' => l10n.getString('adminBroadcastsTimeAll'),
      'upcoming' => l10n.getString('adminBroadcastsTimeUpcoming'),
      'past' => l10n.getString('adminBroadcastsTimePast'),
      _ => value,
    };
  }

  String _statusLabel(LocalizationState l10n, String value) {
    return switch (value) {
      'all' => l10n.getString('adminStatusAll'),
      'draft' => l10n.getString('adminBroadcastsStatusDraft'),
      'scheduled' => l10n.getString('adminBroadcastsStatusScheduled'),
      'sending' => l10n.getString('adminBroadcastsStatusSending'),
      'sent' => l10n.getString('adminBroadcastsStatusSent'),
      'failed' => l10n.getString('adminBroadcastsStatusFailed'),
      _ => value,
    };
  }

  String _typeLabel(LocalizationState l10n, String value) {
    return switch (value) {
      'info' => l10n.getString('adminBroadcastsTypeInfo'),
      'warning' => l10n.getString('adminBroadcastsTypeWarning'),
      'promotion' => l10n.getString('adminBroadcastsTypePromotion'),
      'update' => l10n.getString('adminBroadcastsTypeUpdate'),
      _ => value,
    };
  }

  bool _matchesFilters(_AdminBroadcastRow row) {
    if (_status != 'all' && row.status != _status) return false;

    final now = DateTime.now();
    if (_timeFilter == 'upcoming') {
      final s = row.scheduledAt;
      if (s == null) return false;
      if (!s.isAfter(now)) return false;
    } else if (_timeFilter == 'past') {
      final s = row.scheduledAt;
      final sent = row.sentAt;
      if (sent != null) return true;
      if (s == null) return false;
      if (!s.isBefore(now)) return false;
    }

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return row.title.toLowerCase().contains(q) ||
        row.message.toLowerCase().contains(q) ||
        row.id.toLowerCase().contains(q) ||
        row.status.toLowerCase().contains(q);
  }

  Future<void> _delete(LocalizationState l10n, _AdminBroadcastRow row) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('adminBroadcastsDeleteTitle')),
        content: Text(l10n.getString('adminBroadcastsDeleteBody').replaceAll(
              '{title}',
              row.title,
            )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _rows = _rows.where((r) => r.id != row.id).toList(growable: false);
    });

    try {
      await Supabase.instance.client
          .from('admin_broadcasts')
          .delete()
          .eq('id', row.id)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      unawaited(_load(force: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsDeleteFailed'))),
      );
    }
  }

  Future<bool> _confirmBroadcastSend({
    required LocalizationState l10n,
    required _AdminBroadcastRow row,
    required DateTime? scheduledAtUtc,
  }) async {
    if (!mounted) return false;

    final criteria = _deepCloneCriteria(row.filterCriteria);

    bool hasHeLanguage(Map<String, dynamic> c) {
      final legacy = (c['ui_language'] ?? '').toString().trim().toLowerCase();
      if (legacy == 'he') return true;
      final list = c['ui_languages'];
      if (list is List) {
        return list.any((e) => e.toString().trim().toLowerCase() == 'he');
      }
      return false;
    }

    final isRtl = hasHeLanguage(criteria);

    return (await showDialog<bool>(
          context: context,
          builder: (ctx) {
            int? targetCount;
            bool isCounting = true;
            bool countFailed = false;

            Future<void> startCount(StateSetter setState) async {
              setState(() {
                isCounting = true;
                countFailed = false;
              });
              final count = await _countTargetUsers(criteria);
              if (!ctx.mounted) return;
              setState(() {
                isCounting = false;
                targetCount = count;
                countFailed = count == null;
              });
            }

            return StatefulBuilder(
              builder: (ctx2, setState) {
                if (isCounting && targetCount == null && !countFailed) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!ctx2.mounted) return;
                    if (!isCounting || targetCount != null || countFailed) return;
                    unawaited(startCount(setState));
                  });
                }

                final canConfirm =
                    !isCounting && targetCount != null && targetCount! > 0 && !countFailed;

                final confirmBody = scheduledAtUtc == null
                    ? l10n.getString('adminBroadcastsConfirmSendNowBody')
                    : l10n
                        .getString('adminBroadcastsConfirmScheduleBody')
                        .replaceAll(
                          '{time}',
                          _formatAdminDateTime(l10n, scheduledAtUtc),
                        );

                final actionUrl = (row.actionUrl ?? '').trim();
                final actionText = row.actionUrlText.trim();

                return AlertDialog(
                  title: Text(l10n.getString('adminBroadcastsConfirmTitle')),
                  content: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            confirmBody,
                            style: Theme.of(ctx2).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l10n.getString('adminBroadcastsPreview'),
                            style: Theme.of(ctx2).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Directionality(
                            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      row.title,
                                      style: Theme.of(ctx2).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(row.message),
                                    if (actionUrl.isNotEmpty || actionText.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton(
                                          onPressed: null,
                                          child: Text(
                                            actionText.isEmpty
                                                ? l10n.getString('adminBroadcastsActionUrlTextDefault')
                                                : actionText,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              if (isCounting)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              if (isCounting) const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isCounting
                                      ? l10n.getString('generalLoading')
                                      : targetCount == null
                                          ? l10n.getString('adminBroadcastsTargetUnknown')
                                          : l10n
                                              .getString('adminBroadcastsTargetCountValue')
                                              .replaceAll('{count}', targetCount.toString()),
                                  style: Theme.of(ctx2).textTheme.bodyMedium?.copyWith(
                                        color: (!isCounting && (countFailed || targetCount == null))
                                            ? Theme.of(ctx2).colorScheme.error
                                            : null,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: (!canConfirm)
                                    ? null
                                    : () async {
                                        await _openTargetUsersList(
                                          l10n: l10n,
                                          criteria: _deepCloneCriteria(criteria),
                                          targetCount: targetCount,
                                          listLimit: 50,
                                        );
                                      },
                                child: Text(l10n.getString('adminBroadcastsViewUsers')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx2).pop(false),
                      child: Text(l10n.getString('generalCancel')),
                    ),
                    ElevatedButton(
                      onPressed: canConfirm ? () => Navigator.of(ctx2).pop(true) : null,
                      child: Text(
                        scheduledAtUtc == null
                            ? l10n.getString('adminBroadcastsSendNow')
                            : l10n.getString('adminBroadcastsSchedule'),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        )) ??
        false;
  }

  Future<void> _sendNow(LocalizationState l10n, _AdminBroadcastRow row) async {
    if (row.status != 'draft') return;
    final confirmed = await _confirmBroadcastSend(
      l10n: l10n,
      row: row,
      scheduledAtUtc: null,
    );
    if (!confirmed) return;

    try {
      await Supabase.instance.client
          .from('admin_broadcasts')
          .update({
            'status': 'scheduled',
            'scheduled_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', row.id)
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSaved'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsSaveFailed'))),
      );
    }
  }

  Future<void> _scheduleDraft(LocalizationState l10n, _AdminBroadcastRow row) async {
    if (row.status != 'draft') return;
    final picked = await _pickDateTime(initial: DateTime.now().add(const Duration(minutes: 5)));
    if (picked == null) return;
    if (!mounted) return;
    if (!picked.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsRescheduleMustBeFuture'))),
      );
      return;
    }

    final confirmed = await _confirmBroadcastSend(
      l10n: l10n,
      row: row,
      scheduledAtUtc: picked.toUtc(),
    );
    if (!confirmed) return;

    try {
      await Supabase.instance.client
          .from('admin_broadcasts')
          .update({
            'status': 'scheduled',
            'scheduled_at': picked.toUtc().toIso8601String(),
          })
          .eq('id', row.id)
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSaved'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsSaveFailed'))),
      );
    }
  }

  Future<DateTime?> _pickDateTime({DateTime? initial}) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      initialDate: initial?.toLocal() ?? now,
    );
    if (date == null) return null;
    if (!mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial?.toLocal() ?? now),
    );
    if (time == null) return null;
    if (!mounted) return null;
    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  Map<String, dynamic> _deepCloneCriteria(Map<String, dynamic> v) {
    try {
      final cloned = jsonDecode(jsonEncode(v));
      if (cloned is Map) return Map<String, dynamic>.from(cloned);
    } catch (_) {}
    return Map<String, dynamic>.from(v);
  }

  Future<int?> _countTargetUsers(Map<String, dynamic> criteria) async {
    int? decodeInt(Object? raw) {
      if (raw == null) return null;
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw.toString());
    }

    final criteriaKey = base64UrlEncode(utf8.encode(jsonEncode(criteria)));
    final cacheKey = 'admin_cache:count_targets:v1:$criteriaKey';
    final cached = await _AdminCache.read<int?>(
      cacheKey,
      decodeInt,
    );
    if (cached != null) {
      if (cached.isFresh) return cached.data;
      unawaited(_AdminCache.readRaw(cacheKey).then((_) {}));
    }

    try {
      final result = await Supabase.instance.client.rpc(
        'count_target_users',
        params: {'filter_criteria': criteria},
      ).timeout(const Duration(seconds: 12));
      final v = decodeInt(result);
      await _AdminCache.write<int?>(cacheKey, (x) => x, v);
      return v;
    } catch (_) {
      return cached?.data;
    }
  }

  Future<void> _openTargetUsersList({
    required LocalizationState l10n,
    required Map<String, dynamic> criteria,
    required int? targetCount,
    int listLimit = 50,
  }) async {
    final isWideList = MediaQuery.of(context).size.width >= 900;

    Future<List<Map<String, dynamic>>> loadPage({
      required int limit,
      required int offset,
    }) async {
      final result = await Supabase.instance.client.rpc(
        'admin_list_target_users_for_broadcast',
        params: {
          'filter_criteria': criteria,
          'p_limit': limit,
          'p_offset': offset,
        },
      ).timeout(const Duration(seconds: 12));
      if (result is List) {
        return result
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return const [];
    }

    Widget buildListContent({
      required VoidCallback close,
    }) {
      List<Map<String, dynamic>> rows = const [];
      bool isLoading = true;
      bool isLoadingMore = false;
      bool loadFailed = false;
      bool hasMore = false;

      Future<void> loadInitial(BuildContext listCtx, StateSetter setState) async {
        if (!listCtx.mounted) return;
        setState(() {
          isLoading = true;
          loadFailed = false;
        });
        try {
          final page = await loadPage(limit: listLimit, offset: 0);
          if (!listCtx.mounted) return;
          setState(() {
            rows = page;
            hasMore = page.length >= listLimit;
            isLoading = false;
            loadFailed = false;
          });
        } catch (_) {
          if (!listCtx.mounted) return;
          setState(() {
            isLoading = false;
            loadFailed = true;
          });
        }
      }

      Future<void> loadMore(BuildContext listCtx, StateSetter setState) async {
        if (isLoadingMore || !hasMore) return;
        if (!listCtx.mounted) return;
        setState(() {
          isLoadingMore = true;
        });
        try {
          final page = await loadPage(limit: listLimit, offset: rows.length);
          if (!listCtx.mounted) return;
          setState(() {
            rows = [...rows, ...page];
            hasMore = page.length >= listLimit;
            isLoadingMore = false;
          });
        } catch (_) {
          if (!listCtx.mounted) return;
          setState(() {
            isLoadingMore = false;
          });
        }
      }

      DateTime? tryDate(dynamic v) {
        if (v == null) return null;
        if (v is DateTime) return v;
        return DateTime.tryParse(v.toString());
      }

      return StatefulBuilder(
        builder: (ctx, setState) {
          if (isLoading) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (!isLoading) return;
              if (!ctx.mounted) return;
              loadInitial(ctx, setState);
            });
          }

          final body = isLoading
              ? Center(child: Text(l10n.getString('generalLoading')))
              : loadFailed
                  ? Center(
                      child: Text(
                        l10n.getString('adminBroadcastsTargetUsersLoadFailed'),
                        style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                      ),
                    )
                  : rows.isEmpty
                      ? Center(child: Text(l10n.getString('adminBroadcastsTargetUsersEmpty')))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          itemCount: rows.length + (hasMore ? 1 : 0),
                          separatorBuilder: (ctx, index) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            if (hasMore && i == rows.length) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: OutlinedButton(
                                    onPressed:
                                        isLoadingMore ? null : () => loadMore(ctx, setState),
                                    child: isLoadingMore
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : Text(l10n.getString('generalLoadMore')),
                                  ),
                                ),
                              );
                            }

                            final row = rows[i];
                            final id = (row['user_id'] ?? row['id'] ?? '').toString();
                            final name = (row['name'] ?? '').toString().trim();
                            final displayName = maskUserDisplayName(name);
                            final platform = (row['platform'] ?? '').toString().trim();
                            final lastActive = tryDate(row['last_active_at']);
                            final lastActiveText = lastActive == null
                                ? ''
                                : DateFormat.yMMMd().add_jm().format(lastActive.toLocal());

                            return ListTile(
                              title: Text(name.isEmpty ? id : displayName),
                              subtitle: Text(lastActiveText.isEmpty ? id : '$id\n$lastActiveText'),
                              isThreeLine: lastActiveText.isNotEmpty,
                              trailing: platform.isEmpty
                                  ? null
                                  : _MetaChip(
                                      label: l10n.getString('adminBroadcastsFilterPlatform'),
                                      value: platform,
                                    ),
                            );
                          },
                        );

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('adminBroadcastsTargetUsersTitle'),
                            style: Theme.of(ctx).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            targetCount == null
                                ? l10n.getString('adminBroadcastsTargetUnknown')
                                : l10n
                                    .getString('adminBroadcastsTargetCountValue')
                                    .replaceAll('{count}', targetCount.toString()),
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.getString('generalClose'),
                      onPressed: close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: body),
            ],
          );
        },
      );
    }

    if (isWideList) {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          final safeHeight =
              MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewPadding.vertical;
          return Dialog(
            child: SizedBox(
              width: 640,
              height: safeHeight * 0.85,
              child: buildListContent(close: () => Navigator.of(ctx).pop()),
            ),
          );
        },
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final safeHeight =
            MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewPadding.vertical;
        final height = safeHeight * 0.92;
        return SizedBox(
          height: height,
          child: buildListContent(close: () => Navigator.of(ctx).pop()),
        );
      },
    );
  }

  Future<void> _resendNow(LocalizationState l10n, _AdminBroadcastRow row) async {
    try {
      await Supabase.instance.client.rpc(
        'admin_resend_broadcast_now',
        params: {'p_broadcast_id': row.id},
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsResent'))),
      );
      unawaited(_load(force: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.getString('adminBroadcastsResendFailed')}: $e'),
        ),
      );
    }
  }

  Future<void> _rescheduleSent(LocalizationState l10n, _AdminBroadcastRow row) async {
    final picked = await _pickDateTime(initial: DateTime.now());
    if (picked == null) return;
    if (!mounted) return;
    if (!picked.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsRescheduleMustBeFuture'))),
      );
      return;
    }

    try {
      await Supabase.instance.client.rpc(
        'admin_reschedule_broadcast',
        params: {
          'p_broadcast_id': row.id,
          'p_scheduled_at': picked.toUtc().toIso8601String(),
        },
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminBroadcastsRescheduled'))),
      );
      unawaited(_load(force: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.getString('adminBroadcastsRescheduleFailed')}: $e'),
        ),
      );
    }
  }

  Future<Map<String, dynamic>?> _fetchStats(String broadcastId) async {
    Map<String, dynamic> decodeMap(Object? raw) {
      if (raw is! Map) return const {};
      return Map<String, dynamic>.from(raw);
    }

    final cacheKey = 'admin_cache:broadcast_stats:v1:${broadcastId.trim()}';
    final cached = await _AdminCache.read<Map<String, dynamic>>(
      cacheKey,
      decodeMap,
    );
    if (cached != null) {
      if (cached.isFresh) return cached.data;
      unawaited(_AdminCache.readRaw(cacheKey).then((_) {}));
    }

    try {
      final result = await Supabase.instance.client.rpc(
        'get_broadcast_stats',
        params: {'p_broadcast_id': broadcastId},
      ).timeout(const Duration(seconds: 12));
      if (result is List && result.isNotEmpty) {
        final m = Map<String, dynamic>.from(result.first as Map);
        await _AdminCache.write<Map<String, dynamic>>(cacheKey, (v) => v, m);
        return m;
      }
      if (result is Map) {
        final m = Map<String, dynamic>.from(result);
        await _AdminCache.write<Map<String, dynamic>>(cacheKey, (v) => v, m);
        return m;
      }
      return cached?.data;
    } catch (_) {
      try {
        final result = await Supabase.instance.client.rpc(
          'get_broadcast_stats',
          params: {'broadcast_id': broadcastId},
        ).timeout(const Duration(seconds: 12));
        if (result is List && result.isNotEmpty) {
          final m = Map<String, dynamic>.from(result.first as Map);
          await _AdminCache.write<Map<String, dynamic>>(cacheKey, (v) => v, m);
          return m;
        }
        if (result is Map) {
          final m = Map<String, dynamic>.from(result);
          await _AdminCache.write<Map<String, dynamic>>(cacheKey, (v) => v, m);
          return m;
        }
        return cached?.data;
      } catch (_) {
        return cached?.data;
      }
    }
  }

  Future<void> _showDetails(LocalizationState l10n, _AdminBroadcastRow row) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.getString('adminBroadcastsDetailsTitle')),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 840,
              maxHeight: (MediaQuery.of(ctx).size.height -
                      MediaQuery.of(ctx).viewPadding.vertical) *
                  0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KeyPreviewRow(
                    title: l10n.getString('adminBroadcastsTitle'),
                    value: row.title,
                  ),
                  const SizedBox(height: 8),
                  _KeyPreviewRow(
                    title: l10n.getString('adminBroadcastsMessage'),
                    value: row.message,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetaChip(
                        label: l10n.getString('adminBroadcastsStatus'),
                        value: _statusLabel(l10n, row.status),
                      ),
                      _MetaChip(
                        label: l10n.getString('adminBroadcastsType'),
                        value: _typeLabel(l10n, row.messageType),
                      ),
                      if (row.scheduledAt != null)
                        _MetaChip(
                          label: l10n.getString('adminBroadcastsScheduledAt'),
                          value: _formatAdminDateTime(l10n, row.scheduledAt!),
                        ),
                      if (row.sentAt != null)
                        _MetaChip(
                          label: l10n.getString('adminBroadcastsSentAt'),
                          value: _formatAdminDateTime(l10n, row.sentAt!),
                        ),
                      if (row.targetUserCount != null)
                        _MetaChip(
                          label: l10n.getString('adminBroadcastsTargetCount'),
                          value: row.targetUserCount.toString(),
                        ),
                      if (row.actualSentCount > 0)
                        _MetaChip(
                          label: l10n.getString('adminBroadcastsActualSent'),
                          value: row.actualSentCount.toString(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.getString('adminBroadcastsFilterCriteria'),
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(row.filterCriteria),
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<Map<String, dynamic>?>(
                    future: _fetchStats(row.id),
                    builder: (ctx2, snap) {
                      final stats = snap.data;
                      final total = (stats?['total_target'] as num?)?.toInt();
                      final sent = (stats?['sent_count'] as num?)?.toInt();
                      final delivered = (stats?['delivered_count'] as num?)?.toInt();
                      final failed = (stats?['failed_count'] as num?)?.toInt();
                      final rate = stats?['delivery_rate'];

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('adminBroadcastsStatsTitle'),
                            style: Theme.of(ctx2).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (total != null)
                                _MetaChip(
                                  label: l10n.getString('adminBroadcastsStatsTotal'),
                                  value: total.toString(),
                                ),
                              if (sent != null)
                                _MetaChip(
                                  label: l10n.getString('adminBroadcastsStatsSent'),
                                  value: sent.toString(),
                                ),
                              if (delivered != null)
                                _MetaChip(
                                  label: l10n.getString('adminBroadcastsStatsDelivered'),
                                  value: delivered.toString(),
                                ),
                              if (failed != null)
                                _MetaChip(
                                  label: l10n.getString('adminBroadcastsStatsFailed'),
                                  value: failed.toString(),
                                ),
                              if (rate != null)
                                _MetaChip(
                                  label: l10n.getString('adminBroadcastsStatsRate'),
                                  value: '$rate%',
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.of(ctx).pop(),
              icon: const Icon(Icons.close),
              label: Text(l10n.getString('generalClose')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showEditor(LocalizationState l10n, {_AdminBroadcastRow? existing}) async {
    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;

    var mode = 'single';

    Timer? targetingCountDebounce;
    String? lastTargetingCountRequest;
    int? targetingCount;
    bool isTargetingCounting = false;
    bool targetingCountFailed = false;
    bool didInitTargetingCount = false;

    Timer? recipientsUiLangDebounce;
    String? lastRecipientsUiLangRequest;
    Set<String>? recipientsUiLanguages;
    bool isRecipientsUiLanguagesLoading = false;
    bool recipientsUiLanguagesFailed = false;
    bool didInitRecipientsUiLanguages = false;

    final typeController = ValueNotifier<String>(existing?.messageType ?? 'info');
    final actionUrlController = TextEditingController(text: existing?.actionUrl ?? '');

    final titleEnController = TextEditingController(text: existing?.title ?? '');
    final messageEnController = TextEditingController(text: existing?.message ?? '');
    final actionTextEnController =
        TextEditingController(text: existing?.actionUrlText ?? '');

    final titleEsController = TextEditingController();
    final messageEsController = TextEditingController();
    final actionTextEsController = TextEditingController();

    final titleHeController = TextEditingController();
    final messageHeController = TextEditingController();
    final actionTextHeController = TextEditingController();

    final criteriaController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(
        existing?.filterCriteria ?? <String, dynamic>{'all_users': true},
      ),
    );

    Map<String, dynamic>? parseCriteria() {
      try {
        final parsed = jsonDecode(criteriaController.text.trim().isEmpty
            ? '{}'
            : criteriaController.text);
        if (parsed is Map) {
          return Map<String, dynamic>.from(parsed);
        }
        return null;
      } catch (_) {
        return null;
      }
    }

    Map<String, dynamic> deepCloneCriteria(Map<String, dynamic> v) {
      try {
        final cloned = jsonDecode(jsonEncode(v));
        if (cloned is Map) return Map<String, dynamic>.from(cloned);
      } catch (_) {}
      return Map<String, dynamic>.from(v);
    }

    List<String> asStringList(dynamic raw) {
      if (raw is List) {
        return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      }
      if (raw is Set) {
        return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      }
      return const [];
    }

    bool asBool(dynamic raw) {
      if (raw == true) return true;
      if (raw == false) return false;
      return raw.toString().trim().toLowerCase() == 'true';
    }

    int? asInt(dynamic raw) {
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw.toString().trim());
    }

    Future<List<Map<String, String>>> loadGenderOptions() async {
      List<Map<String, String>> decodeListMap(Object? raw) {
        if (raw is! List) return const [];
        final out = <Map<String, String>>[];
        for (final item in raw) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          out.add({
            'key': (m['key'] ?? '').toString(),
            'displayKey': (m['displayKey'] ?? '').toString(),
          });
        }
        return out;
      }

      Object? encodeListMap(List<Map<String, String>> value) {
        return value
            .map((m) => {'key': m['key'] ?? '', 'displayKey': m['displayKey'] ?? ''})
            .toList(growable: false);
      }

      const cacheKey = 'admin_cache:gender_options:v1';
      final cached = await _AdminCache.read<List<Map<String, String>>>(
        cacheKey,
        decodeListMap,
      );
      if (cached != null && cached.isFresh) return cached.data;

      try {
        final rows = await Supabase.instance.client
            .from('app_gender_options')
            .select('gender_key, display_name_key')
            .order('sort_order', ascending: true)
            .timeout(const Duration(seconds: 8));

        final list = List<Map<String, dynamic>>.from(rows)
            .map(
              (r) => <String, String>{
                'key': (r['gender_key'] ?? '').toString().trim().toLowerCase(),
                'displayKey': (r['display_name_key'] ?? '').toString().trim(),
              },
            )
            .where((m) => m['key']!.isNotEmpty)
            .toList(growable: false);

        await _AdminCache.write<List<Map<String, String>>>(cacheKey, encodeListMap, list);
        return list;
      } catch (_) {
        return cached?.data ??
            const [
              {'key': 'male', 'displayKey': 'gender_male'},
              {'key': 'female', 'displayKey': 'gender_female'},
              {'key': 'non_binary', 'displayKey': 'gender_non_binary'},
            ];
      }
    }

    Future<List<String>> loadSubscriptionTierIds() async {
      List<String> decodeStringList(Object? raw) {
        if (raw is! List) return const [];
        return raw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
      }

      Object? encodeStringList(List<String> value) {
        return value;
      }

      const cacheKey = 'admin_cache:subscription_tier_ids:v1';
      final cached = await _AdminCache.read<List<String>>(
        cacheKey,
        decodeStringList,
      );
      if (cached != null && cached.isFresh) return cached.data;

      try {
        final rows = await Supabase.instance.client
            .from('subscription_tiers')
            .select('id, is_active, sort_order')
            .order('sort_order', ascending: true)
            .timeout(const Duration(seconds: 8));
        final list = List<Map<String, dynamic>>.from(rows)
            .where((r) => r['id'] != null)
            .where((r) => (r['is_active'] as bool?) ?? true)
            .map((r) => (r['id'] ?? '').toString().trim())
            .where((id) => id.isNotEmpty)
            .toList(growable: false);

        final base = list.isEmpty ? const ['plus', 'gold', 'platinum'] : list;
        final out = <String>['free'];
        for (final id in base) {
          if (id.trim().isEmpty) continue;
          if (id.trim().toLowerCase() == 'free') continue;
          out.add(id);
        }
        await _AdminCache.write<List<String>>(cacheKey, encodeStringList, out);
        return out;
      } catch (_) {
        return cached?.data ?? const ['free', 'plus', 'gold', 'platinum'];
      }
    }

    void requestTargetingCount(
      BuildContext dialogCtx,
      StateSetter setDialogState,
      Map<String, dynamic> criteria,
    ) {
      targetingCountDebounce?.cancel();
      targetingCountDebounce = Timer(const Duration(milliseconds: 350), () async {
        if (!mounted || !dialogCtx.mounted) return;
        final requestKey = jsonEncode(criteria);
        lastTargetingCountRequest = requestKey;
        setDialogState(() {
          isTargetingCounting = true;
          targetingCountFailed = false;
        });
        final count = await _countTargetUsers(criteria);
        if (!mounted || !dialogCtx.mounted) return;
        if (lastTargetingCountRequest != requestKey) return;
        setDialogState(() {
          isTargetingCounting = false;
          targetingCount = count;
          targetingCountFailed = count == null;
        });
      });
    }

    void requestRecipientsUiLanguages(
      BuildContext dialogCtx,
      StateSetter setDialogState,
      Map<String, dynamic> criteria,
    ) {
      recipientsUiLangDebounce?.cancel();
      recipientsUiLangDebounce = Timer(const Duration(milliseconds: 350), () async {
        if (!mounted || !dialogCtx.mounted) return;

        final userIds = asStringList(criteria['user_ids']);
        if (userIds.isEmpty) {
          lastRecipientsUiLangRequest = null;
          setDialogState(() {
            isRecipientsUiLanguagesLoading = false;
            recipientsUiLanguagesFailed = false;
            recipientsUiLanguages = null;
          });
          return;
        }

        final normalizedIds = userIds.map((e) => e.toLowerCase()).toList()..sort();
        final requestKey = jsonEncode(normalizedIds);
        lastRecipientsUiLangRequest = requestKey;
        setDialogState(() {
          isRecipientsUiLanguagesLoading = true;
          recipientsUiLanguagesFailed = false;
        });

        try {
          final rows = await Supabase.instance.client.rpc(
            'admin_get_user_ui_languages',
            params: {'p_user_ids': normalizedIds},
          );
          if (!mounted || !dialogCtx.mounted) return;
          if (lastRecipientsUiLangRequest != requestKey) return;

          final list = rows is List ? rows : const [];
          final langs = <String>{};

          for (final raw in list) {
            if (raw is! Map) continue;
            final lang = (raw['preferred_language'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            final normalized = (lang == 'es' || lang == 'he') ? lang : 'en';
            langs.add(normalized);
          }

          if (langs.isEmpty) {
            langs.add('en');
          }

          setDialogState(() {
            isRecipientsUiLanguagesLoading = false;
            recipientsUiLanguagesFailed = false;
            recipientsUiLanguages = langs;
          });
        } catch (_) {
          if (!mounted || !dialogCtx.mounted) return;
          if (lastRecipientsUiLangRequest != requestKey) return;
          setDialogState(() {
            isRecipientsUiLanguagesLoading = false;
            recipientsUiLanguagesFailed = true;
            recipientsUiLanguages = null;
          });
        }
      });
    }

    bool looksLikeUrl(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return true;
      final uri = Uri.tryParse(trimmed);
      if (uri == null) return false;
      if (!uri.hasScheme) return false;
      if (uri.scheme != 'https' && uri.scheme != 'http') return false;
      return uri.host.isNotEmpty;
    }

    Future<Map<String, dynamic>?> editTargetingFilters({
      required Map<String, dynamic> initial,
      required bool allowUiLanguageFilters,
      required Map<String, String> uiLanguageDisplayNames,
    }) async {
      final genders = await loadGenderOptions();
      final tiers = await loadSubscriptionTierIds();
      if (!mounted) return null;

      final isWide = MediaQuery.of(context).size.width >= 900;

      Widget buildContent({
        required Map<String, dynamic> startValue,
        required void Function(Map<String, dynamic> value) closeWithValue,
        required VoidCallback closeWithoutValue,
      }) {
        var draft = deepCloneCriteria(startValue);
        Timer? countDebounce;
        String? lastCountRequest;
        int? targetCount;
        bool isCounting = false;
        bool countFailed = false;
        bool didInitCount = false;
        int listLimit = 50;

        String uiLanguageName(String code) {
          final normalized = code.trim().toLowerCase();
          return uiLanguageDisplayNames[normalized] ??
              uiLanguageNameFallback(l10n, normalized);
        }

        List<String> currentList(String key) => asStringList(draft[key]).map((e) => e.toLowerCase()).toList();
        void setList(String key, List<String> values) {
          final clean = values.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(growable: false);
          if (clean.isEmpty) {
            draft.remove(key);
          } else {
            draft[key] = clean;
          }
        }

        bool currentBool(String key) => asBool(draft[key]);

        int? currentInt(String key) => asInt(draft[key]);
        void setInt(String key, int? value) {
          if (value == null) {
            draft.remove(key);
          } else {
            draft[key] = value;
          }
        }

        Map<String, dynamic>? currentAgeRange() {
          final raw = draft['age_range'];
          if (raw is Map) return Map<String, dynamic>.from(raw);
          return null;
        }

        void setAgeRange({required int min, required int max}) {
          draft['age_range'] = <String, dynamic>{'min': min, 'max': max};
        }

        void clearAgeRange() {
          draft.remove('age_range');
        }

        String statusLabel(LocalizationState l10n, String s) {
          return switch (s) {
            'unverified' => l10n.getString('adminStatusUnverified'),
            'analyzing' => l10n.getString('adminStatusAnalyzing'),
            'pending' => l10n.getString('adminStatusPending'),
            'approved' => l10n.getString('adminStatusApproved'),
            'rejected' => l10n.getString('adminStatusRejected'),
            _ => s,
          };
        }

        String platformLabel(LocalizationState l10n, String p) {
          return switch (p) {
            'ios' => l10n.getString('adminPlatformIos'),
            'android' => l10n.getString('adminPlatformAndroid'),
            'web' => l10n.getString('adminPlatformWeb'),
            _ => p,
          };
        }

        String genderLabel(LocalizationState l10n, String key) {
          final found = genders.firstWhere(
            (g) => (g['key'] ?? '').trim().toLowerCase() == key.trim().toLowerCase(),
            orElse: () => const <String, String>{},
          );
          final displayKey = (found['displayKey'] ?? '').trim();
          if (displayKey.isNotEmpty) {
            return l10n.getString(displayKey);
          }
          final transKey = 'gender_${key.trim().toLowerCase()}';
          return l10n.getString(transKey);
        }

        String tierLabel(LocalizationState l10n, String id) {
          final key = id.trim().toLowerCase();
          if (key == 'free') return l10n.getString('adminSubscriptionTierFree');
          return id;
        }

        const List<int> lastActiveOptions = [1, 3, 7, 14, 30, 90];

        Future<void> openTargetUsersList(Map<String, dynamic> criteria) async {
          final isWideList = MediaQuery.of(context).size.width >= 900;

          Future<List<Map<String, dynamic>>> loadPage({
            required int limit,
            required int offset,
          }) async {
            final result = await Supabase.instance.client.rpc(
              'admin_list_target_users_for_broadcast',
              params: {
                'filter_criteria': criteria,
                'p_limit': limit,
                'p_offset': offset,
              },
            ).timeout(const Duration(seconds: 12));
            if (result is List) {
              return result
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList();
            }
            return const [];
          }

          Widget buildListContent({
            required VoidCallback close,
          }) {
            List<Map<String, dynamic>> rows = const [];
            bool isLoading = true;
            bool isLoadingMore = false;
            bool loadFailed = false;
            bool hasMore = false;

            Future<void> loadInitial(BuildContext listCtx, StateSetter setState) async {
              if (!listCtx.mounted) return;
              setState(() {
                isLoading = true;
                loadFailed = false;
              });
              try {
                final page = await loadPage(limit: listLimit, offset: 0);
                if (!listCtx.mounted) return;
                setState(() {
                  rows = page;
                  hasMore = page.length >= listLimit;
                  isLoading = false;
                  loadFailed = false;
                });
              } catch (_) {
                if (!listCtx.mounted) return;
                setState(() {
                  isLoading = false;
                  loadFailed = true;
                });
              }
            }

            Future<void> loadMore(BuildContext listCtx, StateSetter setState) async {
              if (isLoadingMore || !hasMore) return;
              if (!listCtx.mounted) return;
              setState(() {
                isLoadingMore = true;
              });
              try {
                final page = await loadPage(limit: listLimit, offset: rows.length);
                if (!listCtx.mounted) return;
                setState(() {
                  rows = [...rows, ...page];
                  hasMore = page.length >= listLimit;
                  isLoadingMore = false;
                });
              } catch (_) {
                if (!listCtx.mounted) return;
                setState(() {
                  isLoadingMore = false;
                });
              }
            }

            DateTime? tryDate(dynamic v) {
              if (v == null) return null;
              if (v is DateTime) return v;
              return DateTime.tryParse(v.toString());
            }

            return StatefulBuilder(
              builder: (ctx, setState) {
                if (isLoading) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (!isLoading) return;
                    if (!ctx.mounted) return;
                    loadInitial(ctx, setState);
                  });
                }

                final body = isLoading
                    ? Center(child: Text(l10n.getString('generalLoading')))
                    : loadFailed
                        ? Center(
                            child: Text(
                              l10n.getString('adminBroadcastsTargetUsersLoadFailed'),
                              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(ctx).colorScheme.error,
                                  ),
                            ),
                          )
                        : rows.isEmpty
                            ? Center(child: Text(l10n.getString('adminBroadcastsTargetUsersEmpty')))
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                                itemCount: rows.length + (hasMore ? 1 : 0),
                                separatorBuilder: (ctx, index) => const Divider(height: 1),
                                itemBuilder: (ctx, i) {
                                  if (hasMore && i == rows.length) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      child: Center(
                                        child: OutlinedButton(
                                          onPressed: isLoadingMore
                                              ? null
                                              : () => loadMore(ctx, setState),
                                          child: isLoadingMore
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(strokeWidth: 2),
                                                )
                                              : Text(l10n.getString('generalLoadMore')),
                                        ),
                                      ),
                                    );
                                  }

                                  final row = rows[i];
                                  final id = (row['user_id'] ?? row['id'] ?? '').toString();
                                  final name = (row['name'] ?? '').toString().trim();
                                  final displayName = maskUserDisplayName(name);
                                  final platform = (row['platform'] ?? '').toString().trim();
                                  final lastActive = tryDate(row['last_active_at']);
                                  final lastActiveText = lastActive == null
                                      ? ''
                                      : DateFormat.yMMMd().add_jm().format(lastActive.toLocal());

                                  return ListTile(
                                    title: Text(name.isEmpty ? id : displayName),
                                    subtitle: Text(lastActiveText.isEmpty ? id : '$id\n$lastActiveText'),
                                    isThreeLine: lastActiveText.isNotEmpty,
                                    trailing: platform.isEmpty
                                        ? null
                                        : _MetaChip(
                                            label: l10n.getString('adminBroadcastsFilterPlatform'),
                                            value: platform,
                                          ),
                                  );
                                },
                              );

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.getString('adminBroadcastsTargetUsersTitle'),
                                  style: Theme.of(ctx).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  targetCount == null
                                      ? l10n.getString('adminBroadcastsTargetUnknown')
                                      : l10n
                                          .getString('adminBroadcastsTargetCountValue')
                                          .replaceAll('{count}', targetCount.toString()),
                                  style: Theme.of(ctx).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.getString('generalClose'),
                            onPressed: close,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: body),
                  ],
                );
              },
            );
          }

          if (isWideList) {
            await showDialog<void>(
              context: context,
              builder: (ctx) {
                final safeHeight =
                    MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewPadding.vertical;
                return Dialog(
                  child: SizedBox(
                    width: 640,
                    height: safeHeight * 0.85,
                    child: buildListContent(close: () => Navigator.of(ctx).pop()),
                  ),
                );
              },
            );
            return;
          }

          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            builder: (ctx) {
              final safeHeight =
                  MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewPadding.vertical;
              final height = safeHeight * 0.92;
              return SizedBox(
                height: height,
                child: buildListContent(close: () => Navigator.of(ctx).pop()),
              );
            },
          );
        }

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void closeWithoutValueSafe() {
              countDebounce?.cancel();
              closeWithoutValue();
            }

            void closeWithValueSafe(Map<String, dynamic> value) {
              countDebounce?.cancel();
              closeWithValue(value);
            }

            void requestTargetCount() {
              if (!ctx.mounted) return;
              final requestKey = jsonEncode(draft);
              lastCountRequest = requestKey;
              countFailed = false;
              isCounting = true;
              setSheetState(() {});

              countDebounce?.cancel();
              countDebounce = Timer(const Duration(milliseconds: 350), () async {
                final expectedKey = lastCountRequest;
                if (expectedKey == null) return;

                Map<String, dynamic> criteria;
                try {
                  final decoded = jsonDecode(expectedKey);
                  criteria = decoded is Map
                      ? Map<String, dynamic>.from(decoded)
                      : <String, dynamic>{};
                } catch (_) {
                  criteria = <String, dynamic>{};
                }

                int? count;
                try {
                  count = await _countTargetUsers(criteria);
                } catch (_) {
                  count = null;
                }
                if (!mounted) return;
                if (!ctx.mounted) return;
                if (lastCountRequest != expectedKey) return;

                setSheetState(() {
                  isCounting = false;
                  targetCount = count;
                  countFailed = count == null;
                });
              });
            }

            if (!didInitCount) {
              didInitCount = true;
              isCounting = true;
              countFailed = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (!ctx.mounted) return;
                requestTargetCount();
              });
            }

            final allUsers = currentBool('all_users');
            final lastActiveDays = currentInt('last_active_days');
            final genderSelected = currentList('gender');
            final tierSelected = currentList('subscription_tiers');
            final verificationSelected = currentList('verification_status');
            final platformSelected = currentList('platform');
            final uiLanguages = (() {
              final out = <String>{...currentList('ui_languages')};
              final legacy = (draft['ui_language'] ?? '').toString().trim().toLowerCase();
              if (legacy == 'en' || legacy == 'es' || legacy == 'he') out.add(legacy);
              return out.toList(growable: false);
            })();

            String currentStatusMode() {
              final raw = (draft['status'] ?? '').toString().trim().toLowerCase();
              if (raw == 'visible' || raw == 'invisible' || raw == 'offline') return raw;
              final legacy = (draft['visibility'] ?? '').toString().trim().toLowerCase();
              if (legacy == 'visible' || legacy == 'invisible') return legacy;
              if (asBool(draft['visible_only'])) return 'visible';
              return 'all';
            }

            final statusMode = currentStatusMode();

            final age = currentAgeRange();
            final ageMin = asInt(age?['min']) ?? 18;
            final ageMax = asInt(age?['max']) ?? 80;
            final hasAge = age != null;

            void toggleStringInList(String key, String value) {
              final v = value.trim().toLowerCase();
              var next = currentList(key);
              if (next.contains(v)) {
                next = next.where((e) => e != v).toList(growable: false);
              } else {
                next = [...next, v];
              }
              setSheetState(() {
                setList(key, next);
              });
              requestTargetCount();
            }

            void toggleUiLanguage(String code) {
              final v = code.trim().toLowerCase();
              if (v != 'en' && v != 'es' && v != 'he') return;
              final base = <String>{
                ...currentList('ui_languages'),
                ...(draft['ui_language'] == null
                    ? const <String>{}
                    : <String>{draft['ui_language'].toString().trim().toLowerCase()}),
              }.where((e) => e == 'en' || e == 'es' || e == 'he').toList(growable: false);

              var next = base;
              if (next.contains(v)) {
                next = next.where((e) => e != v).toList(growable: false);
              } else {
                next = [...next, v];
              }

              setSheetState(() {
                draft.remove('ui_language');
                setList('ui_languages', next);
              });
              requestTargetCount();
            }

            Widget sectionTitle(String title) {
              return Padding(
                padding: const EdgeInsets.only(top: 18, bottom: 8),
                child: Text(title, style: Theme.of(ctx).textTheme.titleSmall),
              );
            }

            final content = ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                SwitchListTile(
                  value: allUsers,
                  onChanged: (v) {
                    setSheetState(() {
                      if (v) {
                        draft = <String, dynamic>{'all_users': true};
                      } else {
                        draft.remove('all_users');
                      }
                    });
                    requestTargetCount();
                  },
                  title: Text(l10n.getString('adminBroadcastsFilterAllUsers')),
                ),
                if (!allUsers) ...[
                  sectionTitle(l10n.getString('adminBroadcastsFilterGender')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: genders.map((g) {
                      final key = (g['key'] ?? '').trim().toLowerCase();
                      if (key.isEmpty) return const SizedBox.shrink();
                      final isSelected = genderSelected.contains(key);
                      return FilterChip(
                        selected: isSelected,
                        onSelected: (_) => toggleStringInList('gender', key),
                        label: Text(genderLabel(l10n, key)),
                      );
                    }).toList(growable: false),
                  ),
                  sectionTitle(l10n.getString('adminBroadcastsFilterAgeRange')),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          hasAge
                              ? '${ageMin.toString()}–${ageMax.toString()}'
                              : l10n.getString('generalAny'),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setSheetState(() => clearAgeRange());
                          requestTargetCount();
                        },
                        child: Text(l10n.getString('generalClear')),
                      ),
                    ],
                  ),
                  RangeSlider(
                    values: RangeValues(ageMin.toDouble(), ageMax.toDouble()),
                    min: 18,
                    max: 80,
                    divisions: 62,
                    labels: RangeLabels(ageMin.toString(), ageMax.toString()),
                    onChanged: (values) {
                      setSheetState(() {
                        setAgeRange(min: values.start.round(), max: values.end.round());
                      });
                      requestTargetCount();
                    },
                  ),
                  sectionTitle(l10n.getString('adminBroadcastsFilterSubscriptionTiers')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: tiers.map((id) {
                      final key = id.trim();
                      if (key.isEmpty) return const SizedBox.shrink();
                      final isSelected = tierSelected.contains(key.toLowerCase());
                      return FilterChip(
                        selected: isSelected,
                        onSelected: (_) => toggleStringInList('subscription_tiers', key),
                        label: Text(tierLabel(l10n, key)),
                      );
                    }).toList(growable: false),
                  ),
                  sectionTitle(l10n.getString('adminBroadcastsFilterVerificationStatus')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const ['unverified', 'analyzing', 'pending', 'approved', 'rejected']
                        .map((s) {
                      final isSelected = verificationSelected.contains(s);
                      return FilterChip(
                        selected: isSelected,
                        onSelected: (_) => toggleStringInList('verification_status', s),
                        label: Text(statusLabel(l10n, s)),
                      );
                    }).toList(growable: false),
                  ),
                  sectionTitle(l10n.getString('adminBroadcastsFilterPlatform')),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const ['ios', 'android', 'web'].map((p) {
                      final isSelected = platformSelected.contains(p);
                      return FilterChip(
                        selected: isSelected,
                        onSelected: (_) => toggleStringInList('platform', p),
                        label: Text(platformLabel(l10n, p)),
                      );
                    }).toList(growable: false),
                  ),
                  sectionTitle(l10n.getString('adminBroadcastsFilterLastActiveDays')),
                  DropdownMenu<int?>(
                    initialSelection: lastActiveDays,
                    label: Text(l10n.getString('adminBroadcastsLastActiveLabel')),
                    dropdownMenuEntries: [
                      DropdownMenuEntry(value: null, label: l10n.getString('generalAny')),
                      ...lastActiveOptions.map(
                        (d) => DropdownMenuEntry(
                          value: d,
                          label: l10n
                              .getString('adminBroadcastsLastActiveValue')
                              .replaceAll('{days}', d.toString()),
                        ),
                      ),
                    ],
                    onSelected: (v) {
                      setSheetState(() => setInt('last_active_days', v));
                      requestTargetCount();
                    },
                  ),
                  const SizedBox(height: 8),
                  sectionTitle(l10n.getString('adminBroadcastsFilterStatus')),
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'all',
                        label: Text(l10n.getString('adminBroadcastsStatusAll')),
                      ),
                      ButtonSegment(
                        value: 'visible',
                        label: Text(l10n.getString('adminBroadcastsStatusVisible')),
                      ),
                      ButtonSegment(
                        value: 'invisible',
                        label: Text(l10n.getString('adminBroadcastsStatusInvisible')),
                      ),
                      ButtonSegment(
                        value: 'offline',
                        label: Text(l10n.getString('adminBroadcastsStatusOffline')),
                      ),
                    ],
                    selected: {statusMode},
                    onSelectionChanged: (selection) {
                      if (selection.isEmpty) return;
                      final mode = selection.first;
                      setSheetState(() {
                        draft.remove('visible_only');
                        draft.remove('visibility');
                        if (mode == 'all') {
                          draft.remove('status');
                        } else {
                          draft['status'] = mode;
                        }
                      });
                      requestTargetCount();
                    },
                  ),
                  if (allowUiLanguageFilters) ...[
                    sectionTitle(l10n.getString('adminBroadcastsFilterUiLanguages')),
                    MenuAnchor(
                      menuChildren: ['en', 'es', 'he'].map((code) {
                        final isSelected = uiLanguages.contains(code);
                        return SizedBox(
                          width: 260,
                          child: CheckboxListTile(
                            value: isSelected,
                            onChanged: (_) => toggleUiLanguage(code),
                            title: Text(uiLanguageName(code)),
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                          ),
                        );
                      }).toList(growable: false),
                      builder: (innerCtx, controller, child) {
                        final selectedNames = const ['en', 'es', 'he']
                            .where(uiLanguages.contains)
                            .map(uiLanguageName)
                            .toList(growable: false);
                        final display = selectedNames.isEmpty
                            ? l10n.getString('generalAny')
                            : selectedNames.join(', ');
                        return OutlinedButton.icon(
                          onPressed: () {
                            if (controller.isOpen) {
                              controller.close();
                            } else {
                              controller.open();
                            }
                          },
                          icon: const Icon(Icons.language),
                          label: Text(display, overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
                  ],
                ],
              ],
            );

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.getString('adminBroadcastsTargetingFiltersTitle'),
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.getString('generalClose'),
                        onPressed: closeWithoutValueSafe,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: content),
                const Divider(height: 1),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    10,
                    16,
                    16 +
                        (() {
                          final mq = MediaQuery.of(ctx);
                          final a = mq.viewPadding.bottom;
                          final b = mq.systemGestureInsets.bottom;
                          return a > b ? a : b;
                        })(),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (isCounting)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          if (isCounting) const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              isCounting
                                  ? l10n.getString('generalLoading')
                                  : targetCount == null
                                      ? l10n.getString('adminBroadcastsTargetUnknown')
                                      : l10n
                                          .getString('adminBroadcastsTargetCountValue')
                                          .replaceAll('{count}', targetCount.toString()),
                              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                                    color: (countFailed || targetCount == null) && !isCounting
                                        ? Theme.of(ctx).colorScheme.error
                                        : null,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: (isCounting || targetCount == null || targetCount == 0)
                                ? null
                                : () async {
                                    await openTargetUsersList(deepCloneCriteria(draft));
                                  },
                            child: Text(l10n.getString('adminBroadcastsViewUsers')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () {
                              setSheetState(() => draft = <String, dynamic>{});
                              requestTargetCount();
                            },
                            child: Text(l10n.getString('generalClear')),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: closeWithoutValueSafe,
                            child: Text(l10n.getString('generalCancel')),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () => closeWithValueSafe(draft),
                            child: Text(l10n.getString('generalApply')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      }

      if (isWide) {
        return showDialog<Map<String, dynamic>>(
          context: context,
          builder: (ctx) {
            return Dialog(
              insetPadding: const EdgeInsets.fromLTRB(64, 24, 24, 24),
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 460,
                height: (MediaQuery.of(ctx).size.height -
                        MediaQuery.of(ctx).viewPadding.vertical) *
                    0.9,
                child: buildContent(
                  startValue: initial,
                  closeWithValue: (v) => Navigator.of(ctx).pop(v),
                  closeWithoutValue: () => Navigator.of(ctx).pop(),
                ),
              ),
            );
          },
        );
      }

      return showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (ctx) {
          final safeHeight =
              MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewPadding.vertical;
          final height = safeHeight * 0.92;
          return SizedBox(
            height: height,
            child: buildContent(
              startValue: initial,
              closeWithValue: (v) => Navigator.of(ctx).pop(v),
              closeWithoutValue: () => Navigator.of(ctx).pop(),
            ),
          );
        },
      );
    }

    Widget previewCard(
      BuildContext themeContext, {
      required String locale,
      required String title,
      required String message,
      required String actionText,
      required String actionUrl,
    }) {
      final dir = locale == 'he' ? TextDirection.rtl : TextDirection.ltr;
      return Directionality(
        textDirection: dir,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.trim(),
                  style: Theme.of(themeContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(message.trim()),
                if (actionUrl.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: dir == TextDirection.rtl
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: FilledButton(
                      onPressed: null,
                      child: Text(
                        actionText.trim(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final uiLanguageDisplayNames = await loadUiLanguageDisplayNames();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          String uiLanguageName(String code, Map<String, String> names) {
            final normalized = code.trim().toLowerCase();
            return names[normalized] ??
                uiLanguageNameFallback(l10n, normalized);
          }

          final type = typeController.value;
          final actionUrl = actionUrlController.text;

          final isPerLanguage = mode == 'per_language';

          void setCriteria(Map<String, dynamic> next) {
            criteriaController.text =
                const JsonEncoder.withIndent('  ').convert(next);
            requestTargetingCount(ctx, setDialogState, next);
            requestRecipientsUiLanguages(ctx, setDialogState, next);
            setDialogState(() {});
          }

          void removeCriteriaKey(String key) {
            final current = parseCriteria();
            if (current == null) return;
            current.remove(key);
            setCriteria(current);
          }

          void removeVisibilityCriteria() {
            final current = parseCriteria();
            if (current == null) return;
            current.remove('status');
            current.remove('visibility');
            current.remove('visible_only');
            setCriteria(current);
          }

          String criteriaLabel(String key) {
            return switch (key) {
              'all_users' => l10n.getString('adminBroadcastsFilterAllUsers'),
              'user_ids' => l10n.getString('adminBroadcastsRecipientsButton'),
              'gender' => l10n.getString('adminBroadcastsFilterGender'),
              'age_range' => l10n.getString('adminBroadcastsFilterAgeRange'),
              'subscription_tiers' =>
                l10n.getString('adminBroadcastsFilterSubscriptionTiers'),
              'verification_status' =>
                l10n.getString('adminBroadcastsFilterVerificationStatus'),
              'platform' => l10n.getString('adminBroadcastsFilterPlatform'),
              'last_active_days' =>
                l10n.getString('adminBroadcastsFilterLastActiveDays'),
              'status' => l10n.getString('adminBroadcastsFilterStatus'),
              'visible_only' => l10n.getString('adminBroadcastsFilterVisibleOnly'),
              'ui_language' => l10n.getString('adminBroadcastsFilterUiLanguage'),
              'ui_languages' => l10n.getString('adminBroadcastsFilterUiLanguages'),
              _ => key,
            };
          }

          String formatVerificationStatus(String s) {
            return switch (s) {
              'unverified' => l10n.getString('adminStatusUnverified'),
              'analyzing' => l10n.getString('adminStatusAnalyzing'),
              'pending' => l10n.getString('adminStatusPending'),
              'approved' => l10n.getString('adminStatusApproved'),
              'rejected' => l10n.getString('adminStatusRejected'),
              _ => s,
            };
          }

          String formatPlatform(String p) {
            return switch (p) {
              'ios' => l10n.getString('adminPlatformIos'),
              'android' => l10n.getString('adminPlatformAndroid'),
              'web' => l10n.getString('adminPlatformWeb'),
              _ => p,
            };
          }

          String formatListValue(String key, List<String> values) {
            final clean = values.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            if (clean.isEmpty) return '';
            if (key == 'verification_status') {
              return clean.map(formatVerificationStatus).join(', ');
            }
            if (key == 'platform') {
              return clean.map(formatPlatform).join(', ');
            }
            return clean.join(', ');
          }

          List<Widget> buildCriteriaChips(Map<String, dynamic> criteria) {
            final chips = <Widget>[];

            final userIds = asStringList(criteria['user_ids']);
            if (userIds.isNotEmpty) {
              chips.add(
                InputChip(
                  label: Text(
                    l10n
                        .getString('adminBroadcastsRecipientsChip')
                        .replaceAll('{count}', userIds.length.toString()),
                  ),
                  onDeleted: () => removeCriteriaKey('user_ids'),
                ),
              );
              return chips;
            }

            if (asBool(criteria['all_users'])) {
              chips.add(
                InputChip(
                  label: Text(criteriaLabel('all_users')),
                  onDeleted: () => removeCriteriaKey('all_users'),
                ),
              );
              return chips;
            }

            final genders = asStringList(criteria['gender']);
            if (genders.isNotEmpty) {
              chips.add(
                InputChip(
                  label: Text('${criteriaLabel('gender')}: ${formatListValue('gender', genders)}'),
                  onDeleted: () => removeCriteriaKey('gender'),
                ),
              );
            }

            final age = criteria['age_range'];
            if (age is Map) {
              final m = Map<String, dynamic>.from(age);
              final min = asInt(m['min']);
              final max = asInt(m['max']);
              if (min != null && max != null) {
                chips.add(
                  InputChip(
                    label: Text('${criteriaLabel('age_range')}: ${min.toString()}–${max.toString()}'),
                    onDeleted: () => removeCriteriaKey('age_range'),
                  ),
                );
              }
            }

            final tiers = asStringList(criteria['subscription_tiers']);
            if (tiers.isNotEmpty) {
              chips.add(
                InputChip(
                  label: Text(
                    '${criteriaLabel('subscription_tiers')}: ${formatListValue('subscription_tiers', tiers)}',
                  ),
                  onDeleted: () => removeCriteriaKey('subscription_tiers'),
                ),
              );
            }

            final verification = asStringList(criteria['verification_status']);
            if (verification.isNotEmpty) {
              chips.add(
                InputChip(
                  label: Text(
                    '${criteriaLabel('verification_status')}: ${formatListValue('verification_status', verification)}',
                  ),
                  onDeleted: () => removeCriteriaKey('verification_status'),
                ),
              );
            }

            final platforms = asStringList(criteria['platform']);
            if (platforms.isNotEmpty) {
              chips.add(
                InputChip(
                  label: Text(
                    '${criteriaLabel('platform')}: ${formatListValue('platform', platforms)}',
                  ),
                  onDeleted: () => removeCriteriaKey('platform'),
                ),
              );
            }

            final lastActive = asInt(criteria['last_active_days']);
            if (lastActive != null) {
              chips.add(
                InputChip(
                  label: Text(
                    '${criteriaLabel('last_active_days')}: ${l10n.getString('adminBroadcastsLastActiveValue').replaceAll('{days}', lastActive.toString())}',
                  ),
                  onDeleted: () => removeCriteriaKey('last_active_days'),
                ),
              );
            }

            final status = (criteria['status'] ?? '').toString().trim().toLowerCase();
            final legacyVis = (criteria['visibility'] ?? '').toString().trim().toLowerCase();
            final legacyVisible = asBool(criteria['visible_only']);
            final mode = (status == 'visible' || status == 'invisible' || status == 'offline')
                ? status
                : (legacyVis == 'visible' || legacyVis == 'invisible')
                    ? legacyVis
                    : (legacyVisible ? 'visible' : 'all');
            if (mode == 'visible' || mode == 'invisible' || mode == 'offline') {
              final modeLabel = switch (mode) {
                'visible' => l10n.getString('adminBroadcastsStatusVisible'),
                'invisible' => l10n.getString('adminBroadcastsStatusInvisible'),
                'offline' => l10n.getString('adminBroadcastsStatusOffline'),
                _ => mode,
              };
              chips.add(
                InputChip(
                  label: Text('${criteriaLabel('status')}: $modeLabel'),
                  onDeleted: removeVisibilityCriteria,
                ),
              );
            }

            if (!isPerLanguage) {
              final uiLang = (criteria['ui_language'] ?? '').toString().trim().toLowerCase();
              final uiLangs = <String>{
                ...asStringList(criteria['ui_languages']).map((e) => e.toLowerCase()),
                if (uiLang.isNotEmpty) uiLang,
              }.where((e) => e == 'en' || e == 'es' || e == 'he').toList(growable: false);
              if (uiLangs.isNotEmpty) {
                chips.add(
                  InputChip(
                    label: Text(
                      '${criteriaLabel('ui_languages')}: ${uiLangs.map((c) => uiLanguageName(c, uiLanguageDisplayNames)).join(', ')}',
                    ),
                    onDeleted: () {
                      removeCriteriaKey('ui_language');
                      removeCriteriaKey('ui_languages');
                    },
                  ),
                );
              }
            }

            return chips;
          }

          final previewEn = previewCard(
            ctx,
            locale: 'en',
            title: titleEnController.text,
            message: messageEnController.text,
            actionText: actionTextEnController.text,
            actionUrl: actionUrl,
          );
          final previewEs = isPerLanguage
              ? previewCard(
                  ctx,
                  locale: 'es',
                  title: titleEsController.text,
                  message: messageEsController.text,
                  actionText: actionTextEsController.text,
                  actionUrl: actionUrl,
                )
              : previewEn;
          final previewHe = isPerLanguage
              ? previewCard(
                  ctx,
                  locale: 'he',
                  title: titleHeController.text,
                  message: messageHeController.text,
                  actionText: actionTextHeController.text,
                  actionUrl: actionUrl,
                )
              : previewEn;

          Future<void> submit() async {
            if (!formKey.currentState!.validate()) return;

            final criteria = parseCriteria();
            if (criteria == null) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.getString('adminBroadcastsInvalidJson'))),
              );
              return;
            }

            setDialogState(() {
              isSubmitting = true;
            });

            try {
              final client = Supabase.instance.client;
              final nowUtc = DateTime.now().toUtc().toIso8601String();

              final userId = client.auth.currentUser?.id;

              if (existing != null) {
                await client.from('admin_broadcasts').update({
                  'title': titleEnController.text.trim(),
                  'message': messageEnController.text.trim(),
                  'message_type': type,
                  'action_url': actionUrlController.text.trim().isEmpty
                      ? null
                      : actionUrlController.text.trim(),
                  'action_url_text': actionTextEnController.text.trim().isEmpty
                      ? null
                      : actionTextEnController.text.trim(),
                  'filter_criteria': criteria,
                  'scheduled_at': null,
                  'sent_at': null,
                  'status': 'draft',
                  'updated_at': nowUtc,
                }).eq('id', existing.id);
              } else if (isPerLanguage) {
                Map<String, dynamic> criteriaFor(String locale) {
                  final merged = Map<String, dynamic>.from(criteria);
                  merged.remove('ui_language');
                  merged.remove('ui_languages');
                  merged['ui_language'] = locale;
                  return merged;
                }

                final selectedUserIds = asStringList(criteria['user_ids']);
                final actionUrl = actionUrlController.text.trim().isEmpty
                    ? null
                    : actionUrlController.text.trim();

                Map<String, dynamic> rowForLocale(String locale, List<String> userIds) {
                  final criteriaForUsers = criteriaFor(locale);
                  criteriaForUsers['user_ids'] = userIds;
                  return {
                    'title': switch (locale) {
                      'es' => titleEsController.text.trim().isEmpty
                          ? titleEnController.text.trim()
                          : titleEsController.text.trim(),
                      'he' => titleHeController.text.trim().isEmpty
                          ? titleEnController.text.trim()
                          : titleHeController.text.trim(),
                      _ => titleEnController.text.trim(),
                    },
                    'message': switch (locale) {
                      'es' => messageEsController.text.trim().isEmpty
                          ? messageEnController.text.trim()
                          : messageEsController.text.trim(),
                      'he' => messageHeController.text.trim().isEmpty
                          ? messageEnController.text.trim()
                          : messageHeController.text.trim(),
                      _ => messageEnController.text.trim(),
                    },
                    'message_type': type,
                    'action_url': actionUrl,
                    'action_url_text': switch (locale) {
                      'es' => actionTextEsController.text.trim().isEmpty
                          ? (actionTextEnController.text.trim().isEmpty
                              ? null
                              : actionTextEnController.text.trim())
                          : actionTextEsController.text.trim(),
                      'he' => actionTextHeController.text.trim().isEmpty
                          ? (actionTextEnController.text.trim().isEmpty
                              ? null
                              : actionTextEnController.text.trim())
                          : actionTextHeController.text.trim(),
                      _ =>
                        actionTextEnController.text.trim().isEmpty
                            ? null
                            : actionTextEnController.text.trim(),
                    },
                    'filter_criteria': criteriaForUsers,
                    'scheduled_at': null,
                    'sent_at': null,
                    'status': 'draft',
                    'created_by': userId,
                  };
                }

                final List<Map<String, dynamic>> payload;
                if (selectedUserIds.isEmpty) {
                  payload = [
                    rowForLocale('en', const []),
                    rowForLocale('es', const []),
                    rowForLocale('he', const []),
                  ];
                  payload[0]['filter_criteria'] = criteriaFor('en');
                  payload[1]['filter_criteria'] = criteriaFor('es');
                  payload[2]['filter_criteria'] = criteriaFor('he');
                } else {
                  final result = await client.rpc(
                    'admin_get_user_ui_languages',
                    params: {'p_user_ids': selectedUserIds},
                  ).timeout(const Duration(seconds: 12));

                  final byLang = <String, List<String>>{
                    'en': [],
                    'es': [],
                    'he': [],
                  };

                  final unknown = <String>{...selectedUserIds};

                  if (result is List) {
                    for (final row in result) {
                      if (row is! Map) continue;
                      final m = Map<String, dynamic>.from(row);
                      final id = (m['user_id'] ?? m['id'] ?? '').toString().trim();
                      if (id.isEmpty) continue;
                      final lang = (m['ui_language'] ?? m['language'] ?? 'en')
                          .toString()
                          .trim()
                          .toLowerCase();
                      final normalized = (lang == 'es' || lang == 'he') ? lang : 'en';
                      byLang[normalized]!.add(id);
                      unknown.remove(id);
                    }
                  }

                  if (unknown.isNotEmpty) {
                    byLang['en'] = [...byLang['en']!, ...unknown];
                  }

                  payload = [
                    if (byLang['en']!.isNotEmpty) rowForLocale('en', byLang['en']!),
                    if (byLang['es']!.isNotEmpty) rowForLocale('es', byLang['es']!),
                    if (byLang['he']!.isNotEmpty) rowForLocale('he', byLang['he']!),
                  ];
                }

                await client.from('admin_broadcasts').insert(payload);
              } else {
                await client.from('admin_broadcasts').insert({
                  'title': titleEnController.text.trim(),
                  'message': messageEnController.text.trim(),
                  'message_type': type,
                  'action_url': actionUrlController.text.trim().isEmpty
                      ? null
                      : actionUrlController.text.trim(),
                  'action_url_text': actionTextEnController.text.trim().isEmpty
                      ? null
                      : actionTextEnController.text.trim(),
                  'filter_criteria': criteria,
                  'scheduled_at': null,
                  'sent_at': null,
                  'status': 'draft',
                  'created_by': userId,
                });
              }

              if (!mounted || !ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.getString('adminSaved'))),
              );
              unawaited(_load(force: true));
            } catch (_) {
              if (!mounted || !ctx.mounted) return;
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.getString('adminBroadcastsSaveFailed'))),
              );
            } finally {
              if (ctx.mounted) {
                setDialogState(() {
                  isSubmitting = false;
                });
              }
            }
          }

          final dialogTitle = existing == null
              ? l10n.getString('adminBroadcastsAdd')
              : l10n.getString('adminBroadcastsEdit');

          return Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 920,
                maxHeight: (MediaQuery.of(ctx).size.height -
                        MediaQuery.of(ctx).viewPadding.vertical) *
                    0.9,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      dialogTitle,
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      fit: FlexFit.loose,
                      child: Form(
                        key: formKey,
                        child: SingleChildScrollView(
                          padding: const EdgeInsetsDirectional.only(end: 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                      if (existing == null) const SizedBox(height: 8),
                      if (existing == null)
                        DropdownMenu<String>(
                          width: 420,
                          initialSelection: mode,
                          label: Text(l10n.getString('adminBroadcastsMode')),
                          dropdownMenuEntries: [
                            DropdownMenuEntry(
                              value: 'per_language',
                              label: l10n.getString('adminBroadcastsModePerLanguage'),
                            ),
                            DropdownMenuEntry(
                              value: 'single',
                              label: l10n.getString('adminBroadcastsModeSingle'),
                            ),
                          ],
                          onSelected: isSubmitting
                              ? null
                              : (v) => setDialogState(() {
                                    mode = v ?? 'single';
                                  }),
                        ),
                      if (existing == null) const SizedBox(height: 12),
                      DropdownMenu<String>(
                        width: 420,
                        initialSelection: type,
                        label: Text(l10n.getString('adminBroadcastsType')),
                        dropdownMenuEntries: const [
                          'info',
                          'warning',
                          'promotion',
                          'update',
                        ]
                            .map(
                              (t) => DropdownMenuEntry(
                                value: t,
                                label: _typeLabel(l10n, t),
                              ),
                            )
                            .toList(growable: false),
                        onSelected: isSubmitting
                            ? null
                            : (v) => setDialogState(() => typeController.value = v ?? 'info'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: actionUrlController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminBroadcastsActionUrl'),
                        ),
                        validator: (v) {
                          if (!looksLikeUrl(v ?? '')) {
                            return l10n.getString('adminBroadcastsActionUrlInvalid');
                          }
                          return null;
                        },
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 12),
                      Builder(
                        builder: (innerCtx) {
                          final criteria = parseCriteria();
                          final hasValidCriteria = criteria != null;
                          final safeCriteria = criteria ?? <String, dynamic>{};
                          final chips = buildCriteriaChips(safeCriteria);

                          if (!didInitTargetingCount) {
                            didInitTargetingCount = true;
                            if (criteria != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted || !ctx.mounted) return;
                                requestTargetingCount(ctx, setDialogState, criteria);
                              });
                            }
                          }
                          if (!didInitRecipientsUiLanguages) {
                            didInitRecipientsUiLanguages = true;
                            if (criteria != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted || !ctx.mounted) return;
                                requestRecipientsUiLanguages(ctx, setDialogState, criteria);
                              });
                            }
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      l10n.getString('adminBroadcastsTargetingTitle'),
                                      style: Theme.of(innerCtx).textTheme.titleSmall,
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: isSubmitting
                                        ? null
                                        : () async {
                                            final current = parseCriteria();
                                            if (current == null) {
                                              if (!innerCtx.mounted) return;
                                              ScaffoldMessenger.of(innerCtx).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    l10n.getString('adminBroadcastsInvalidJson'),
                                                  ),
                                                ),
                                              );
                                              return;
                                            }
                                            final initial = Map<String, dynamic>.from(current)
                                              ..remove('user_ids');
                                            final edited = await editTargetingFilters(
                                              initial: initial,
                                              allowUiLanguageFilters: true,
                                              uiLanguageDisplayNames: uiLanguageDisplayNames,
                                            );
                                            if (edited == null) return;
                                            setCriteria(edited);
                                          },
                                    icon: const Icon(Icons.tune_outlined),
                                    label: Text(l10n.getString('generalFilters')),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed: isSubmitting
                                        ? null
                                        : () async {
                                            Future<List<Map<String, dynamic>>> searchUsers({
                                              required String query,
                                              required int limit,
                                              required int offset,
                                            }) async {
                                              final result = await Supabase.instance.client.rpc(
                                                'admin_search_users',
                                                params: {
                                                  'p_query': query,
                                                  'p_limit': limit,
                                                  'p_offset': offset,
                                                },
                                              ).timeout(const Duration(seconds: 12));
                                              if (result is List) {
                                                return result
                                                    .whereType<Map>()
                                                    .map((e) => Map<String, dynamic>.from(e))
                                                    .toList();
                                              }
                                              return const [];
                                            }

                                            Future<List<String>?> pickRecipients(
                                              BuildContext dialogContext, {
                                              required List<String> initialUserIds,
                                            }) async {
                                              final initialSet = <String>{
                                                ...initialUserIds.map((e) => e.trim()).where((e) => e.isNotEmpty),
                                              };
                                              Timer? searchDebounce;

                                              try {
                                                return await showDialog<List<String>>(
                                                  context: dialogContext,
                                                  builder: (pickerCtx) {
                                                    final controller = TextEditingController();

                                                    String query = '';
                                                    bool isLoading = false;
                                                    bool loadFailed = false;
                                                    List<Map<String, dynamic>> results = const [];
                                                    final selected = <String>{...initialSet};

                                                    Future<void> load(StateSetter setState) async {
                                                      if (!pickerCtx.mounted) return;
                                                      setState(() {
                                                        isLoading = true;
                                                        loadFailed = false;
                                                      });
                                                      try {
                                                        final page = await searchUsers(
                                                          query: query,
                                                          limit: 50,
                                                          offset: 0,
                                                        );
                                                        if (!pickerCtx.mounted) return;
                                                        setState(() {
                                                          results = page;
                                                          isLoading = false;
                                                          loadFailed = false;
                                                        });
                                                      } catch (_) {
                                                        if (!pickerCtx.mounted) return;
                                                        setState(() {
                                                          isLoading = false;
                                                          loadFailed = true;
                                                        });
                                                      }
                                                    }

                                                    return StatefulBuilder(
                                                      builder: (pickerCtx, setState) {
                                                        if (results.isEmpty && !isLoading && !loadFailed) {
                                                          WidgetsBinding.instance.addPostFrameCallback((_) {
                                                            if (!pickerCtx.mounted) return;
                                                            load(setState);
                                                          });
                                                        }

                                                        void scheduleSearch(String next) {
                                                          query = next;
                                                          searchDebounce?.cancel();
                                                          searchDebounce = Timer(
                                                            const Duration(milliseconds: 300),
                                                            () => load(setState),
                                                          );
                                                          setState(() {});
                                                        }

                                                        final maxHeight = MediaQuery.of(pickerCtx).size.height -
                                                            MediaQuery.of(pickerCtx).viewPadding.vertical -
                                                            120;
                                                        final dialogHeight = maxHeight.clamp(360, 620).toDouble();

                                                        final body = isLoading
                                                            ? Center(
                                                                child: Text(
                                                                  l10n.getString('generalLoading'),
                                                                ),
                                                              )
                                                            : loadFailed
                                                                ? Center(
                                                                    child: Text(
                                                                      l10n.getString(
                                                                        'adminBroadcastsRecipientsLoadFailed',
                                                                      ),
                                                                      style: Theme.of(pickerCtx)
                                                                          .textTheme
                                                                          .bodyMedium
                                                                          ?.copyWith(
                                                                            color: Theme.of(pickerCtx)
                                                                                .colorScheme
                                                                                .error,
                                                                          ),
                                                                    ),
                                                                  )
                                                                : results.isEmpty
                                                                    ? Center(
                                                                        child: Text(
                                                                          l10n.getString(
                                                                            'adminBroadcastsRecipientsEmpty',
                                                                          ),
                                                                        ),
                                                                      )
                                                                    : ListView.separated(
                                                                        itemCount: results.length,
                                                                        separatorBuilder: (_, _) =>
                                                                            const Divider(height: 1),
                                                                        itemBuilder: (rowCtx, i) {
                                                                          final row = results[i];
                                                                          final id = (row['user_id'] ??
                                                                                  row['id'] ??
                                                                                  '')
                                                                              .toString()
                                                                              .trim();
                                                                          final name =
                                                                              (row['name'] ?? '').toString().trim();
                                                                          final displayName =
                                                                              maskUserDisplayName(name);
                                                                          final title = name.isEmpty ? id : displayName;
                                                                          final subtitle = name.isEmpty ? '' : id;
                                                                          final checked = selected.contains(id);
                                                                          return CheckboxListTile(
                                                                            value: checked,
                                                                            onChanged: (v) {
                                                                              if (v == true) {
                                                                                selected.add(id);
                                                                              } else {
                                                                                selected.remove(id);
                                                                              }
                                                                              setState(() {});
                                                                            },
                                                                            title: Text(title),
                                                                            subtitle: subtitle.isEmpty
                                                                                ? null
                                                                                : Text(subtitle),
                                                                            controlAffinity:
                                                                                ListTileControlAffinity.leading,
                                                                          );
                                                                        },
                                                                      );

                                                        return Dialog(
                                                          child: ConstrainedBox(
                                                            constraints: const BoxConstraints(maxWidth: 780),
                                                            child: SizedBox(
                                                              height: dialogHeight,
                                                              child: Column(
                                                                children: [
                                                                  Padding(
                                                                    padding: const EdgeInsets.fromLTRB(
                                                                        16, 12, 8, 8),
                                                                    child: Row(
                                                                      children: [
                                                                        Expanded(
                                                                          child: Text(
                                                                            l10n.getString(
                                                                              'adminBroadcastsRecipientsTitle',
                                                                            ),
                                                                            style: Theme.of(pickerCtx)
                                                                                .textTheme
                                                                                .titleLarge,
                                                                          ),
                                                                        ),
                                                                        IconButton(
                                                                          tooltip: l10n.getString('generalClose'),
                                                                          onPressed: () => Navigator.of(pickerCtx)
                                                                              .pop(null),
                                                                          icon: const Icon(Icons.close),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                  Padding(
                                                                    padding: const EdgeInsets.fromLTRB(
                                                                        16, 0, 16, 12),
                                                                    child: Column(
                                                                      crossAxisAlignment:
                                                                          CrossAxisAlignment.stretch,
                                                                      children: [
                                                                        TextField(
                                                                          controller: controller,
                                                                          onChanged: scheduleSearch,
                                                                          decoration: InputDecoration(
                                                                            labelText: l10n.getString(
                                                                              'adminBroadcastsRecipientsSearchLabel',
                                                                            ),
                                                                            prefixIcon:
                                                                                const Icon(Icons.search),
                                                                          ),
                                                                        ),
                                                                        const SizedBox(height: 8),
                                                                        Text(
                                                                          l10n
                                                                              .getString(
                                                                                'adminBroadcastsRecipientsSelectedValue',
                                                                              )
                                                                              .replaceAll(
                                                                                '{count}',
                                                                                selected.length.toString(),
                                                                              ),
                                                                          style: Theme.of(pickerCtx)
                                                                              .textTheme
                                                                              .bodySmall,
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                  const Divider(height: 1),
                                                                  Expanded(child: body),
                                                                  const Divider(height: 1),
                                                                  Padding(
                                                                    padding: const EdgeInsets.fromLTRB(
                                                                        16, 10, 16, 12),
                                                                    child: Row(
                                                                      children: [
                                                                        TextButton(
                                                                          onPressed: selected.isEmpty
                                                                              ? null
                                                                              : () {
                                                                                  selected.clear();
                                                                                  setState(() {});
                                                                                },
                                                                          child: Text(
                                                                            l10n.getString('generalClear'),
                                                                          ),
                                                                        ),
                                                                        const Spacer(),
                                                                        TextButton(
                                                                          onPressed: () => Navigator.of(pickerCtx)
                                                                              .pop(null),
                                                                          child: Text(
                                                                            l10n.getString('generalCancel'),
                                                                          ),
                                                                        ),
                                                                        const SizedBox(width: 8),
                                                                        FilledButton(
                                                                          onPressed: () => Navigator.of(pickerCtx)
                                                                              .pop(
                                                                            selected.toList(growable: false),
                                                                          ),
                                                                          child: Text(
                                                                            l10n.getString('generalApply'),
                                                                          ),
                                                                        ),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    );
                                                  },
                                                );
                                              } finally {
                                                searchDebounce?.cancel();
                                              }
                                            }

                                            final current = parseCriteria();
                                            if (current == null) {
                                              if (!innerCtx.mounted) return;
                                              ScaffoldMessenger.of(innerCtx).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    l10n.getString('adminBroadcastsInvalidJson'),
                                                  ),
                                                ),
                                              );
                                              return;
                                            }

                                            final picked = await pickRecipients(
                                              innerCtx,
                                              initialUserIds: asStringList(current['user_ids']),
                                            );
                                            if (picked == null) return;
                                            final next = <String, dynamic>{
                                              if (picked.isNotEmpty) 'user_ids': picked,
                                            };
                                            setCriteria(next);
                                          },
                                    icon: const Icon(Icons.person_search_outlined),
                                    label: Text(l10n.getString('adminBroadcastsRecipientsButton')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (!hasValidCriteria)
                                Text(
                                  l10n.getString('adminBroadcastsInvalidJson'),
                                  style: Theme.of(innerCtx).textTheme.bodyMedium?.copyWith(
                                        color: Theme.of(innerCtx).colorScheme.error,
                                      ),
                                )
                              else if (chips.isEmpty)
                                Text(l10n.getString('adminBroadcastsTargetingEmpty'))
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: chips,
                                ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: isSubmitting
                                        ? null
                                        : () => setCriteria(<String, dynamic>{}),
                                    child: Text(l10n.getString('generalClear')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  if (isTargetingCounting)
                                    const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  if (isTargetingCounting) const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      isTargetingCounting
                                          ? l10n.getString('generalLoading')
                                          : targetingCount == null
                                              ? l10n.getString('adminBroadcastsTargetUnknown')
                                              : l10n
                                                  .getString('adminBroadcastsTargetCountValue')
                                                  .replaceAll(
                                                    '{count}',
                                                    targetingCount.toString(),
                                                  ),
                                      style: Theme.of(innerCtx).textTheme.bodyMedium?.copyWith(
                                            color: (!hasValidCriteria ||
                                                        targetingCountFailed ||
                                                        targetingCount == null) &&
                                                    !isTargetingCounting
                                                ? Theme.of(innerCtx).colorScheme.error
                                                : null,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  OutlinedButton(
                                    onPressed: (!hasValidCriteria ||
                                            isTargetingCounting ||
                                            targetingCount == null ||
                                            targetingCount == 0)
                                        ? null
                                        : () async {
                                            await _openTargetUsersList(
                                              l10n: l10n,
                                              criteria: deepCloneCriteria(safeCriteria),
                                              targetCount: targetingCount,
                                              listLimit: 50,
                                            );
                                          },
                                    child: Text(l10n.getString('adminBroadcastsViewUsers')),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      if (isPerLanguage)
                        Builder(
                          builder: (innerCtx) {
                            final criteria = parseCriteria();
                            final userIds = asStringList(criteria?['user_ids']);
                            final shouldLimitByRecipients =
                                userIds.isNotEmpty && !recipientsUiLanguagesFailed;
                            final allowed = shouldLimitByRecipients
                                ? (recipientsUiLanguages ?? const <String>{})
                                : const <String>{'en', 'es', 'he'};

                            final locales = <String>['en', 'es', 'he']
                                .where((e) => allowed.contains(e))
                                .toList(growable: false);
                            final safeLocales =
                                locales.isEmpty ? const <String>['en'] : locales;

                            Widget editorForLocale(String locale) {
                              return switch (locale) {
                                'es' => _BroadcastLanguageEditor(
                                    l10n: l10n,
                                    titleController: titleEsController,
                                    messageController: messageEsController,
                                    actionTextController: actionTextEsController,
                                    preview: previewEs,
                                    isSubmitting: isSubmitting,
                                    onChanged: () => setDialogState(() {}),
                                  ),
                                'he' => _BroadcastLanguageEditor(
                                    l10n: l10n,
                                    titleController: titleHeController,
                                    messageController: messageHeController,
                                    actionTextController: actionTextHeController,
                                    preview: previewHe,
                                    isSubmitting: isSubmitting,
                                    onChanged: () => setDialogState(() {}),
                                  ),
                                _ => _BroadcastLanguageEditor(
                                    l10n: l10n,
                                    titleController: titleEnController,
                                    messageController: messageEnController,
                                    actionTextController: actionTextEnController,
                                    preview: previewEn,
                                    isSubmitting: isSubmitting,
                                    onChanged: () => setDialogState(() {}),
                                  ),
                              };
                            }

                            if (shouldLimitByRecipients &&
                                recipientsUiLanguages == null &&
                                isRecipientsUiLanguagesLoading) {
                              return SizedBox(
                                height: 520,
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(l10n.getString('generalLoading')),
                                    ],
                                  ),
                                ),
                              );
                            }

                            if (safeLocales.length == 1) {
                              return SizedBox(
                                height: 520,
                                child: editorForLocale(safeLocales.first),
                              );
                            }

                            return DefaultTabController(
                              length: safeLocales.length,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TabBar(
                                    tabs: safeLocales
                                        .map(
                                          (locale) => Tab(
                                            text: uiLanguageName(
                                              locale,
                                              uiLanguageDisplayNames,
                                            ),
                                          ),
                                        )
                                        .toList(growable: false),
                                  ),
                                  SizedBox(
                                    height: 520,
                                    child: TabBarView(
                                      children: safeLocales
                                          .map(editorForLocale)
                                          .toList(growable: false),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )
                      else
                        Column(
                          children: [
                            TextFormField(
                              controller: titleEnController,
                              decoration: InputDecoration(
                                labelText: l10n.getString('adminBroadcastsTitle'),
                              ),
                              validator: (v) {
                                if ((v ?? '').trim().isEmpty) {
                                  return l10n.getString('adminBroadcastsTitleRequired');
                                }
                                return null;
                              },
                              onChanged: (_) => setDialogState(() {}),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: messageEnController,
                              maxLines: 4,
                              decoration: InputDecoration(
                                labelText: l10n.getString('adminBroadcastsMessage'),
                              ),
                              validator: (v) {
                                if ((v ?? '').trim().isEmpty) {
                                  return l10n.getString('adminBroadcastsMessageRequired');
                                }
                                return null;
                              },
                              onChanged: (_) => setDialogState(() {}),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: actionTextEnController,
                              decoration: InputDecoration(
                                labelText: l10n.getString('adminBroadcastsActionUrlText'),
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                l10n.getString('adminBroadcastsPreview'),
                                style: Theme.of(ctx).textTheme.titleSmall,
                              ),
                            ),
                            const SizedBox(height: 8),
                            previewEn,
                          ],
                        ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                          child: Text(l10n.getString('generalCancel')),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: isSubmitting ? null : submit,
                          child: isSubmitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(l10n.getString('generalSave')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    targetingCountDebounce?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final filtered = _rows.where(_matchesFilters).toList(growable: false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  decoration: InputDecoration(
                    labelText: l10n.getString('adminBroadcastsSearchHint'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownMenu<String>(
                  width: 220,
                  initialSelection: _status,
                  label: Text(l10n.getString('adminBroadcastsStatus')),
                  dropdownMenuEntries: const [
                    'all',
                    'draft',
                    'scheduled',
                    'sending',
                    'sent',
                    'failed',
                  ]
                      .map(
                        (s) => DropdownMenuEntry(
                          value: s,
                          label: _statusLabel(l10n, s),
                        ),
                      )
                      .toList(growable: false),
                  onSelected: (v) => setState(() => _status = v ?? 'all'),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownMenu<String>(
                  width: 220,
                  initialSelection: _timeFilter,
                  label: Text(l10n.getString('adminBroadcastsTimeFilter')),
                  dropdownMenuEntries: const [
                    'all',
                    'upcoming',
                    'past',
                  ]
                      .map(
                        (t) => DropdownMenuEntry(
                          value: t,
                          label: _timeFilterLabel(l10n, t),
                        ),
                      )
                      .toList(growable: false),
                  onSelected: (v) => setState(() => _timeFilter = v ?? 'all'),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : () => _showEditor(l10n),
                icon: const Icon(Icons.add),
                label: Text(l10n.getString('adminBroadcastsAdd')),
              ),
              OutlinedButton.icon(
                onPressed: _isLoading ? null : () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.getString('generalRefresh')),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _isLoading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(l10n.getString('generalLoading')),
                    ],
                  ),
                )
              : _errorKey != null
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                l10n.getString(_errorKey!),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: () => _load(force: true),
                                icon: const Icon(Icons.refresh),
                                label: Text(l10n.getString('generalRefresh')),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : filtered.isEmpty
                      ? Center(child: Text(l10n.getString('adminBroadcastsEmpty')))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final row = filtered[index];
                            final scheduled = row.scheduledAt == null
                                ? ''
                                : _formatAdminDateTime(l10n, row.scheduledAt!);
                            final sent =
                                row.sentAt == null ? '' : _formatAdminDateTime(l10n, row.sentAt!);
                            final lang = (row.filterCriteria['ui_language'] ?? '').toString().trim();

                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              row.title.trim().isEmpty ? row.id : row.title,
                                              style: Theme.of(context).textTheme.titleMedium,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _MetaChip(
                                            label: l10n.getString('adminBroadcastsStatus'),
                                            value: _statusLabel(l10n, row.status),
                                          ),
                                          const SizedBox(width: 8),
                                          _MetaChip(
                                            label: l10n.getString('adminBroadcastsType'),
                                            value: _typeLabel(l10n, row.messageType),
                                          ),
                                          if (lang.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            _MetaChip(
                                              label: l10n.getString('adminBroadcastsLanguage'),
                                              value: lang.toUpperCase(),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        row.message,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          if (scheduled.isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString('adminBroadcastsScheduledAt'),
                                              value: scheduled,
                                            ),
                                          if (sent.isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString('adminBroadcastsSentAt'),
                                              value: sent,
                                            ),
                                          if (row.targetUserCount != null)
                                            _MetaChip(
                                              label: l10n.getString('adminBroadcastsTargetCount'),
                                              value: row.targetUserCount.toString(),
                                            ),
                                          if (row.actualSentCount > 0)
                                            _MetaChip(
                                              label: l10n.getString('adminBroadcastsActualSent'),
                                              value: row.actualSentCount.toString(),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () => _showDetails(l10n, row),
                                            icon: const Icon(Icons.open_in_new),
                                            label: Text(
                                              l10n.getString('adminBroadcastsDetails'),
                                            ),
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: row.status == 'draft'
                                                ? () => _showEditor(l10n, existing: row)
                                                : null,
                                            icon: const Icon(Icons.edit),
                                            label: Text(l10n.getString('generalEdit')),
                                          ),
                                          if (row.status == 'draft')
                                            ElevatedButton.icon(
                                              onPressed: () => _scheduleDraft(l10n, row),
                                              icon: const Icon(Icons.schedule),
                                              label: Text(l10n.getString('adminBroadcastsSchedule')),
                                            ),
                                          if (row.status == 'draft')
                                            ElevatedButton.icon(
                                              onPressed: () => _sendNow(l10n, row),
                                              icon: const Icon(Icons.send),
                                              label: Text(l10n.getString('adminBroadcastsSendNow')),
                                            ),
                                          if (row.status == 'sent')
                                            ElevatedButton.icon(
                                              onPressed: () => _resendNow(l10n, row),
                                              icon: const Icon(Icons.send),
                                              label: Text(l10n.getString('adminBroadcastsResendNow')),
                                            ),
                                          if (row.status == 'sent')
                                            OutlinedButton.icon(
                                              onPressed: () => _rescheduleSent(l10n, row),
                                              icon: const Icon(Icons.schedule),
                                              label: Text(l10n.getString('adminBroadcastsReschedule')),
                                            ),
                                          TextButton.icon(
                                            onPressed: () => _delete(l10n, row),
                                            icon: const Icon(Icons.delete_outline),
                                            label: Text(l10n.getString('generalDelete')),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

class _BroadcastLanguageEditor extends StatelessWidget {
  final LocalizationState l10n;
  final TextEditingController titleController;
  final TextEditingController messageController;
  final TextEditingController actionTextController;
  final Widget preview;
  final bool isSubmitting;
  final VoidCallback onChanged;

  const _BroadcastLanguageEditor({
    required this.l10n,
    required this.titleController,
    required this.messageController,
    required this.actionTextController,
    required this.preview,
    required this.isSubmitting,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          TextFormField(
            controller: titleController,
            decoration: InputDecoration(
              labelText: l10n.getString('adminBroadcastsTitle'),
            ),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) {
                return l10n.getString('adminBroadcastsTitleRequired');
              }
              return null;
            },
            enabled: !isSubmitting,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: messageController,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: l10n.getString('adminBroadcastsMessage'),
            ),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) {
                return l10n.getString('adminBroadcastsMessageRequired');
              }
              return null;
            },
            enabled: !isSubmitting,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: actionTextController,
            decoration: InputDecoration(
              labelText: l10n.getString('adminBroadcastsActionUrlText'),
            ),
            enabled: !isSubmitting,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.getString('adminBroadcastsPreview'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: SingleChildScrollView(child: preview)),
        ],
      ),
    );
  }
}

class _TranslationKeyGroup {
  final String key;
  final String en;
  final String es;
  final String he;

  const _TranslationKeyGroup({
    required this.key,
    required this.en,
    required this.es,
    required this.he,
  });

  bool get isMissingAny =>
      en.trim().isEmpty || es.trim().isEmpty || he.trim().isEmpty;

  bool isMissingLocale(String locale) {
    return switch (locale) {
      'en' => en.trim().isEmpty,
      'es' => es.trim().isEmpty,
      'he' => he.trim().isEmpty,
      _ => false,
    };
  }
}

enum _BulkDelimiterMode { auto, tab, pipe }

class _TranslationsScreen extends ConsumerStatefulWidget {
  const _TranslationsScreen();

  @override
  ConsumerState<_TranslationsScreen> createState() => _TranslationsScreenState();
}

class _TranslationsScreenState extends ConsumerState<_TranslationsScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_TranslationKeyGroup> _groups = const [];

  String _query = '';
  bool _missingAnyOnly = false;
  String _missingLocale = 'all';

  late final Future<Map<String, String>> _uiLanguageDisplayNamesFuture =
      loadUiLanguageDisplayNames();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    List<Map<String, dynamic>> decodeListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final cacheKey = 'admin_cache:translations_screen:groups:v1';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<List<Map<String, dynamic>>>(
        cacheKey,
        decodeListMap,
      );
      if (!mounted) return;
      if (cached != null) {
        final list = cached.data
            .map(
              (m) => _TranslationKeyGroup(
                key: (m['key'] ?? '').toString(),
                en: (m['en'] ?? '').toString(),
                es: (m['es'] ?? '').toString(),
                he: (m['he'] ?? '').toString(),
              ),
            )
            .toList(growable: false)
          ..sort((a, b) => a.key.compareTo(b.key));
        setState(() {
          _groups = list;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final rows = await Supabase.instance.client
          .from('translations')
          .select('locale, key, value')
          .inFilter('locale', const ['en', 'es', 'he'])
          .timeout(const Duration(seconds: 12));

      final byKey = <String, Map<String, String>>{};

      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final locale = (row['locale'] as String?) ?? '';
        final key = (row['key'] as String?) ?? '';
        final value = (row['value'] as String?) ?? '';
        if (locale.isEmpty || key.isEmpty) continue;

        (byKey[key] ??= <String, String>{})[locale] = value;
      }

      final list = byKey.entries
          .map(
            (e) => _TranslationKeyGroup(
              key: e.key,
              en: e.value['en'] ?? '',
              es: e.value['es'] ?? '',
              he: e.value['he'] ?? '',
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.key.compareTo(b.key));

      final cachePayload = list
          .map(
            (g) => <String, String>{
              'key': g.key,
              'en': g.en,
              'es': g.es,
              'he': g.he,
            },
          )
          .toList(growable: false);
      await _AdminCache.write<List<Map<String, dynamic>>>(
        cacheKey,
        (v) => v,
        cachePayload,
      );

      if (!mounted) return;
      setState(() {
        _groups = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminTranslationsLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminTranslationsLoadFailed';
          _isLoading = false;
        });
      }
    }
  }

  List<_TranslationKeyGroup> _filtered() {
    final q = _query.trim().toLowerCase();

    bool matchesQuery(_TranslationKeyGroup g) {
      if (q.isEmpty) return true;
      return g.key.toLowerCase().contains(q) ||
          g.en.toLowerCase().contains(q) ||
          g.es.toLowerCase().contains(q) ||
          g.he.toLowerCase().contains(q);
    }

    bool matchesMissing(_TranslationKeyGroup g) {
      if (_missingAnyOnly && !g.isMissingAny) return false;
      if (_missingLocale == 'all') return true;
      return g.isMissingLocale(_missingLocale);
    }

    return _groups
        .where((g) => matchesQuery(g) && matchesMissing(g))
        .toList(growable: false);
  }

  Future<void> _upsertGroup({
    _TranslationKeyGroup? existing,
    Map<String, String>? uiLanguageDisplayNames,
  }) async {
    final l10n = ref.read(localizationProvider);
    final formKey = GlobalKey<FormState>();
    final names = uiLanguageDisplayNames ?? const <String, String>{};

    String uiLanguageName(String code) {
      final normalized = code.trim().toLowerCase();
      return names[normalized] ??
          uiLanguageNameFallback(l10n, normalized);
    }

    final keyController = TextEditingController(text: existing?.key ?? '');
    final enController = TextEditingController(text: existing?.en ?? '');
    final esController = TextEditingController(text: existing?.es ?? '');
    final heController = TextEditingController(text: existing?.he ?? '');

    var isSubmitting = false;

    Future<void> submit(
      BuildContext dialogCtx,
      void Function(void Function()) setDialogState,
    ) async {
      if (!(formKey.currentState?.validate() ?? false)) return;

      if (!dialogCtx.mounted) return;
      setDialogState(() {
        isSubmitting = true;
      });

      try {
        final key = keyController.text.trim();
        final payload = [
          {'locale': 'en', 'key': key, 'value': enController.text},
          {'locale': 'es', 'key': key, 'value': esController.text},
          {'locale': 'he', 'key': key, 'value': heController.text},
        ];

        await Supabase.instance.client.rpc(
          'admin_bulk_upsert_translations',
          params: {'p_items': payload},
      ).timeout(const Duration(seconds: 20));

        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
        ref
            .read(localizationProvider.notifier)
            .setLocale(l10n.locale.languageCode);
        unawaited(_load(force: true));
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() {
          isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminTranslationsSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isEditing = existing != null;
          return AlertDialog(
            title: Text(
              isEditing
                  ? l10n.getString('adminTranslationsEditKey')
                  : l10n.getString('adminTranslationsAddKey'),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: keyController,
                        enabled: !isEditing,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminTranslationsKey'),
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) {
                            return l10n.getString('adminTranslationsKeyRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: enController,
                        decoration: InputDecoration(
                          labelText: uiLanguageName('en'),
                        ),
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: esController,
                        decoration: InputDecoration(
                          labelText: uiLanguageName('es'),
                        ),
                        maxLines: null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: heController,
                        decoration: InputDecoration(
                          labelText: uiLanguageName('he'),
                        ),
                        textDirection: TextDirection.rtl,
                        textAlign: TextAlign.right,
                        maxLines: null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              FilledButton(
                onPressed:
                    isSubmitting ? null : () => submit(ctx, setDialogState),
                child: isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('generalSave')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteGroup(_TranslationKeyGroup group) async {
    final l10n = ref.read(localizationProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('adminTranslationsDeleteTitle')),
        content: Text(
          l10n
              .getString('adminTranslationsDeleteBody')
              .replaceAll('{key}', group.key),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _groups = _groups.where((g) => g.key != group.key).toList(growable: false);
    });

    try {
      await Supabase.instance.client.rpc(
        'admin_delete_translation_key',
        params: {'p_key': group.key},
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      ref
          .read(localizationProvider.notifier)
          .setLocale(l10n.locale.languageCode);
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      unawaited(_load(force: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminTranslationsDeleteFailed'))),
      );
    }
  }

  Future<void> _bulkImport() async {
    final l10n = ref.read(localizationProvider);

    final textController = TextEditingController();
    var delimiter = _BulkDelimiterMode.auto;
    var allowEmptyValues = false;
    var parsedCount = 0;

    List<Map<String, String>> parseNow() {
      final raw = textController.text;
      final lines = const LineSplitter()
          .convert(raw)
          .map((l) => l.trimRight())
          .where((l) => l.trim().isNotEmpty)
          .toList(growable: false);

      if (lines.isEmpty) return const [];

      String detectDelimiter(String line) {
        if (delimiter == _BulkDelimiterMode.tab) return '\t';
        if (delimiter == _BulkDelimiterMode.pipe) return '|';
        if (line.contains('\t')) return '\t';
        return '|';
      }

      final items = <Map<String, String>>[];
      for (final line in lines) {
        final delim = detectDelimiter(line);
        final parts = line.split(delim).map((p) => p.trim()).toList(growable: false);
        if (parts.length < 2) continue;

        final key = parts[0];
        if (key.isEmpty) continue;

        String partAt(int i) => i < parts.length ? parts[i] : '';

        final en = partAt(1);
        final es = partAt(2);
        final he = partAt(3);

        if (allowEmptyValues) {
          items.add({'locale': 'en', 'key': key, 'value': en});
          items.add({'locale': 'es', 'key': key, 'value': es});
          items.add({'locale': 'he', 'key': key, 'value': he});
          continue;
        }

        if (en.isNotEmpty) items.add({'locale': 'en', 'key': key, 'value': en});
        if (es.isNotEmpty) items.add({'locale': 'es', 'key': key, 'value': es});
        if (he.isNotEmpty) items.add({'locale': 'he', 'key': key, 'value': he});
      }

      return items;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final items = parseNow();
          parsedCount = items.length;

          return AlertDialog(
            title: Text(l10n.getString('adminTranslationsBulkImportTitle')),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.getString('adminTranslationsBulkImportFormat')),
                    const SizedBox(height: 12),
                    DropdownMenu<_BulkDelimiterMode>(
                      initialSelection: delimiter,
                      dropdownMenuEntries: [
                        DropdownMenuEntry(
                          value: _BulkDelimiterMode.auto,
                          label: l10n.getString(
                            'adminTranslationsBulkImportDelimiterAuto',
                          ),
                        ),
                        DropdownMenuEntry(
                          value: _BulkDelimiterMode.tab,
                          label:
                              l10n.getString('adminTranslationsBulkImportDelimiterTab'),
                        ),
                        DropdownMenuEntry(
                          value: _BulkDelimiterMode.pipe,
                          label:
                              l10n.getString('adminTranslationsBulkImportDelimiterPipe'),
                        ),
                      ],
                      onSelected: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          delimiter = value;
                        });
                      },
                      label: Text(
                        l10n.getString('adminTranslationsBulkImportDelimiter'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: allowEmptyValues,
                      onChanged: (v) {
                        setDialogState(() {
                          allowEmptyValues = v ?? false;
                        });
                      },
                      title: Text(
                        l10n.getString('adminTranslationsBulkImportAllowEmpty'),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: textController,
                      maxLines: 12,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        hintText: l10n.getString('adminTranslationsBulkImportHint'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n
                          .getString('adminTranslationsBulkImportParsedCount')
                          .replaceAll('{count}', parsedCount.toString()),
                      style: Theme.of(ctx).textTheme.labelLarge,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              FilledButton(
                onPressed: parsedCount == 0
                    ? null
                    : () async {
                        try {
                          final payload = parseNow();
                          if (payload.isEmpty) {
                            if (!ctx.mounted) return;
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.getString(
                                    'adminTranslationsBulkImportNothingParsed',
                                  ),
                                ),
                              ),
                            );
                            return;
                          }

                          await Supabase.instance.client.rpc(
                            'admin_bulk_upsert_translations',
                            params: {'p_items': payload},
                          ).timeout(const Duration(seconds: 20));

                          if (!mounted || !ctx.mounted) return;
                          Navigator.of(ctx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.getString('adminSaved'))),
                          );
                          ref
                              .read(localizationProvider.notifier)
                              .setLocale(l10n.locale.languageCode);
                          unawaited(_load(force: true));
                        } catch (_) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.getString('adminTranslationsSaveFailed'),
                              ),
                            ),
                          );
                        }
                      },
                child: Text(l10n.getString('adminTranslationsBulkImportImport')),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final filtered = _filtered();

    return FutureBuilder<Map<String, String>>(
      future: _uiLanguageDisplayNamesFuture,
      builder: (context, snapshot) {
        final uiLanguageDisplayNames = snapshot.data ?? const <String, String>{};
        String uiLanguageName(String code) {
          final normalized = code.trim().toLowerCase();
          return uiLanguageDisplayNames[normalized] ??
              uiLanguageNameFallback(l10n, normalized);
        }

        return Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n
                          .getString('adminTranslationsCount')
                          .replaceAll('{count}', filtered.length.toString()),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : () => _load(force: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.getString('generalRefresh')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isLoading
                          ? null
                          : () => _upsertGroup(
                                uiLanguageDisplayNames: uiLanguageDisplayNames,
                              ),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.getString('adminTranslationsAddKey')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _bulkImport,
                      icon: const Icon(Icons.playlist_add),
                      label: Text(l10n.getString('adminTranslationsBulkImport')),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: TextField(
                        onChanged: (v) {
                          setState(() {
                            _query = v;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: l10n.getString('adminTranslationsSearchHint'),
                          prefixIcon: const Icon(Icons.search),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    DropdownMenu<String>(
                      initialSelection: _missingLocale,
                      dropdownMenuEntries: [
                        DropdownMenuEntry(
                          value: 'all',
                          label: l10n.getString('adminTranslationsAll'),
                        ),
                        DropdownMenuEntry(
                          value: 'en',
                          label: uiLanguageName('en'),
                        ),
                        DropdownMenuEntry(
                          value: 'es',
                          label: uiLanguageName('es'),
                        ),
                        DropdownMenuEntry(
                          value: 'he',
                          label: uiLanguageName('he'),
                        ),
                      ],
                      onSelected: (value) {
                        if (value == null) return;
                        setState(() {
                          _missingLocale = value;
                        });
                      },
                      label:
                          Text(l10n.getString('adminTranslationsMissingLocale')),
                    ),
                    FilterChip(
                      selected: _missingAnyOnly,
                      onSelected: (v) {
                        setState(() {
                          _missingAnyOnly = v;
                        });
                      },
                      label: Text(l10n.getString('adminTranslationsMissingAny')),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorKey != null
                          ? Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 520),
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        l10n.getString(_errorKey!),
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 12),
                                      OutlinedButton.icon(
                                        onPressed: () => _load(force: true),
                                        icon: const Icon(Icons.refresh),
                                        label: Text(
                                          l10n.getString('generalRefresh'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final g = filtered[index];
                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                g.key,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleSmall,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  l10n.getString('generalEdit'),
                                              onPressed: () => _upsertGroup(
                                                existing: g,
                                                uiLanguageDisplayNames:
                                                    uiLanguageDisplayNames,
                                              ),
                                              icon: const Icon(Icons.edit),
                                            ),
                                            IconButton(
                                              tooltip: l10n
                                                  .getString('generalDelete'),
                                              onPressed: () => _deleteGroup(g),
                                              icon: const Icon(
                                                  Icons.delete_outline),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        _KeyPreviewRow(
                                          title: uiLanguageName('en'),
                                          value: g.en,
                                        ),
                                        _KeyPreviewRow(
                                          title: uiLanguageName('es'),
                                          value: g.es,
                                        ),
                                        _KeyPreviewRow(
                                          title: uiLanguageName('he'),
                                          value: g.he,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AdminAppConfigEntry {
  final int id;
  final String configKey;
  final dynamic configValue;
  final String configType;
  final String category;
  final String description;
  final bool isUserConfigurable;
  final num? minValue;
  final num? maxValue;
  final dynamic allowedValues;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const _AdminAppConfigEntry({
    required this.id,
    required this.configKey,
    required this.configValue,
    required this.configType,
    required this.category,
    required this.description,
    required this.isUserConfigurable,
    required this.minValue,
    required this.maxValue,
    required this.allowedValues,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _AdminAppConfigEntry.fromRow(Map<String, dynamic> row) {
    num? tryNum(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      return num.tryParse(v.toString());
    }

    DateTime? tryDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return _AdminAppConfigEntry(
      id: (row['id'] as int?) ?? 0,
      configKey: (row['config_key'] as String?) ?? '',
      configValue: row['config_value'],
      configType: (row['config_type'] as String?) ?? '',
      category: (row['category'] as String?) ?? '',
      description: (row['description'] as String?) ?? '',
      isUserConfigurable: (row['is_user_configurable'] as bool?) ?? false,
      minValue: tryNum(row['min_value']),
      maxValue: tryNum(row['max_value']),
      allowedValues: row['allowed_values'],
      createdAt: tryDate(row['created_at']),
      updatedAt: tryDate(row['updated_at']),
    );
  }
}

class _AppConfigScreen extends ConsumerStatefulWidget {
  const _AppConfigScreen();

  @override
  ConsumerState<_AppConfigScreen> createState() => _AppConfigScreenState();
}

class _AppConfigScreenState extends ConsumerState<_AppConfigScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_AdminAppConfigEntry> _entries = const [];

  String _query = '';
  String? _category;
  bool? _userConfigurable;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    List<Map<String, dynamic>> decodeListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final cacheKey = 'admin_cache:app_config:v1';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<List<Map<String, dynamic>>>(
        cacheKey,
        decodeListMap,
      );
      if (!mounted) return;
      if (cached != null) {
        final list = cached.data
            .map((r) => _AdminAppConfigEntry.fromRow(r))
            .toList(growable: false)
          ..sort((a, b) => a.configKey.compareTo(b.configKey));
        setState(() {
          _entries = list;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select(
            'id, config_key, config_value, config_type, category, description, is_user_configurable, min_value, max_value, allowed_values, created_at, updated_at',
          );

      final raw = rows
          .map((r) => Map<String, dynamic>.from(r))
          .toList(growable: false);
      await _AdminCache.write<List<Map<String, dynamic>>>(
        cacheKey,
        (v) => v,
        raw,
      );

      final list = raw
          .map((r) => _AdminAppConfigEntry.fromRow(r))
          .toList(growable: false);
      list.sort((a, b) => a.configKey.compareTo(b.configKey));

      if (!mounted) return;
      setState(() {
        _entries = list;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminAppConfigLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminAppConfigLoadFailed';
          _isLoading = false;
        });
      }
    }
  }

  dynamic _normalizeJsonValue(dynamic value) {
    if (value == null) return null;
    if (value is num || value is bool || value is String) return value;
    if (value is List) {
      return value.map(_normalizeJsonValue).toList(growable: false);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value)
          .map((k, v) => MapEntry(k, _normalizeJsonValue(v)));
    }
    return value.toString();
  }

  String _formatJsonValue(dynamic value) {
    final normalized = _normalizeJsonValue(value);
    try {
      final encoded = jsonEncode(normalized);
      return encoded;
    } catch (_) {
      return (value ?? '').toString();
    }
  }

  Future<void> _upsertEntry({_AdminAppConfigEntry? existing}) async {
    final l10n = ref.read(localizationProvider);

    final formKey = GlobalKey<FormState>();

    final keyController = TextEditingController(text: existing?.configKey ?? '');
    final valueController = TextEditingController(
      text: existing == null ? '' : _formatJsonValue(existing.configValue),
    );
    final typeController = TextEditingController(text: existing?.configType ?? '');
    final categoryController = TextEditingController(text: existing?.category ?? '');
    final descriptionController =
        TextEditingController(text: existing?.description ?? '');
    final minController = TextEditingController(
      text: existing?.minValue == null ? '' : existing!.minValue.toString(),
    );
    final maxController = TextEditingController(
      text: existing?.maxValue == null ? '' : existing!.maxValue.toString(),
    );
    final allowedValuesController = TextEditingController(
      text: existing?.allowedValues == null
          ? ''
          : _formatJsonValue(existing!.allowedValues),
    );

    var isUserConfigurable = existing?.isUserConfigurable ?? false;
    var isSubmitting = false;

    dynamic parseJsonFlexible(String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      try {
        return jsonDecode(trimmed);
      } catch (_) {
        return trimmed;
      }
    }

    Future<void> submit(
      BuildContext dialogCtx,
      void Function(void Function()) setDialogState,
    ) async {
      if (!(formKey.currentState?.validate() ?? false)) return;

      if (!dialogCtx.mounted) return;
      setDialogState(() {
        isSubmitting = true;
      });

      try {
        final configKey = keyController.text.trim();

        final payload = <String, dynamic>{
          'config_key': configKey,
          'config_value': parseJsonFlexible(valueController.text),
          'config_type': typeController.text.trim(),
          'category': categoryController.text.trim(),
          'description': descriptionController.text.trim(),
          'is_user_configurable': isUserConfigurable,
          'min_value': num.tryParse(minController.text.trim()),
          'max_value': num.tryParse(maxController.text.trim()),
          'allowed_values': parseJsonFlexible(allowedValuesController.text),
        };

        await Supabase.instance.client.from('app_config').upsert(
              payload,
              onConflict: 'config_key',
            ).timeout(const Duration(seconds: 20));

        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
        unawaited(_load(force: true));
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() {
          isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminAppConfigSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text(
              l10n.getString(existing == null
                  ? 'adminAppConfigAdd'
                  : 'adminAppConfigEdit'),
            ),
            content: SizedBox(
              width: 720,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: keyController,
                        enabled: existing == null,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigKey'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString('adminAppConfigKeyRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: valueController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigValue'),
                        ),
                        minLines: 3,
                        maxLines: 10,
                        validator: (v) {
                          final raw = (v ?? '').trim();
                          if (raw.isEmpty) {
                            return l10n.getString('adminAppConfigValueRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: typeController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigType'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString('adminAppConfigTypeRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: categoryController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigCategory'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString('adminAppConfigCategoryRequired');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: descriptionController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigDescription'),
                        ),
                        minLines: 2,
                        maxLines: 6,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString(
                              'adminAppConfigDescriptionRequired',
                            );
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        value: isUserConfigurable,
                        onChanged: (v) {
                          setDialogState(() {
                            isUserConfigurable = v;
                          });
                        },
                        title: Text(
                          l10n.getString('adminAppConfigIsUserConfigurable'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: minController,
                              decoration: InputDecoration(
                                labelText: l10n.getString('adminAppConfigMinValue'),
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: maxController,
                              decoration: InputDecoration(
                                labelText: l10n.getString('adminAppConfigMaxValue'),
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: allowedValuesController,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminAppConfigAllowedValues'),
                        ),
                        minLines: 2,
                        maxLines: 8,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              ElevatedButton(
                onPressed:
                    isSubmitting ? null : () => submit(ctx, setDialogState),
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('generalSave')),
              ),
            ],
          );
        },
      ),
    );

    _disposeTextControllersLater([
      keyController,
      valueController,
      typeController,
      categoryController,
      descriptionController,
      minController,
      maxController,
      allowedValuesController,
    ]);
  }

  Future<void> _deleteEntry(_AdminAppConfigEntry entry) async {
    final l10n = ref.read(localizationProvider);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('adminAppConfigDeleteTitle')),
        content: Text(
          l10n.getString('adminAppConfigDeleteBody').replaceAll(
                '{key}',
                entry.configKey,
              ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );

    if (shouldDelete != true) return;

    setState(() {
      _entries =
          _entries.where((e) => e.configKey != entry.configKey).toList(growable: false);
    });

    try {
      await Supabase.instance.client
          .from('app_config')
          .delete()
          .eq('config_key', entry.configKey);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      unawaited(_load(force: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminAppConfigDeleteFailed'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    if (_isLoading) {
      return _MessageScaffold(
        title: l10n.getString('adminNavAppConfig'),
        body: l10n.getString('generalLoading'),
        showSpinner: true,
      );
    }

    if (_errorKey != null) {
      return _MessageScaffold(
        title: l10n.getString('adminNavAppConfig'),
        body: l10n.getString(_errorKey!),
      );
    }

    final categories = _entries
        .map((e) => e.category)
        .where((c) => c.trim().isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();

    final normalizedQuery = _query.trim().toLowerCase();

    final filtered = _entries.where((e) {
      if (_category != null && _category!.isNotEmpty && e.category != _category) {
        return false;
      }
      if (_userConfigurable != null && e.isUserConfigurable != _userConfigurable) {
        return false;
      }
      if (normalizedQuery.isEmpty) return true;
      return e.configKey.toLowerCase().contains(normalizedQuery) ||
          e.category.toLowerCase().contains(normalizedQuery) ||
          e.configType.toLowerCase().contains(normalizedQuery) ||
          e.description.toLowerCase().contains(normalizedQuery);
    }).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('adminNavAppConfig'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.getString('generalRefresh')),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: () => _upsertEntry(existing: null),
                icon: const Icon(Icons.add),
                label: Text(l10n.getString('adminAppConfigAdd')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  onChanged: (v) {
                    setState(() {
                      _query = v;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: l10n.getString('adminAppConfigSearchHint'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownMenu<String>(
                  initialSelection: _category ?? '',
                  dropdownMenuEntries: [
                    DropdownMenuEntry<String>(
                      value: '',
                      label: l10n.getString('adminAppConfigAllCategories'),
                    ),
                    ...categories.map(
                      (c) => DropdownMenuEntry<String>(value: c, label: c),
                    ),
                  ],
                  onSelected: (v) {
                    setState(() {
                      _category = (v == null || v.isEmpty) ? null : v;
                    });
                  },
                  label: Text(l10n.getString('adminAppConfigCategory')),
                  inputDecorationTheme: const InputDecorationTheme(
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownMenu<String>(
                  initialSelection: switch (_userConfigurable) {
                    true => 'true',
                    false => 'false',
                    null => '',
                  },
                  dropdownMenuEntries: [
                    DropdownMenuEntry<String>(
                      value: '',
                      label: l10n.getString('adminAppConfigAllUserConfigurable'),
                    ),
                    DropdownMenuEntry<String>(
                      value: 'true',
                      label: l10n.getString('adminSubscriptionsYes'),
                    ),
                    DropdownMenuEntry<String>(
                      value: 'false',
                      label: l10n.getString('adminSubscriptionsNo'),
                    ),
                  ],
                  onSelected: (v) {
                    setState(() {
                      _userConfigurable = switch (v) {
                        'true' => true,
                        'false' => false,
                        _ => null,
                      };
                    });
                  },
                  label: Text(l10n.getString('adminAppConfigIsUserConfigurable')),
                  inputDecorationTheme: const InputDecorationTheme(
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _query = '';
                    _category = null;
                    _userConfigurable = null;
                  });
                },
                child: Text(l10n.getString('adminAppConfigClearFilters')),
              ),
              Text(
                l10n
                    .getString('adminAppConfigCount')
                    .replaceAll('{count}', filtered.length.toString()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final e = filtered[index];
                final valuePreview = _formatJsonValue(e.configValue);
                final shortValue = valuePreview.length > 220
                    ? '${valuePreview.substring(0, 220)}…'
                    : valuePreview;

                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.configKey,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            TextButton(
                              onPressed: () => _upsertEntry(existing: e),
                              child: Text(l10n.getString('generalEdit')),
                            ),
                            TextButton(
                              onPressed: () => _deleteEntry(e),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    Theme.of(context).colorScheme.error,
                              ),
                              child: Text(l10n.getString('generalDelete')),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _MetaChip(
                              label: l10n.getString('adminAppConfigCategory'),
                              value: e.category,
                            ),
                            _MetaChip(
                              label: l10n.getString('adminAppConfigType'),
                              value: e.configType,
                            ),
                            _MetaChip(
                              label: l10n.getString('adminAppConfigIsUserConfigurable'),
                              value: e.isUserConfigurable
                                  ? l10n.getString('adminSubscriptionsYes')
                                  : l10n.getString('adminSubscriptionsNo'),
                            ),
                            if (e.minValue != null)
                              _MetaChip(
                                label: l10n.getString('adminAppConfigMinValue'),
                                value: e.minValue.toString(),
                              ),
                            if (e.maxValue != null)
                              _MetaChip(
                                label: l10n.getString('adminAppConfigMaxValue'),
                                value: e.maxValue.toString(),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(e.description),
                        const SizedBox(height: 12),
                        Text(
                          shortValue,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                        const SizedBox(height: 8),
                        if (e.allowedValues != null)
                          _KeyPreviewRow(
                            title:
                                l10n.getString('adminAppConfigAllowedValuesShort'),
                            value: _formatJsonValue(e.allowedValues),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminSubscriptionTier {
  final String id;
  final String revenueCatPackageIdentifier;
  final String titleKey;
  final String? subtitleKey;
  final String featuresKey;
  final String? badgeKey;
  final int sortOrder;
  final bool isActive;

  const _AdminSubscriptionTier({
    required this.id,
    required this.revenueCatPackageIdentifier,
    required this.titleKey,
    required this.subtitleKey,
    required this.featuresKey,
    required this.badgeKey,
    required this.sortOrder,
    required this.isActive,
  });

  factory _AdminSubscriptionTier.fromRow(Map<String, dynamic> row) {
    return _AdminSubscriptionTier(
      id: (row['id'] as String?) ?? '',
      revenueCatPackageIdentifier:
          (row['revenue_cat_package_identifier'] as String?) ?? '',
      titleKey: (row['title_key'] as String?) ?? '',
      subtitleKey: row['subtitle_key'] as String?,
      featuresKey: (row['features_key'] as String?) ?? '',
      badgeKey: row['badge_key'] as String?,
      sortOrder: (row['sort_order'] as int?) ?? 0,
      isActive: (row['is_active'] as bool?) ?? true,
    );
  }
}

class _AdminSubscriptionPlan {
  final String id;
  final String tierId;
  final String duration;
  final String priceDisplay;
  final String? savingsText;
  final String? revenueCatPackageIdentifier;
  final int sortOrder;

  const _AdminSubscriptionPlan({
    required this.id,
    required this.tierId,
    required this.duration,
    required this.priceDisplay,
    required this.savingsText,
    required this.revenueCatPackageIdentifier,
    required this.sortOrder,
  });

  factory _AdminSubscriptionPlan.fromRow(Map<String, dynamic> row) {
    return _AdminSubscriptionPlan(
      id: (row['id'] as String?) ?? '',
      tierId: (row['tier_id'] as String?) ?? '',
      duration: (row['duration'] as String?) ?? '',
      priceDisplay: (row['price_display'] as String?) ?? '',
      savingsText: row['savings_text'] as String?,
      revenueCatPackageIdentifier:
          row['revenue_cat_package_identifier'] as String?,
      sortOrder: (row['sort_order'] as int?) ?? 0,
    );
  }
}

class _SubscriptionsScreen extends ConsumerStatefulWidget {
  const _SubscriptionsScreen();

  @override
  ConsumerState<_SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends ConsumerState<_SubscriptionsScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_AdminSubscriptionTier> _tiers = const [];
  Map<String, List<_AdminSubscriptionPlan>> _plansByTierId = const {};

  String _durationLabel(LocalizationState l10n, String duration) {
    return switch (duration) {
      'day' => l10n.getString('paywallPeriodDaily'),
      'week' => l10n.getString('paywallPeriodWeekly'),
      'month' => l10n.getString('paywallPeriodMonthly'),
      'year' => l10n.getString('paywallPeriodAnnual'),
      _ => duration,
    };
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    Map<String, dynamic> decodeMap(Object? raw) {
      if (raw is! Map) return const {};
      return Map<String, dynamic>.from(raw);
    }

    List<Map<String, dynamic>> asListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final cacheKey = 'admin_cache:subscriptions:v1';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<Map<String, dynamic>>(
        cacheKey,
        decodeMap,
      );
      if (!mounted) return;
      if (cached != null) {
        final tierRows = asListMap(cached.data['tiers']);
        final planRows = asListMap(cached.data['plans']);

        final tiers = tierRows
            .map(_AdminSubscriptionTier.fromRow)
            .where((t) => t.id.isNotEmpty)
            .toList(growable: false);

        final plans = planRows
            .map(_AdminSubscriptionPlan.fromRow)
            .where((p) => p.id.isNotEmpty && p.tierId.isNotEmpty)
            .toList(growable: false);

        final map = <String, List<_AdminSubscriptionPlan>>{};
        for (final p in plans) {
          (map[p.tierId] ??= <_AdminSubscriptionPlan>[]).add(p);
        }

        setState(() {
          _tiers = tiers;
          _plansByTierId = map;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final client = Supabase.instance.client;
      final tierRows = await client
          .from('subscription_tiers')
          .select()
          .order('sort_order', ascending: true);
      final planRows = await client
          .from('subscription_plans')
          .select()
          .order('tier_id', ascending: true)
          .order('sort_order', ascending: true);

      final rawTiers =
          List<Map<String, dynamic>>.from(tierRows).map((r) => Map<String, dynamic>.from(r)).toList(growable: false);
      final rawPlans =
          List<Map<String, dynamic>>.from(planRows).map((r) => Map<String, dynamic>.from(r)).toList(growable: false);
      await _AdminCache.write<Map<String, dynamic>>(
        cacheKey,
        (v) => v,
        <String, dynamic>{'tiers': rawTiers, 'plans': rawPlans},
      );

      final tiers = rawTiers
          .map(_AdminSubscriptionTier.fromRow)
          .where((t) => t.id.isNotEmpty)
          .toList(growable: false);

      final plans = rawPlans
          .map(_AdminSubscriptionPlan.fromRow)
          .where((p) => p.id.isNotEmpty && p.tierId.isNotEmpty)
          .toList(growable: false);

      final map = <String, List<_AdminSubscriptionPlan>>{};
      for (final p in plans) {
        (map[p.tierId] ??= <_AdminSubscriptionPlan>[]).add(p);
      }

      if (!mounted) return;
      setState(() {
        _tiers = tiers;
        _plansByTierId = map;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSubscriptionsLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminSubscriptionsLoadFailed';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _upsertTier({
    required _AdminSubscriptionTier? existing,
  }) async {
    final l10n = ref.read(localizationProvider);
    final idController = TextEditingController(text: existing?.id ?? '');
    final revenueCatController = TextEditingController(
      text: existing?.revenueCatPackageIdentifier ?? '',
    );
    final titleKeyController = TextEditingController(text: existing?.titleKey ?? '');
    final subtitleKeyController =
        TextEditingController(text: existing?.subtitleKey ?? '');
    final featuresKeyController =
        TextEditingController(text: existing?.featuresKey ?? '');
    final badgeKeyController =
        TextEditingController(text: existing?.badgeKey ?? '');
    final sortOrderController =
        TextEditingController(text: (existing?.sortOrder ?? 0).toString());
    var isActive = existing?.isActive ?? true;

    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    Future<void> submit(BuildContext dialogCtx, StateSetter setDialogState) async {
      if (isSubmitting) return;
      final isValid = formKey.currentState?.validate() ?? false;
      if (!isValid) return;

      if (!dialogCtx.mounted) return;
      setDialogState(() {
        isSubmitting = true;
      });

      final id = idController.text.trim();
      final revenueCat = revenueCatController.text.trim();
      final titleKey = titleKeyController.text.trim();
      final subtitleKey = subtitleKeyController.text.trim();
      final featuresKey = featuresKeyController.text.trim();
      final badgeKey = badgeKeyController.text.trim();
      final sortOrder = int.tryParse(sortOrderController.text.trim()) ?? 0;

      try {
        await Supabase.instance.client.rpc(
          'admin_upsert_subscription_tier',
          params: {
            'p_id': id,
            'p_revenue_cat_package_identifier': revenueCat,
            'p_title_key': titleKey,
            'p_subtitle_key': subtitleKey,
            'p_features_key': featuresKey,
            'p_badge_key': badgeKey,
            'p_sort_order': sortOrder,
            'p_is_active': isActive,
          },
        ).timeout(const Duration(seconds: 20));
        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
        unawaited(_load(force: true));
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() {
          isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSubscriptionsSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final previewTitle = titleKeyController.text.trim();
            final previewSubtitle = subtitleKeyController.text.trim();
            final previewFeatures = featuresKeyController.text.trim();
            final previewBadge = badgeKeyController.text.trim();

            return AlertDialog(
              title: Text(
                l10n.getString(existing == null
                    ? 'adminSubscriptionsAddTier'
                    : 'adminSubscriptionsEditTier'),
              ),
              content: SizedBox(
                width: 560,
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: idController,
                          enabled: existing == null,
                          decoration: InputDecoration(
                            labelText: l10n.getString('adminSubscriptionsTierId'),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return l10n.getString(
                                'adminSubscriptionsTierIdRequired',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: revenueCatController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsRevenueCatId'),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return l10n.getString(
                                'adminSubscriptionsRevenueCatIdRequired',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: titleKeyController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsTitleKey'),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return l10n.getString(
                                'adminSubscriptionsTitleKeyRequired',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        _KeyPreviewRow(
                          title: l10n.getString('adminSubscriptionsPreview'),
                          value: previewTitle.isEmpty
                              ? ''
                              : l10n.getString(previewTitle),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: subtitleKeyController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsSubtitleKey'),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        const SizedBox(height: 8),
                        _KeyPreviewRow(
                          title: l10n.getString('adminSubscriptionsPreview'),
                          value: previewSubtitle.isEmpty
                              ? ''
                              : l10n.getString(previewSubtitle),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: featuresKeyController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsFeaturesKey'),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return l10n.getString(
                                'adminSubscriptionsFeaturesKeyRequired',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        _KeyPreviewRow(
                          title: l10n.getString('adminSubscriptionsPreview'),
                          value: previewFeatures.isEmpty
                              ? ''
                              : l10n.getString(previewFeatures),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: badgeKeyController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsBadgeKey'),
                          ),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        const SizedBox(height: 8),
                        _KeyPreviewRow(
                          title: l10n.getString('adminSubscriptionsPreview'),
                          value: previewBadge.isEmpty ? '' : l10n.getString(previewBadge),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: sortOrderController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.getString('adminSubscriptionsSortOrder'),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: isActive,
                          onChanged: (v) {
                            setDialogState(() {
                              isActive = v;
                            });
                          },
                          title: Text(
                            l10n.getString('adminSubscriptionsIsActive'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                  child: Text(l10n.getString('generalCancel')),
                ),
                ElevatedButton(
                  onPressed:
                      isSubmitting ? null : () => submit(ctx, setDialogState),
                  child: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.getString('generalSave')),
                ),
              ],
            );
          },
        );
      },
    );

    _disposeTextControllersLater([
      idController,
      revenueCatController,
      titleKeyController,
      subtitleKeyController,
      featuresKeyController,
      badgeKeyController,
      sortOrderController,
    ]);
  }

  Future<void> _deleteTier(_AdminSubscriptionTier tier) async {
    final l10n = ref.read(localizationProvider);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('adminSubscriptionsDeleteTierTitle')),
        content: Text(
          l10n.getString('adminSubscriptionsDeleteTierBody').replaceAll(
                '{id}',
                tier.id,
              ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;

    setState(() {
      _tiers = _tiers.where((t) => t.id != tier.id).toList(growable: false);
      final copy = Map<String, List<_AdminSubscriptionPlan>>.from(_plansByTierId);
      copy.remove(tier.id);
      _plansByTierId = copy;
    });

    try {
      await Supabase.instance.client.rpc(
        'admin_delete_subscription_tier',
        params: {'p_id': tier.id},
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      unawaited(_load(force: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSubscriptionsDeleteFailed'))),
      );
    }
  }

  Future<void> _upsertPlan({
    required _AdminSubscriptionPlan? existing,
    required String? defaultTierId,
  }) async {
    final l10n = ref.read(localizationProvider);
    final idController = TextEditingController(text: existing?.id ?? '');
    var tierId = existing?.tierId ?? defaultTierId ?? (_tiers.isNotEmpty ? _tiers.first.id : '');
    var duration = existing?.duration ?? 'month';
    final priceController =
        TextEditingController(text: existing?.priceDisplay ?? '');
    final savingsController =
        TextEditingController(text: existing?.savingsText ?? '');
    final revenueCatController =
        TextEditingController(text: existing?.revenueCatPackageIdentifier ?? '');
    final sortOrderController =
        TextEditingController(text: (existing?.sortOrder ?? 0).toString());
    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    Future<void> submit(BuildContext dialogCtx, StateSetter setDialogState) async {
      if (isSubmitting) return;
      final isValid = formKey.currentState?.validate() ?? false;
      if (!isValid) return;

      if (!dialogCtx.mounted) return;
      setDialogState(() {
        isSubmitting = true;
      });

      final id = idController.text.trim();
      final priceDisplay = priceController.text.trim();
      final savingsText = savingsController.text.trim();
      final revenueCat = revenueCatController.text.trim();
      final sortOrder = int.tryParse(sortOrderController.text.trim()) ?? 0;

      try {
        await Supabase.instance.client.rpc(
          'admin_upsert_subscription_plan',
          params: {
            'p_id': id,
            'p_tier_id': tierId,
            'p_duration': duration,
            'p_price_display': priceDisplay,
            'p_savings_text': savingsText,
            'p_revenue_cat_package_identifier': revenueCat,
            'p_sort_order': sortOrder,
          },
        ).timeout(const Duration(seconds: 20));
        if (!mounted || !dialogCtx.mounted) return;
        Navigator.of(dialogCtx).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSaved'))),
        );
        unawaited(_load(force: true));
      } catch (_) {
        if (!mounted || !dialogCtx.mounted) return;
        setDialogState(() {
          isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminSubscriptionsSaveFailed'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text(
              l10n.getString(existing == null
                  ? 'adminSubscriptionsAddPlan'
                  : 'adminSubscriptionsEditPlan'),
            ),
            content: SizedBox(
              width: 560,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: idController,
                        enabled: existing == null,
                        decoration: InputDecoration(
                          labelText: l10n.getString('adminSubscriptionsPlanId'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString(
                              'adminSubscriptionsPlanIdRequired',
                            );
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      FormField<String>(
                        initialValue: tierId.isEmpty ? null : tierId,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString('adminSubscriptionsTierIdRequired');
                          }
                          return null;
                        },
                        builder: (field) {
                          return InputDecorator(
                            decoration: InputDecoration(
                              labelText: l10n.getString('adminSubscriptionsTierId'),
                              errorText: field.errorText,
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: (field.value ?? '').isEmpty ? null : field.value,
                                items: _tiers
                                    .map(
                                      (t) => DropdownMenuItem<String>(
                                        value: t.id,
                                        child: Text(
                                          '${t.id} • ${l10n.getString(t.titleKey)}',
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    tierId = value;
                                  });
                                  field.didChange(value);
                                },
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      FormField<String>(
                        initialValue: duration,
                        builder: (field) {
                          return InputDecorator(
                            decoration: InputDecoration(
                              labelText: l10n.getString('adminSubscriptionsDuration'),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: field.value,
                                items: ['day', 'week', 'month', 'year']
                                    .map(
                                      (d) => DropdownMenuItem<String>(
                                        value: d,
                                        child: Text(_durationLabel(l10n, d)),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    duration = value;
                                  });
                                  field.didChange(value);
                                },
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: priceController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.getString('adminSubscriptionsPriceDisplay'),
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n.getString(
                              'adminSubscriptionsPriceDisplayRequired',
                            );
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: savingsController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.getString('adminSubscriptionsSavingsText'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: revenueCatController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.getString('adminSubscriptionsRevenueCatId'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: sortOrderController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.getString('adminSubscriptionsSortOrder'),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
                child: Text(l10n.getString('generalCancel')),
              ),
              ElevatedButton(
                onPressed:
                    isSubmitting ? null : () => submit(ctx, setDialogState),
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.getString('generalSave')),
              ),
            ],
          );
        },
      ),
    );

    _disposeTextControllersLater([
      idController,
      priceController,
      savingsController,
      revenueCatController,
      sortOrderController,
    ]);
  }

  Future<void> _deletePlan(_AdminSubscriptionPlan plan) async {
    final l10n = ref.read(localizationProvider);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('adminSubscriptionsDeletePlanTitle')),
        content: Text(
          l10n.getString('adminSubscriptionsDeletePlanBody').replaceAll(
                '{id}',
                plan.id,
              ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.getString('generalDelete')),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;

    setState(() {
      final copy = Map<String, List<_AdminSubscriptionPlan>>.from(_plansByTierId);
      final existing = copy[plan.tierId];
      if (existing != null) {
        copy[plan.tierId] = existing.where((p) => p.id != plan.id).toList(growable: false);
      }
      _plansByTierId = copy;
    });

    try {
      await Supabase.instance.client.rpc(
        'admin_delete_subscription_plan',
        params: {'p_id': plan.id},
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminDeleted'))),
      );
      unawaited(_load(force: true));
    } catch (_) {
      if (!mounted) return;
      unawaited(_load(force: true));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSubscriptionsDeleteFailed'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    if (_isLoading) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(l10n.getString('generalLoading')),
              ],
            ),
          ),
        ),
      );
    }

    final errorKey = _errorKey;
    if (errorKey != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString(errorKey), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.getString('generalRefresh')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 980;
        final padding = EdgeInsets.all(isWide ? 24 : 12);

        return Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWide)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.getString('adminNavSubscriptions'),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _load(force: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.getString('generalRefresh')),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () => _upsertTier(existing: null),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.getString('adminSubscriptionsAddTier')),
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.getString('adminNavSubscriptions'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _load(force: true),
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.getString('generalRefresh')),
                    ),
                    FilledButton.icon(
                      onPressed: () => _upsertTier(existing: null),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.getString('adminSubscriptionsAddTier')),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: _tiers.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final tier = _tiers[index];
                    final plans = _plansByTierId[tier.id] ?? const [];

                    Future<void> handleTierAction(String value) async {
                      if (value == 'edit_tier') {
                        await _upsertTier(existing: tier);
                        return;
                      }
                      if (value == 'add_plan') {
                        await _upsertPlan(existing: null, defaultTierId: tier.id);
                        return;
                      }
                      if (value == 'delete_tier') {
                        await _deleteTier(tier);
                        return;
                      }
                    }

                    Widget tierActions() {
                      if (isWide) {
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _upsertTier(existing: tier),
                              icon: const Icon(Icons.edit_outlined),
                              label: Text(l10n.getString('generalEdit')),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  _upsertPlan(existing: null, defaultTierId: tier.id),
                              icon: const Icon(Icons.add),
                              label: Text(l10n.getString('adminSubscriptionsAddPlan')),
                            ),
                            TextButton.icon(
                              onPressed: () => _deleteTier(tier),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(context).colorScheme.error,
                              ),
                              icon: const Icon(Icons.delete_outline),
                              label: Text(l10n.getString('generalDelete')),
                            ),
                          ],
                        );
                      }

                      return PopupMenuButton<String>(
                        onSelected: handleTierAction,
                        itemBuilder: (ctx) => [
                          PopupMenuItem(
                            value: 'edit_tier',
                            child: Text(l10n.getString('generalEdit')),
                          ),
                          PopupMenuItem(
                            value: 'add_plan',
                            child: Text(l10n.getString('adminSubscriptionsAddPlan')),
                          ),
                          PopupMenuItem(
                            value: 'delete_tier',
                            child: Text(l10n.getString('generalDelete')),
                          ),
                        ],
                      );
                    }

                    Widget plansSection() {
                      if (plans.isEmpty) {
                        return Text(l10n.getString('adminSubscriptionsNoPlans'));
                      }

                      if (isWide) {
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsPlanId')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsDuration')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsPriceDisplay')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsSavingsText')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsRevenueCatId')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsSortOrder')),
                              ),
                              DataColumn(
                                label: Text(l10n.getString('adminSubscriptionsActions')),
                              ),
                            ],
                            rows: plans.map((p) {
                              return DataRow(
                                cells: [
                                  DataCell(SelectableText(p.id)),
                                  DataCell(Text(_durationLabel(l10n, p.duration))),
                                  DataCell(Text(p.priceDisplay)),
                                  DataCell(Text(p.savingsText ?? '')),
                                  DataCell(Text(p.revenueCatPackageIdentifier ?? '')),
                                  DataCell(Text(p.sortOrder.toString())),
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextButton(
                                          onPressed: () => _upsertPlan(
                                            existing: p,
                                            defaultTierId: tier.id,
                                          ),
                                          style: TextButton.styleFrom(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            minimumSize: const Size(0, 32),
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                          child: Text(l10n.getString('generalEdit')),
                                        ),
                                        TextButton(
                                          onPressed: () => _deletePlan(p),
                                          style: TextButton.styleFrom(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            minimumSize: const Size(0, 32),
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            foregroundColor:
                                                Theme.of(context).colorScheme.error,
                                          ),
                                          child: Text(l10n.getString('generalDelete')),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            }).toList(growable: false),
                          ),
                        );
                      }

                      return Column(
                        children: [
                          for (final p in plans)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Theme.of(context).dividerColor),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: ListTile(
                                  title: Text(
                                    p.priceDisplay.trim().isEmpty ? p.id : p.priceDisplay,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _MetaChip(
                                          label: l10n.getString('adminSubscriptionsDuration'),
                                          value: _durationLabel(l10n, p.duration),
                                        ),
                                        _MetaChip(
                                          label: l10n.getString('adminSubscriptionsPlanId'),
                                          value: p.id,
                                        ),
                                        if ((p.savingsText ?? '').trim().isNotEmpty)
                                          _MetaChip(
                                            label:
                                                l10n.getString('adminSubscriptionsSavingsText'),
                                            value: (p.savingsText ?? '').trim(),
                                          ),
                                        if ((p.revenueCatPackageIdentifier ?? '').trim().isNotEmpty)
                                          _MetaChip(
                                            label:
                                                l10n.getString('adminSubscriptionsRevenueCatId'),
                                            value: (p.revenueCatPackageIdentifier ?? '').trim(),
                                          ),
                                        _MetaChip(
                                          label: l10n.getString('adminSubscriptionsSortOrder'),
                                          value: p.sortOrder.toString(),
                                        ),
                                      ],
                                    ),
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (v) {
                                      if (v == 'edit') {
                                        _upsertPlan(existing: p, defaultTierId: tier.id);
                                        return;
                                      }
                                      if (v == 'delete') {
                                        _deletePlan(p);
                                        return;
                                      }
                                    },
                                    itemBuilder: (ctx) => [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(l10n.getString('generalEdit')),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(l10n.getString('generalDelete')),
                                      ),
                                    ],
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    }

                    return Card(
                      child: Padding(
                        padding: EdgeInsets.all(isWide ? 16 : 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${tier.id} • ${l10n.getString(tier.titleKey)}',
                                        style: Theme.of(context).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          _MetaChip(
                                            label: l10n.getString(
                                              'adminSubscriptionsIsActive',
                                            ),
                                            value: tier.isActive
                                                ? l10n.getString('adminSubscriptionsYes')
                                                : l10n.getString('adminSubscriptionsNo'),
                                          ),
                                          _MetaChip(
                                            label: l10n.getString(
                                              'adminSubscriptionsSortOrder',
                                            ),
                                            value: tier.sortOrder.toString(),
                                          ),
                                          if (tier.revenueCatPackageIdentifier.trim().isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString(
                                                'adminSubscriptionsRevenueCatId',
                                              ),
                                              value: tier.revenueCatPackageIdentifier,
                                            ),
                                          if (tier.titleKey.trim().isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString(
                                                'adminSubscriptionsTitleKey',
                                              ),
                                              value: tier.titleKey,
                                            ),
                                          if ((tier.subtitleKey ?? '').trim().isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString(
                                                'adminSubscriptionsSubtitleKey',
                                              ),
                                              value: tier.subtitleKey!,
                                            ),
                                          if (tier.featuresKey.trim().isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString(
                                                'adminSubscriptionsFeaturesKey',
                                              ),
                                              value: tier.featuresKey,
                                            ),
                                          if ((tier.badgeKey ?? '').trim().isNotEmpty)
                                            _MetaChip(
                                              label: l10n.getString(
                                                'adminSubscriptionsBadgeKey',
                                              ),
                                              value: tier.badgeKey!,
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                tierActions(),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              l10n.getString('adminSubscriptionsPlansHeader'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            plansSection(),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _KeyPreviewRow extends StatelessWidget {
  final String title;
  final String value;

  const _KeyPreviewRow({
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final text = value.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text),
        ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetaChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text('$label: $value'),
      ),
    );
  }
}

class _VerificationUserRow {
  final String id;
  final String name;
  final String verificationStatus;
  final bool isVerified;
  final String? profilePhotoPath;
  final String? verificationPhotoPath;
  final DateTime? verificationSubmittedAt;
  final DateTime? verificationReviewedAt;
  final String? verificationReviewerId;
  final String? verificationReviewerName;
  final num? verificationSimilarityScore;
  final Object? verificationAiAnalysis;
  final bool verificationAutoRejected;

  const _VerificationUserRow({
    required this.id,
    required this.name,
    required this.verificationStatus,
    required this.isVerified,
    required this.profilePhotoPath,
    required this.verificationPhotoPath,
    required this.verificationSubmittedAt,
    required this.verificationReviewedAt,
    required this.verificationReviewerId,
    required this.verificationReviewerName,
    required this.verificationSimilarityScore,
    required this.verificationAiAnalysis,
    required this.verificationAutoRejected,
  });

  static DateTime? _tryDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  factory _VerificationUserRow.fromMap(Map<String, dynamic> row) {
    Object? analysis = row['verification_ai_analysis'];
    if (analysis is String) {
      final trimmed = analysis.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          analysis = jsonDecode(trimmed);
        } catch (_) {}
      }
    }
    return _VerificationUserRow(
      id: (row['id'] ?? '').toString(),
      name: (row['name'] ?? '').toString(),
      verificationStatus: (row['verification_status'] ?? 'unverified').toString(),
      isVerified: (row['is_verified'] ?? false) is bool
          ? (row['is_verified'] ?? false) as bool
          : (row['is_verified'] ?? false).toString().toLowerCase() == 'true',
      profilePhotoPath: row['profile_photo_path']?.toString(),
      verificationPhotoPath: row['verification_photo_path']?.toString(),
      verificationSubmittedAt: _tryDate(row['verification_submitted_at']),
      verificationReviewedAt: _tryDate(row['verification_reviewed_at']),
      verificationReviewerId: row['verification_reviewer_id']?.toString(),
      verificationReviewerName: row['verification_reviewer_name']?.toString(),
      verificationSimilarityScore: row['verification_similarity_score'] as num?,
      verificationAiAnalysis: analysis,
      verificationAutoRejected: (row['verification_auto_rejected'] ?? false) is bool
          ? (row['verification_auto_rejected'] ?? false) as bool
          : (row['verification_auto_rejected'] ?? false).toString().toLowerCase() == 'true',
    );
  }
}

class _UserVerificationScreen extends ConsumerStatefulWidget {
  const _UserVerificationScreen();

  @override
  ConsumerState<_UserVerificationScreen> createState() => _UserVerificationScreenState();
}

class _UserVerificationScreenState extends ConsumerState<_UserVerificationScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_VerificationUserRow> _rows = const [];
  int _loadGeneration = 0;

  String _query = '';
  String _status = 'pending';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    List<Map<String, dynamic>> decodeListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final generation = ++_loadGeneration;
    if (!mounted) return;
    final queryTrimmed = _query.trim();
    final queryKey =
        queryTrimmed.isEmpty ? 'none' : base64UrlEncode(utf8.encode(queryTrimmed));
    final cacheKey = 'admin_cache:verification:v1:$_status:$queryKey';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<List<Map<String, dynamic>>>(
        cacheKey,
        decodeListMap,
      );
      if (!mounted) return;
      if (generation != _loadGeneration) return;
      if (cached != null) {
        final mapped = cached.data
            .map((e) => _VerificationUserRow.fromMap(e))
            .toList(growable: false);
        setState(() {
          _rows = mapped;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    if (generation != _loadGeneration) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final result = await Supabase.instance.client.rpc(
        'admin_list_verification_users',
        params: {
          'p_status': _status == 'all' ? null : _status,
          'p_query': queryTrimmed.isEmpty ? null : queryTrimmed,
          'p_limit': 200,
          'p_offset': 0,
        },
      ).timeout(const Duration(seconds: 12));

      final list = (result as List<dynamic>).cast<dynamic>();
      final raw = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      await _AdminCache.write<List<Map<String, dynamic>>>(
        cacheKey,
        (v) => v,
        raw,
      );
      final mapped =
          raw.map((e) => _VerificationUserRow.fromMap(e)).toList(growable: false);

      if (!mounted) return;
      if (generation != _loadGeneration) return;
      setState(() {
        _rows = mapped;
      });
    } catch (_) {
      if (!mounted) return;
      if (generation != _loadGeneration) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminVerificationLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminVerificationLoadFailed';
        });
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _statusLabel(LocalizationState l10n, String status) {
    return switch (status) {
      'pending' => l10n.getString('adminStatusPending'),
      'approved' => l10n.getString('adminStatusApproved'),
      'rejected' => l10n.getString('adminStatusRejected'),
      'analyzing' => l10n.getString('adminStatusAnalyzing'),
      'unverified' => l10n.getString('adminStatusUnverified'),
      _ => status,
    };
  }

  String _normalizeStorageObjectPath(String bucket, String objectPath) {
    var clean = objectPath.trim();
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      try {
        final uri = Uri.parse(clean);
        final segments = uri.pathSegments;
        final idx = segments.indexOf(bucket);
        if (idx >= 0 && idx < segments.length - 1) {
          return segments.sublist(idx + 1).join('/');
        }
      } catch (_) {}
    }
    if (clean.startsWith('/')) clean = clean.substring(1);
    final prefix = '$bucket/';
    if (clean.startsWith(prefix)) clean = clean.substring(prefix.length);
    return clean;
  }

  Future<String?> _getSignedUrlFor(String bucket, String objectPath) async {
    final clean = _normalizeStorageObjectPath(bucket, objectPath);
    if (clean.isEmpty) return null;
    final signedUrlCacheKey = 'admin_cache:signed_url:v1:$bucket:$clean';
    final cached = await _AdminCache.read<String>(
      signedUrlCacheKey,
      (raw) => (raw ?? '').toString(),
    );
    final cachedUrl = cached?.data.trim() ?? '';
    if (cachedUrl.isNotEmpty && (cached?.isFresh ?? false)) {
      return cachedUrl;
    }

    try {
      final dynamic resp = await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(clean, 600);

      if (resp == null) return null;
      String? resolveRelativeUrl(String url) {
        final trimmed = url.trim();
        if (trimmed.isEmpty) return null;
        if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed;
        if (!trimmed.startsWith('/')) return trimmed;
        try {
          final dynamic c = Supabase.instance.client;
          final base = (c.supabaseUrl as String?)?.trim();
          if (base == null || base.isEmpty) return trimmed;
          return Uri.parse(base).resolve(trimmed).toString();
        } catch (_) {
          return trimmed;
        }
      }

      bool looksSigned(String url) {
        try {
          final uri = Uri.parse(url);
          if (uri.queryParameters.containsKey('token')) return true;
          if (uri.query.isNotEmpty &&
              (uri.query.contains('X-Amz-') || uri.query.contains('X-Amz-Signature'))) {
            return true;
          }
        } catch (_) {}
        return false;
      }

      String attachTokenIfNeeded(String url, String? token) {
        if (token == null || token.trim().isEmpty) return url;
        if (url.contains('token=')) return url;
        final sep = url.contains('?') ? '&' : '?';
        return '$url${sep}token=${Uri.encodeQueryComponent(token.trim())}';
      }

      if (resp is String) {
        final resolved = resolveRelativeUrl(resp);
        if (resolved == null) return null;
        final out = looksSigned(resolved) ? resolved : null;
        if (out != null) {
          await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
        }
        return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
      }
      if (resp is Map) {
        final token = resp['token']?.toString();
        final rawUrl = (resp['signedUrl'] ??
                resp['signed_url'] ??
                resp['signedurl'] ??
                resp['signedURL'] ??
                resp['signed_url'])
            ?.toString();
        if (rawUrl != null && rawUrl.trim().isNotEmpty) {
          final resolved = resolveRelativeUrl(rawUrl);
          if (resolved == null) return null;
          final withToken = attachTokenIfNeeded(resolved, token);
          final out = looksSigned(withToken) ? withToken : null;
          if (out != null) {
            await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
          }
          return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
        }
        final data = resp['data'];
        if (data is Map) {
          final nestedToken = data['token']?.toString() ?? token;
          final nestedUrl = (data['signedUrl'] ??
                  data['signed_url'] ??
                  data['signedurl'] ??
                  data['signedURL'] ??
                  data['signed_url'])
              ?.toString();
          if (nestedUrl != null && nestedUrl.trim().isNotEmpty) {
            final resolved = resolveRelativeUrl(nestedUrl);
            if (resolved == null) return null;
            final withToken = attachTokenIfNeeded(resolved, nestedToken);
            final out = looksSigned(withToken) ? withToken : null;
            if (out != null) {
              await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
            }
            return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
          }
        }
      }
      try {
        final maybe = (resp as dynamic).signedUrl ?? (resp as dynamic).data?.signedUrl;
        if (maybe is String && maybe.trim().isNotEmpty) {
          final resolved = resolveRelativeUrl(maybe);
          if (resolved == null) return null;
          final out = looksSigned(resolved) ? resolved : null;
          if (out != null) {
            await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
          }
          return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
        }
      } catch (_) {}
      return cachedUrl.isNotEmpty ? cachedUrl : null;
    } catch (_) {
      return cachedUrl.isNotEmpty ? cachedUrl : null;
    }
  }

  Future<void> _showPhotoViewer({
    required LocalizationState l10n,
    required String titleKey,
    required String bucket,
    required String path,
  }) async {
    final clean = _normalizeStorageObjectPath(bucket, path);
    if (clean.isEmpty) return;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Dialog.fullscreen(
          child: Column(
            children: [
              Material(
                color: Theme.of(ctx).colorScheme.surface,
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.getString(titleKey),
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: FutureBuilder<String?>(
                      future: _getSignedUrlFor(bucket, clean),
                      builder: (ctx, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return Text(
                            l10n.getString('generalLoading'),
                            style: const TextStyle(color: Colors.white),
                          );
                        }
                        final url = snap.data;
                        if (url == null || url.trim().isEmpty) {
                          return Text(
                            l10n.getString('adminVerificationPhotoLoadFailed'),
                            style: const TextStyle(color: Colors.white),
                          );
                        }
                        final cacheKey = 'admin_image_cache:v1:$bucket:$clean';
                        return InteractiveViewer(
                          child: CachedNetworkImage(
                            imageUrl: url,
                            cacheKey: cacheKey,
                            useOldImageOnUrlChange: true,
                            fit: BoxFit.contain,
                            placeholder: (context, url) => Text(
                              l10n.getString('generalLoading'),
                              style: const TextStyle(color: Colors.white),
                            ),
                            errorWidget: (context, url, error) => Text(
                              l10n.getString('adminVerificationPhotoLoadFailed'),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _photoSection({
    required LocalizationState l10n,
    required String titleKey,
    required String emptyKey,
    required String bucket,
    required String? path,
    double? maxHeight,
  }) {
    final clean = (path ?? '').trim();
    if (clean.isEmpty) {
      return Center(child: Text(l10n.getString(emptyKey)));
    }

    final normalized = _normalizeStorageObjectPath(bucket, clean);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.getString(titleKey),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxHeight ?? 520,
            minHeight: 160,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: FutureBuilder<String?>(
                future: _getSignedUrlFor(bucket, normalized),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Center(child: Text(l10n.getString('generalLoading')));
                  }
                  final url = snap.data;
                  if (url == null || url.trim().isEmpty) {
                    return Center(child: Text(l10n.getString('adminVerificationPhotoLoadFailed')));
                  }
                  final cacheKey = 'admin_image_cache:v1:$bucket:$normalized';
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: InkWell(
                      onTap: () => _showPhotoViewer(
                        l10n: l10n,
                        titleKey: titleKey,
                        bucket: bucket,
                        path: normalized,
                      ),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        cacheKey: cacheKey,
                        useOldImageOnUrlChange: true,
                        fit: BoxFit.contain,
                        placeholder: (context, url) =>
                            Center(child: Text(l10n.getString('generalLoading'))),
                        errorWidget: (context, url, error) => Center(
                          child: Text(l10n.getString('adminVerificationPhotoLoadFailed')),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Map<String, dynamic>? _coerceAnalysisMap(Object? raw) {
    if (raw == null) return null;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return null;
  }

  String? _firstStringValue(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  num? _firstNumValue(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      if (v is num) return v;
      final parsed = num.tryParse(v.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  bool? _firstBoolValue(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      if (v is bool) return v;
      final s = v.toString().trim().toLowerCase();
      if (s == 'true') return true;
      if (s == 'false') return false;
    }
    return null;
  }

  List<String> _stringListValue(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      if (v is List) {
        final list = v
            .map((e) => e?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
        if (list.isNotEmpty) return list;
      }
      final s = v.toString().trim();
      if (s.isNotEmpty) return [s];
    }
    return const [];
  }

  String _formatConfidence(num value) {
    if (value >= 0 && value <= 1) {
      return '${(value * 100).toStringAsFixed(1)}%';
    }
    if (value > 1 && value <= 100) {
      return '${value.toStringAsFixed(1)}%';
    }
    return value.toStringAsFixed(2);
  }

  String _titleCaseWords(String input) {
    final parts = input
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '';
    return parts
        .map((w) {
          final lower = w.toLowerCase();
          if (lower == 'ai') return 'AI';
          if (lower.isEmpty) return '';
          return '${lower[0].toUpperCase()}${lower.substring(1)}';
        })
        .join(' ');
  }

  String _humanizeKey(String key) {
    var s = key.trim();
    if (s.isEmpty) return s;
    s = s.replaceAll(RegExp(r'[_\-]+'), ' ');
    s = s.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'([A-Z]+)([A-Z][a-z])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _titleCaseWords(s);
  }

  String _aiLabelForKey(LocalizationState l10n, String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return l10n.getString('adminUnknown');
    if (trimmed.startsWith('#')) return trimmed;

    final normalized = trimmed.replaceAll('-', '_');
    return switch (normalized) {
      'authenticityAudit' ||
      'authenticity_audit' =>
        l10n.getString('adminVerificationAiFieldAuthenticityAudit'),
      'authentic' => l10n.getString('adminVerificationAiFieldAuthentic'),
      'comparedAt' || 'compared_at' => l10n.getString('adminVerificationAiFieldComparedAt'),
      'confidence' => l10n.getString('adminVerificationAiFieldConfidence'),
      'gestureCode' || 'gesture_code' => l10n.getString('adminVerificationAiFieldGesture'),
      'gesturePrompt' || 'gesture_prompt' =>
        l10n.getString('adminVerificationAiFieldGestureRequirement'),
      'isMatch' || 'is_match' => l10n.getString('adminVerificationAiFieldMatch'),
      'note' => l10n.getString('adminVerificationAiFieldNote'),
      'reasoning' => l10n.getString('adminVerificationAiFieldReasoning'),
      'service' => l10n.getString('adminVerificationAiFieldService'),
      'similarity' => l10n.getString('adminVerificationAiFieldSimilarity'),
      _ => _humanizeKey(trimmed),
    };
  }

  String _formatAiEnum(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;

    final upper = raw.toUpperCase();
    if (upper.contains('_')) {
      final words = upper
          .split('_')
          .where((w) => w.trim().isNotEmpty)
          .toList(growable: false);
      if (words.length >= 2 &&
          words.last == 'HAND' &&
          (words[words.length - 2] == 'RIGHT' || words[words.length - 2] == 'LEFT')) {
        final dir = words[words.length - 2].toLowerCase();
        final prefix = words.sublist(0, words.length - 2).join(' ').toLowerCase();
        return '${_titleCaseWords(prefix)} ($dir hand)';
      }
      final lower = words.join(' ').toLowerCase();
      return _titleCaseWords(lower);
    }

    if (raw.contains('_')) {
      return _titleCaseWords(raw.replaceAll('_', ' ').toLowerCase());
    }
    return raw;
  }

  String _formatAiValue(LocalizationState l10n, String key, Object? value) {
    if (value == null) return '';

    if (value is bool) return value ? l10n.getString('adminYes') : l10n.getString('adminNo');

    final normalizedKey = key.trim().replaceAll('-', '_');
    if (value is num) {
      final asInt = value % 1 == 0 ? value.toInt().toString() : value.toStringAsFixed(2);
      if (normalizedKey == 'confidence') return asInt;
      if (normalizedKey == 'similarity') return asInt;
      return asInt;
    }

    final s = value.toString().trim();
    if (s.isEmpty) return '';

    if (normalizedKey == 'comparedAt' || normalizedKey == 'compared_at') {
      final dt = DateTime.tryParse(s);
      if (dt != null) return _formatAdminDateTime(l10n, dt);
    }

    if (normalizedKey == 'gestureCode' || normalizedKey == 'gesture_code') {
      return _formatAiEnum(s);
    }
    if (normalizedKey == 'service') {
      return _formatAiEnum(s);
    }

    if (normalizedKey == 'confidence') {
      final parsed = num.tryParse(s);
      if (parsed != null) return parsed % 1 == 0 ? parsed.toInt().toString() : parsed.toString();
    }
    if (normalizedKey == 'similarity') {
      final parsed = num.tryParse(s);
      if (parsed != null) return parsed % 1 == 0 ? parsed.toInt().toString() : parsed.toString();
    }

    return s;
  }

  Widget _aiFieldRow(LocalizationState l10n, String rawKey, Object? rawValue) {
    final label = _aiLabelForKey(l10n, rawKey);
    final value = _formatAiValue(l10n, rawKey, rawValue).trim();
    if (value.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelWidth = (constraints.maxWidth * 0.28).clamp(140.0, 240.0);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(value),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _analysisTreeNode(LocalizationState l10n, String label, Object? value, int depth) {
    final normalizedLabel = _aiLabelForKey(l10n, label);

    if (depth >= 6) {
      return _aiFieldRow(l10n, label, value);
    }

    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final keys = map.keys.map((k) => k.toString()).toList(growable: false)
        ..sort((a, b) => a.compareTo(b));
      return ExpansionTile(
        initiallyExpanded: depth == 0 &&
            (label == 'authenticityAudit' || label == 'authenticity_audit'),
        title: Text(normalizedLabel),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        children: [
          for (final k in keys)
            _analysisTreeNode(l10n, k, map[k], depth + 1),
        ],
      );
    }

    if (value is List) {
      final items = value.cast<dynamic>();
      return ExpansionTile(
        title: Text('$normalizedLabel (${items.length})'),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        children: [
          for (var i = 0; i < items.length; i++)
            _analysisTreeNode(l10n, '#${i + 1}', items[i], depth + 1),
        ],
      );
    }

    final s = (value ?? '').toString().trim();
    return _aiFieldRow(l10n, label, s);
  }

  Widget _aiAnalysisContent(
    LocalizationState l10n,
    Object? analysis, {
    bool showSummary = true,
  }) {
    final map = _coerceAnalysisMap(analysis);
    if (map == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(l10n.getString('adminVerificationNoAnalysis')),
      );
    }

    final decision = showSummary
        ? _firstStringValue(
            map,
            const ['decision', 'verdict', 'result', 'status', 'label', 'classification'],
          )
        : null;
    final match = showSummary
        ? _firstBoolValue(
            map,
            const ['match', 'is_match', 'face_match', 'same_person', 'verified'],
          )
        : null;
    final confidence = showSummary
        ? _firstNumValue(
            map,
            const [
              'confidence',
              'match_confidence',
              'probability',
              'score',
              'similarity',
              'similarity_score',
            ],
          )
        : null;
    final reasons = showSummary
        ? _stringListValue(
            map,
            const ['reasons', 'reason', 'rejection_reasons', 'issues', 'notes', 'explanations'],
          )
        : const <String>[];
    final flags = showSummary
        ? _stringListValue(
            map,
            const ['flags', 'warnings', 'alerts', 'signals'],
          )
        : const <String>[];

    final summaryChips = showSummary
        ? <Widget>[
            if (decision != null)
              _MetaChip(
                label: l10n.getString('adminVerificationAiDecision'),
                value: decision,
              ),
            if (match != null)
              _MetaChip(
                label: l10n.getString('adminVerificationAiMatch'),
                value: match ? l10n.getString('adminYes') : l10n.getString('adminNo'),
              ),
            if (confidence != null)
              _MetaChip(
                label: l10n.getString('adminVerificationAiConfidence'),
                value: _formatConfidence(confidence),
              ),
          ]
        : const <Widget>[];

    final priority = <String>[
      'authenticityAudit',
      'authenticity_audit',
      'comparedAt',
      'compared_at',
      'confidence',
      'gestureCode',
      'gesture_code',
      'gesturePrompt',
      'gesture_prompt',
      'isMatch',
      'is_match',
      'similarity',
      'service',
      'note',
      'reasoning',
    ];
    final allKeys = map.keys.map((k) => k.toString()).toSet();
    final ordered = <String>[
      for (final k in priority)
        if (allKeys.contains(k)) k,
      ...allKeys.where((k) => !priority.contains(k)).toList()..sort(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSummary) ...[
          Text(
            l10n.getString('adminVerificationAiSummaryTitle'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (summaryChips.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.getString('adminVerificationAiSummaryUnavailable')),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: summaryChips,
            ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.getString('adminVerificationAiReasons'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in reasons) Chip(label: Text(r)),
              ],
            ),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.getString('adminVerificationAiFlags'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in flags) Chip(label: Text(f)),
              ],
            ),
          ],
          const SizedBox(height: 12),
        ],
        for (final k in ordered) ...[
          _analysisTreeNode(l10n, k, map[k], 0),
          const Divider(height: 1),
        ],
        ExpansionTile(
          title: Text(l10n.getString('adminVerificationAiRawJson')),
          childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
          children: [
            SelectableText(const JsonEncoder.withIndent('  ').convert(map)),
          ],
        ),
      ],
    );
  }

  Future<void> _showAiAnalysis(LocalizationState l10n, _VerificationUserRow row) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final maxHeight = (MediaQuery.of(ctx).size.height -
                MediaQuery.of(ctx).viewPadding.vertical) *
            0.85;
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 980, maxHeight: maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.getString('adminVerificationAiAnalysis'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    row.name.trim().isEmpty ? row.id : '${maskUserDisplayName(row.name)}  (${row.id})',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: _aiAnalysisContent(
                        l10n,
                        row.verificationAiAnalysis,
                        showSummary: false,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                      label: Text(l10n.getString('generalClose')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showReview(LocalizationState l10n, _VerificationUserRow row) async {
    final path = row.verificationPhotoPath?.trim() ?? '';
    if (path.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminVerificationNoPhoto'))),
      );
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final maxHeight = (MediaQuery.of(ctx).size.height -
                MediaQuery.of(ctx).viewPadding.vertical) *
            0.85;
        final statusLabel = _statusLabel(l10n, row.verificationStatus);
        final reviewedByValue = () {
          final reviewerId = (row.verificationReviewerId ?? '').trim();
          final reviewerName = (row.verificationReviewerName ?? '').trim();
          if (reviewerId.isNotEmpty) {
            final shortId = reviewerId.length <= 8 ? reviewerId : reviewerId.substring(0, 8);
            if (reviewerName.isNotEmpty) {
              return '${maskUserDisplayName(reviewerName)} ($shortId)';
            }
            return shortId;
          }

          final isFinalDecision =
              row.verificationStatus == 'approved' || row.verificationStatus == 'rejected';
          if (!isFinalDecision) return '';

          final analysis = _coerceAnalysisMap(row.verificationAiAnalysis) ?? const {};
          if (analysis.isNotEmpty || row.verificationAutoRejected) {
            return l10n.getString('adminVerificationReviewerAi');
          }
          return '';
        }();
        Widget statusBadge() {
          final scheme = Theme.of(ctx).colorScheme;
          final (bg, fg, border) = switch (row.verificationStatus) {
            'approved' => (Colors.green.shade700, Colors.white, null),
            'rejected' => (Colors.red.shade700, Colors.white, null),
            _ => (
                scheme.surface,
                scheme.onSurface,
                BorderSide(color: Theme.of(ctx).dividerColor),
              ),
          };
          return DecoratedBox(
            decoration: ShapeDecoration(
              color: bg,
              shape: StadiumBorder(side: border ?? BorderSide.none),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                statusLabel,
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: fg,
                    ),
              ),
            ),
          );
        }
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 980, maxHeight: maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.getString('adminVerificationReviewTitle'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: SelectableText(
                          row.name.trim().isEmpty ? row.id : '${maskUserDisplayName(row.name)}  (${row.id})',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (reviewedByValue.isNotEmpty) ...[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Theme.of(ctx).dividerColor),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Text(
                                '${l10n.getString('adminVerificationReviewedBy')}: $reviewedByValue',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(ctx).textTheme.labelMedium,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      statusBadge(),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (row.verificationSimilarityScore != null)
                        _MetaChip(
                          label: l10n.getString('adminVerificationScore'),
                          value: row.verificationSimilarityScore!.toStringAsFixed(2),
                        ),
                      if (row.verificationSubmittedAt != null)
                        _MetaChip(
                          label: l10n.getString('adminVerificationSubmitted'),
                          value: _formatAdminDateTime(l10n, row.verificationSubmittedAt!),
                        ),
                      if (row.verificationReviewedAt != null)
                        _MetaChip(
                          label: l10n.getString('adminVerificationReviewed'),
                          value: _formatAdminDateTime(l10n, row.verificationReviewedAt!),
                        ),
                      if (row.verificationAutoRejected)
                        _MetaChip(
                          label: l10n.getString('adminVerificationAutoRejected'),
                          value: l10n.getString('adminYes'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide = constraints.maxWidth >= 820;
                          final double photoMaxHeight = isWide
                              ? (maxHeight * 0.52).clamp(240.0, 520.0).toDouble()
                              : 420.0;

                          final profile = _photoSection(
                            l10n: l10n,
                            titleKey: 'adminVerificationProfilePhoto',
                            emptyKey: 'adminVerificationNoProfilePhoto',
                            bucket: 'profile-photos',
                            path: row.profilePhotoPath,
                            maxHeight: photoMaxHeight,
                          );

                          final verification = _photoSection(
                            l10n: l10n,
                            titleKey: 'adminVerificationPhotoTitle',
                            emptyKey: 'adminVerificationNoPhoto',
                            bucket: 'verification-photos',
                            path: row.verificationPhotoPath,
                            maxHeight: photoMaxHeight,
                          );

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isWide)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: profile),
                                    const SizedBox(width: 12),
                                    Expanded(child: verification),
                                  ],
                                )
                              else ...[
                                profile,
                                const SizedBox(height: 12),
                                verification,
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: row.verificationStatus == 'approved'
                            ? null
                            : () async {
                                Navigator.of(ctx).pop();
                                await _setStatus(l10n, row.id, 'approved');
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                          disabledForegroundColor:
                              Theme.of(context).colorScheme.onSurface.withAlpha(97),
                        ),
                        icon: const Icon(Icons.check),
                        label: Text(l10n.getString('adminApprove')),
                      ),
                      OutlinedButton.icon(
                        onPressed: row.verificationStatus == 'rejected'
                            ? null
                            : () async {
                                Navigator.of(ctx).pop();
                                await _setStatus(l10n, row.id, 'rejected');
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                        ),
                        icon: const Icon(Icons.close),
                        label: Text(l10n.getString('adminReject')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: Text(l10n.getString('generalClose')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _setStatus(LocalizationState l10n, String userId, String status) async {
    try {
      await Supabase.instance.client.rpc(
        'admin_set_user_verification_status',
        params: {
          'p_user_id': userId,
          'p_status': status,
        },
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSaved'))),
      );
      unawaited(_load(force: true));
    } on PostgrestException catch (e, st) {
      developer.log(
        'admin_set_user_verification_status PostgREST error',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      final msg = '${e.message} ${e.hint ?? ''} ${e.details ?? ''}';
      final key =
          msg.contains('No API key found') || msg.contains('apikey') || msg.contains('No `apikey`')
              ? 'supabaseConfigMissing'
              : 'adminVerificationUpdateFailed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString(key))),
      );
    } catch (e, st) {
      developer.log(
        'admin_set_user_verification_status failed',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      final msg = e.toString();
      final key =
          msg.contains('No API key found') || msg.contains('apikey') || msg.contains('No `apikey`')
              ? 'supabaseConfigMissing'
              : 'adminVerificationUpdateFailed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString(key))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    if (_isLoading) {
      return Center(child: Text(l10n.getString('generalLoading')));
    }

    if (_errorKey != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString(_errorKey!), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.getString('generalRefresh')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final filtered = _rows.where((r) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return r.id.toLowerCase().contains(q) ||
          r.name.toLowerCase().contains(q) ||
          r.verificationStatus.toLowerCase().contains(q);
    }).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('adminNavVerification'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.getString('generalRefresh')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: l10n.getString('adminVerificationSearchHint'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              DropdownMenu<String>(
                initialSelection: _status,
                dropdownMenuEntries: [
                  DropdownMenuEntry(value: 'all', label: l10n.getString('adminStatusAll')),
                  DropdownMenuEntry(value: 'pending', label: l10n.getString('adminStatusPending')),
                  DropdownMenuEntry(value: 'approved', label: l10n.getString('adminStatusApproved')),
                  DropdownMenuEntry(value: 'rejected', label: l10n.getString('adminStatusRejected')),
                  DropdownMenuEntry(value: 'unverified', label: l10n.getString('adminStatusUnverified')),
                  DropdownMenuEntry(value: 'analyzing', label: l10n.getString('adminStatusAnalyzing')),
                ],
                onSelected: (v) {
                  if (v == null) return;
                  setState(() {
                    _status = v;
                  });
                  unawaited(_load(force: true));
                },
                label: Text(l10n.getString('adminVerificationStatusFilter')),
                inputDecorationTheme: const InputDecorationTheme(
                  border: OutlineInputBorder(),
                ),
              ),
              Text(
                l10n
                    .getString('adminVerificationCount')
                    .replaceAll('{count}', filtered.length.toString()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(l10n.getString('adminVerificationEmpty')),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final row = filtered[i];
                      final status = row.verificationStatus;
                      final statusLabel = _statusLabel(l10n, status);
                      final submitted = row.verificationSubmittedAt != null
                          ? _formatAdminDateTime(l10n, row.verificationSubmittedAt!)
                          : '';
                      final reviewed = row.verificationReviewedAt != null
                          ? _formatAdminDateTime(l10n, row.verificationReviewedAt!)
                          : '';
                      final reviewerId = (row.verificationReviewerId ?? '').trim();
                      final reviewerName = (row.verificationReviewerName ?? '').trim();
                      final score = row.verificationSimilarityScore != null
                          ? row.verificationSimilarityScore!.toStringAsFixed(2)
                          : '';
                      String shortReviewer(String id) {
                        final clean = id.trim();
                        if (clean.isEmpty) return '';
                        if (clean.length <= 8) return clean;
                        return clean.substring(0, 8);
                      }

                      String reviewerDisplay() {
                        if (reviewerId.isNotEmpty) {
                          final shortId = shortReviewer(reviewerId);
                          if (reviewerName.isNotEmpty) {
                            final display = maskUserDisplayName(reviewerName);
                            return shortId.isEmpty ? display : '$display ($shortId)';
                          }
                          return shortId;
                        }

                        final isFinalDecision = status == 'approved' || status == 'rejected';
                        if (!isFinalDecision) return '';

                        final analysis = _coerceAnalysisMap(row.verificationAiAnalysis) ?? const {};
                        if (analysis.isNotEmpty || row.verificationAutoRejected) {
                          return l10n.getString('adminVerificationReviewerAi');
                        }
                        return '';
                      }

                      Widget statusBadge() {
                        final scheme = Theme.of(context).colorScheme;
                        final (bg, fg, border) = switch (status) {
                          'approved' => (Colors.green.shade700, Colors.white, null),
                          'rejected' => (Colors.red.shade700, Colors.white, null),
                          _ => (
                              scheme.surface,
                              scheme.onSurface,
                              BorderSide(color: Theme.of(context).dividerColor),
                            ),
                        };
                        return DecoratedBox(
                          decoration: ShapeDecoration(
                            color: bg,
                            shape: StadiumBorder(side: border ?? BorderSide.none),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Text(
                              statusLabel,
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: fg,
                                  ),
                            ),
                          ),
                        );
                      }

                      final reviewedSummary = reviewed;
                      final reviewedBy = reviewerDisplay();
                      final hasPhoto = (row.verificationPhotoPath ?? '').trim().isNotEmpty;

                      return Card(
                        child: InkWell(
                          onTap: hasPhoto ? () => _showReview(l10n, row) : null,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        (row.name).trim().isEmpty ? row.id : maskUserDisplayName(row.name.trim()),
                                        style: Theme.of(context).textTheme.titleMedium,
                                      ),
                                    ),
                                    if (row.isVerified) ...[
                                      const SizedBox(width: 8),
                                      const Icon(Icons.verified, color: Colors.green),
                                    ],
                                    const SizedBox(width: 8),
                                    statusBadge(),
                                  ],
                                ),
                                if (reviewedBy.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 520),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Theme.of(context).dividerColor,
                                            ),
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            child: Text(
                                              '${l10n.getString('adminVerificationReviewedBy')}: $reviewedBy',
                                              style: Theme.of(context).textTheme.labelMedium,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (submitted.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminVerificationSubmitted'),
                                        value: submitted,
                                      ),
                                    if (reviewedSummary.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminVerificationReviewed'),
                                        value: reviewedSummary,
                                      ),
                                    if (score.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminVerificationScore'),
                                        value: score,
                                      ),
                                    if (row.verificationAutoRejected)
                                      _MetaChip(
                                        label: l10n.getString('adminVerificationAutoRejected'),
                                        value: l10n.getString('adminYes'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final isWide = constraints.maxWidth >= 720;

                                    final infoButtons = Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if ((_coerceAnalysisMap(row.verificationAiAnalysis) ??
                                                const {})
                                            .isNotEmpty)
                                          OutlinedButton.icon(
                                            onPressed: () => _showAiAnalysis(l10n, row),
                                            icon: const Icon(Icons.psychology_outlined),
                                            label: Text(
                                              l10n.getString('adminVerificationAiAnalysis'),
                                            ),
                                          ),
                                        OutlinedButton.icon(
                                          onPressed: hasPhoto ? () => _showReview(l10n, row) : null,
                                          icon: const Icon(Icons.image_outlined),
                                          label: Text(
                                            l10n.getString('adminVerificationViewPhoto'),
                                          ),
                                        ),
                                      ],
                                    );

                                    final actionButtons = Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        ElevatedButton.icon(
                                          onPressed: status == 'approved'
                                              ? null
                                              : () => _setStatus(l10n, row.id, 'approved'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.green.shade700,
                                            foregroundColor: Colors.white,
                                            disabledBackgroundColor: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            disabledForegroundColor: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withAlpha(97),
                                          ),
                                          icon: const Icon(Icons.check),
                                          label: Text(l10n.getString('adminApprove')),
                                        ),
                                        ElevatedButton.icon(
                                          onPressed: status == 'rejected'
                                              ? null
                                              : () => _setStatus(l10n, row.id, 'rejected'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red.shade700,
                                            foregroundColor: Colors.white,
                                            disabledBackgroundColor: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            disabledForegroundColor: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withAlpha(97),
                                          ),
                                          icon: const Icon(Icons.close),
                                          label: Text(l10n.getString('adminReject')),
                                        ),
                                      ],
                                    );

                                    if (!isWide) {
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          infoButtons,
                                          const SizedBox(height: 8),
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: actionButtons,
                                          ),
                                        ],
                                      );
                                    }

                                    return Row(
                                      children: [
                                        Expanded(child: infoButtons),
                                        const SizedBox(width: 12),
                                        actionButtons,
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProfileEditRequestRow {
  final String id;
  final String userId;
  final String userName;
  final List<String> requestedFields;
  final String message;
  final List<Map<String, dynamic>> attachments;
  final String status;
  final bool changeComplete;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? reviewedAt;
  final String reviewedBy;
  final String reviewerNote;
  final String reviewerName;

  const _ProfileEditRequestRow({
    required this.id,
    required this.userId,
    required this.userName,
    required this.requestedFields,
    required this.message,
    required this.attachments,
    required this.status,
    required this.changeComplete,
    required this.createdAt,
    required this.updatedAt,
    required this.reviewedAt,
    required this.reviewedBy,
    required this.reviewerNote,
    required this.reviewerName,
  });

  static DateTime? _tryDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  static List<String> _toStringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    }
    return const [];
  }

  static List<Map<String, dynamic>> _toMapList(dynamic v) {
    if (v == null) return const [];
    if (v is List) {
      final out = <Map<String, dynamic>>[];
      for (final item in v) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }
    return const [];
  }

  factory _ProfileEditRequestRow.fromMap(Map<String, dynamic> row) {
    final rawComplete = row['change_complete'] ?? row['changeComplete'] ?? false;
    final changeComplete = rawComplete is bool
        ? rawComplete
        : rawComplete.toString().toLowerCase() == 'true';
    return _ProfileEditRequestRow(
      id: (row['id'] ?? '').toString(),
      userId: (row['user_id'] ?? '').toString(),
      userName: (row['user_name'] ?? '').toString(),
      requestedFields: _toStringList(row['requested_fields']),
      message: (row['message'] ?? '').toString(),
      attachments: _toMapList(row['attachments']),
      status: (row['status'] ?? 'pending').toString(),
      changeComplete: changeComplete,
      createdAt: _tryDate(row['created_at']),
      updatedAt: _tryDate(row['updated_at']),
      reviewedAt: _tryDate(row['reviewed_at']),
      reviewedBy: (row['reviewed_by'] ?? '').toString(),
      reviewerNote: (row['reviewer_note'] ?? '').toString(),
      reviewerName: (row['reviewer_name'] ?? '').toString(),
    );
  }
}

class _ProfileEditRequestsScreen extends ConsumerStatefulWidget {
  const _ProfileEditRequestsScreen();

  @override
  ConsumerState<_ProfileEditRequestsScreen> createState() => _ProfileEditRequestsScreenState();
}

class _ProfileEditRequestsScreenState extends ConsumerState<_ProfileEditRequestsScreen> {
  bool _isLoading = true;
  String? _errorKey;
  List<_ProfileEditRequestRow> _rows = const [];

  String _query = '';
  String _status = 'pending';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    List<Map<String, dynamic>> decodeListMap(Object? raw) {
      if (raw is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      return out;
    }

    final queryTrimmed = _query.trim();
    final queryKey =
        queryTrimmed.isEmpty ? 'none' : base64UrlEncode(utf8.encode(queryTrimmed));
    final cacheKey = 'admin_cache:profile_edits:v4:$_status:$queryKey';
    var hadCached = false;

    if (!force) {
      final cached = await _AdminCache.read<List<Map<String, dynamic>>>(
        cacheKey,
        decodeListMap,
      );
      if (!mounted) return;
      if (cached != null) {
        final mapped = cached.data
            .map((e) => _ProfileEditRequestRow.fromMap(e))
            .toList(growable: false);
        setState(() {
          _rows = mapped;
          _isLoading = false;
          _errorKey = null;
        });
        hadCached = true;
        if (cached.isFresh) return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = !hadCached;
      _errorKey = null;
    });

    try {
      final result = await Supabase.instance.client.rpc(
        'admin_list_profile_edit_requests',
        params: {
          'p_status': _status == 'all' ? null : _status,
          'p_query': queryTrimmed.isEmpty ? null : queryTrimmed,
          'p_limit': 200,
          'p_offset': 0,
        },
      ).timeout(const Duration(seconds: 12));

      final list = (result as List<dynamic>).cast<dynamic>();
      final raw = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      await _AdminCache.write<List<Map<String, dynamic>>>(
        cacheKey,
        (v) => v,
        raw,
      );

      final mapped =
          raw.map((e) => _ProfileEditRequestRow.fromMap(e)).toList(growable: false);

      if (!mounted) return;
      setState(() {
        _rows = mapped;
        _isLoading = false;
      });
    } catch (e, st) {
      debugPrint('admin_list_profile_edit_requests failed: $e');
      debugPrint('$st');
      if (!mounted) return;
      if (hadCached) {
        final l10n = ref.read(localizationProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminProfileEditsLoadFailed'))),
        );
      } else {
        setState(() {
          _errorKey = 'adminProfileEditsLoadFailed';
          _isLoading = false;
        });
      }
    }
  }

  String _statusLabel(LocalizationState l10n, String status) {
    return switch (status) {
      'pending' => l10n.getString('adminStatusPending'),
      'approved' => l10n.getString('adminStatusApproved'),
      'rejected' => l10n.getString('adminStatusRejected'),
      _ => status,
    };
  }

  String _normalizeStorageObjectPath(String bucket, String objectPath) {
    var clean = objectPath.trim();
    if (clean.startsWith('/')) clean = clean.substring(1);
    final prefix = '$bucket/';
    if (clean.startsWith(prefix)) clean = clean.substring(prefix.length);
    return clean;
  }

  String _extensionFromNameOrPath(String name, String objectPath) {
    final src = name.trim().isNotEmpty ? name.trim() : objectPath.trim();
    final dot = src.lastIndexOf('.');
    if (dot <= 0 || dot >= src.length - 1) return '';
    return src.substring(dot + 1).toLowerCase().trim();
  }

  Future<String?> _getSignedUrl(String bucket, String objectPath) async {
    final clean = _normalizeStorageObjectPath(bucket, objectPath);
    if (clean.isEmpty) return null;
    final signedUrlCacheKey = 'admin_cache:signed_url:v1:$bucket:$clean';
    final cached = await _AdminCache.read<String>(
      signedUrlCacheKey,
      (raw) => (raw ?? '').toString(),
    );
    final cachedUrl = cached?.data.trim() ?? '';
    if (cachedUrl.isNotEmpty && (cached?.isFresh ?? false)) {
      return cachedUrl;
    }

    try {
      final dynamic resp = await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(clean, 600)
          .timeout(const Duration(seconds: 8));

      if (resp == null) return cachedUrl.isNotEmpty ? cachedUrl : null;

      String? resolveRelativeUrl(String url) {
        final trimmed = url.trim();
        if (trimmed.isEmpty) return null;
        if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return trimmed;
        if (!trimmed.startsWith('/')) return trimmed;
        try {
          final dynamic c = Supabase.instance.client;
          final base = (c.supabaseUrl as String?)?.trim();
          if (base == null || base.isEmpty) return trimmed;
          return Uri.parse(base).resolve(trimmed).toString();
        } catch (_) {
          return trimmed;
        }
      }

      bool looksSigned(String url) {
        try {
          final uri = Uri.parse(url);
          if (uri.queryParameters.containsKey('token')) return true;
          if (uri.query.isNotEmpty &&
              (uri.query.contains('X-Amz-') || uri.query.contains('X-Amz-Signature'))) {
            return true;
          }
        } catch (_) {}
        return false;
      }

      String attachTokenIfNeeded(String url, String? token) {
        if (token == null || token.trim().isEmpty) return url;
        if (url.contains('token=')) return url;
        final sep = url.contains('?') ? '&' : '?';
        return '$url${sep}token=${Uri.encodeQueryComponent(token.trim())}';
      }

      if (resp is String) {
        final resolved = resolveRelativeUrl(resp);
        if (resolved == null) return cachedUrl.isNotEmpty ? cachedUrl : null;
        final out = looksSigned(resolved) ? resolved : null;
        if (out != null) {
          await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
        }
        return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
      }
      if (resp is Map) {
        final token = resp['token']?.toString();
        final rawUrl = (resp['signedUrl'] ??
                resp['signed_url'] ??
                resp['signedurl'] ??
                resp['signedURL'] ??
                resp['signed_url'])
            ?.toString();
        if (rawUrl != null && rawUrl.trim().isNotEmpty) {
          final resolved = resolveRelativeUrl(rawUrl);
          if (resolved == null) return cachedUrl.isNotEmpty ? cachedUrl : null;
          final withToken = attachTokenIfNeeded(resolved, token);
          final out = looksSigned(withToken) ? withToken : null;
          if (out != null) {
            await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
          }
          return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
        }
        final data = resp['data'];
        if (data is Map) {
          final nestedToken = data['token']?.toString() ?? token;
          final nestedUrl = (data['signedUrl'] ??
                  data['signed_url'] ??
                  data['signedurl'] ??
                  data['signedURL'] ??
                  data['signed_url'])
              ?.toString();
          if (nestedUrl != null && nestedUrl.trim().isNotEmpty) {
            final resolved = resolveRelativeUrl(nestedUrl);
            if (resolved == null) return cachedUrl.isNotEmpty ? cachedUrl : null;
            final withToken = attachTokenIfNeeded(resolved, nestedToken);
            final out = looksSigned(withToken) ? withToken : null;
            if (out != null) {
              await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
            }
            return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
          }
        }
      }
      try {
        final maybe = (resp as dynamic).signedUrl ?? (resp as dynamic).data?.signedUrl;
        if (maybe is String && maybe.trim().isNotEmpty) {
          final resolved = resolveRelativeUrl(maybe);
          if (resolved == null) return cachedUrl.isNotEmpty ? cachedUrl : null;
          final out = looksSigned(resolved) ? resolved : null;
          if (out != null) {
            await _AdminCache.write<String>(signedUrlCacheKey, (v) => v, out);
          }
          return out ?? (cachedUrl.isNotEmpty ? cachedUrl : null);
        }
      } catch (_) {}

      return cachedUrl.isNotEmpty ? cachedUrl : null;
    } catch (_) {
      return cachedUrl.isNotEmpty ? cachedUrl : null;
    }
  }

  String? _contentTypeForExtension(String ext) {
    return switch (ext.toLowerCase().trim()) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      _ => null,
    };
  }

  Future<void> _openAttachmentInSystem(
    LocalizationState l10n, {
    required String title,
    required String bucket,
    required String objectPath,
  }) async {
    final normalized = _normalizeStorageObjectPath(bucket, objectPath);
    if (normalized.isEmpty) return;

    final url = await _getSignedUrl(bucket, normalized);
    if (url == null || url.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminAttachmentLoadFailed'))),
      );
      return;
    }

    var opened = false;
    if (!kIsWeb) {
      try {
        final bytes = await Supabase.instance.client.storage.from(bucket).download(normalized);
        final fileName = title.trim().isNotEmpty ? title.trim() : normalized.split('/').last;
        final ext = _extensionFromNameOrPath(fileName, normalized);
        opened = await openBytesInDefaultApp(
          bytes,
          suggestedFileName: fileName,
          contentType: _contentTypeForExtension(ext),
        );
      } catch (_) {
        opened = false;
      }
    }

    opened = opened || await openUrlExternal(url);
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminAttachmentOpenFailed'))),
      );
    }
  }

  Future<void> _deleteProfileEditAttachments(List<Map<String, dynamic>> attachments) async {
    if (attachments.isEmpty) return;

    final byBucket = <String, Set<String>>{};
    for (final a in attachments) {
      final bucket = (a['bucket'] ?? 'profile-edit-attachments').toString().trim();
      final rawPath = (a['url'] ?? a['path'] ?? a['objectPath'] ?? '').toString().trim();
      if (bucket.isEmpty || rawPath.isEmpty) continue;
      final normalized = _normalizeStorageObjectPath(bucket, rawPath);
      if (normalized.trim().isEmpty) continue;
      (byBucket[bucket] ??= <String>{}).add(normalized);
    }

    for (final entry in byBucket.entries) {
      final bucket = entry.key;
      final paths = entry.value.toList(growable: false);
      if (paths.isEmpty) continue;
      try {
        await Supabase.instance.client.storage.from(bucket).remove(paths);
      } catch (e, st) {
        developer.log(
          'Failed to delete profile edit attachments from bucket: $bucket',
          name: 'MatchMeAdmin',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<void> _review(LocalizationState l10n, _ProfileEditRequestRow row, String decision) async {
    final note = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(
            decision == 'approved'
                ? l10n.getString('adminProfileEditsApproveTitle')
                : l10n.getString('adminProfileEditsRejectTitle'),
          ),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: l10n.getString('adminReviewerNote'),
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (note == null) return;

    try {
      final normalizedId = row.id.trim();
      final isUuid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(normalizedId);
      if (!isUuid) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.getString('adminProfileEditsUpdateFailed'))),
        );
        return;
      }

      final trimmedNote = note.trim();
      await Supabase.instance.client.rpc(
        'admin_review_profile_edit_request',
        params: {
          'p_request_id': normalizedId,
          'p_decision': decision,
          if (trimmedNote.isNotEmpty) 'p_reviewer_note': trimmedNote,
        },
      ).timeout(const Duration(seconds: 20));

      await _deleteProfileEditAttachments(row.attachments)
          .timeout(const Duration(seconds: 20), onTimeout: () {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString('adminSaved'))),
      );
      unawaited(_load(force: true));
    } on PostgrestException catch (e, st) {
      developer.log(
        'admin_review_profile_edit_request PostgREST error',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      final msg = '${e.message} ${e.hint ?? ''} ${e.details ?? ''}';
      final key =
          msg.contains('No API key found') || msg.contains('apikey') || msg.contains('No `apikey`')
              ? 'supabaseConfigMissing'
              : 'adminProfileEditsUpdateFailed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString(key))),
      );
    } catch (e, st) {
      developer.log(
        'admin_review_profile_edit_request failed',
        name: 'MatchMeAdmin',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      final msg = e.toString();
      final key =
          msg.contains('No API key found') || msg.contains('apikey') || msg.contains('No `apikey`')
              ? 'supabaseConfigMissing'
              : 'adminProfileEditsUpdateFailed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.getString(key))),
      );
    }
  }

  Future<void> _showDetails(LocalizationState l10n, _ProfileEditRequestRow row) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final statusLabel = _statusLabel(l10n, row.status);
        String fmt(DateTime? v) => v == null ? '' : _formatAdminDateTime(l10n, v);

        final created = fmt(row.createdAt);
        final updated = fmt(row.updatedAt);
        final reviewedAt = fmt(row.reviewedAt);
        final reviewerName = row.reviewerName.trim();
        final reviewerId = row.reviewedBy.trim();
        final reviewerNote = row.reviewerNote.trim();

        final showUpdatedEvent = row.updatedAt != null &&
            row.createdAt != null &&
            row.updatedAt!.millisecondsSinceEpoch != row.createdAt!.millisecondsSinceEpoch &&
            (row.reviewedAt == null ||
                row.updatedAt!.millisecondsSinceEpoch != row.reviewedAt!.millisecondsSinceEpoch);

        Widget statusBadge() {
          final scheme = Theme.of(ctx).colorScheme;
          final (bg, fg, border) = switch (row.status) {
            'approved' => (Colors.green.shade700, Colors.white, null),
            'rejected' => (Colors.red.shade700, Colors.white, null),
            _ => (
                scheme.surface,
                scheme.onSurface,
                BorderSide(color: Theme.of(ctx).dividerColor),
              ),
          };
          return DecoratedBox(
            decoration: ShapeDecoration(
              color: bg,
              shape: StadiumBorder(side: border ?? BorderSide.none),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                statusLabel,
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: fg,
                    ),
              ),
            ),
          );
        }

        Widget timelineEvent({
          required IconData icon,
          required String title,
          required List<Widget> children,
        }) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  foregroundColor: Theme.of(ctx).colorScheme.onSurface,
                  child: Icon(icon, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(ctx).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      ...children,
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return AlertDialog(
          title: Text(l10n.getString('adminProfileEditsDetailsTitle')),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 680,
              maxHeight: (MediaQuery.of(ctx).size.height -
                      MediaQuery.of(ctx).viewPadding.vertical) *
                  0.7,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          row.userName.trim().isEmpty ? row.userId : maskUserDisplayName(row.userName),
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      statusBadge(),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _KeyPreviewRow(
                    title: l10n.getString('adminRequestId'),
                    value: row.id,
                  ),
                  const SizedBox(height: 8),
                  _KeyPreviewRow(
                    title: l10n.getString('adminUserId'),
                    value: row.userId,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.getString('adminProfileEditsFields'),
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (row.requestedFields.isEmpty)
                    const SizedBox.shrink()
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in row.requestedFields) Chip(label: Text(f)),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.getString('adminProfileEditsMessage'),
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (context) {
                      bool isRtlText(String text) {
                        bool isStrongRtl(int rune) {
                          return (rune >= 0x0590 && rune <= 0x08FF) ||
                              (rune >= 0xFB1D && rune <= 0xFEFC);
                        }

                        bool isStrongLtr(int rune) {
                          return (rune >= 0x0041 && rune <= 0x005A) ||
                              (rune >= 0x0061 && rune <= 0x007A);
                        }

                        for (final rune in text.runes) {
                          if (isStrongRtl(rune)) return true;
                          if (isStrongLtr(rune)) return false;
                        }
                        return false;
                      }

                      final rtl = isRtlText(row.message);
                      return SizedBox(
                        width: double.infinity,
                        child: SelectableText(
                          row.message,
                          textAlign: rtl ? TextAlign.right : TextAlign.left,
                          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.getString('adminProfileEditsAttachments'), style: Theme.of(ctx).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (row.attachments.isEmpty)
                    Text(l10n.getString('adminProfileEditsNoAttachments'))
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: row.attachments.map((a) {
                        final name = (a['name'] ?? '').toString();
                        final url = (a['url'] ?? '').toString();
                        final bucket = (a['bucket'] ?? 'profile-photos').toString();
                        final extSource = name.trim().isNotEmpty ? name : url;
                        final dot = extSource.lastIndexOf('.');
                        final ext = dot >= 0 && dot < extSource.length - 1
                            ? extSource.substring(dot + 1).toLowerCase().trim()
                            : '';
                        final isImage = switch (ext) {
                          'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => true,
                          _ => false,
                        };
                        final icon = isImage
                            ? Icons.image_outlined
                            : (ext == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.description_outlined);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: OutlinedButton.icon(
                            onPressed: url.trim().isEmpty
                                ? null
                                : () => _openAttachmentInSystem(
                                      l10n,
                                      title: name,
                                      bucket: bucket,
                                      objectPath: url,
                                    ),
                            icon: Icon(icon),
                            label: Text(name.trim().isEmpty ? l10n.getString('adminAttachment') : name),
                          ),
                        );
                      }).toList(growable: false),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.getString('adminAuditTrail'),
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  timelineEvent(
                    icon: Icons.upload_file,
                    title: l10n.getString('adminVerificationSubmitted'),
                    children: [
                      if (created.isNotEmpty)
                        _KeyPreviewRow(
                          title: l10n.getString('adminProfileEditsCreated'),
                          value: created,
                        ),
                    ],
                  ),
                  if (showUpdatedEvent)
                    timelineEvent(
                      icon: Icons.update,
                      title: l10n.getString('adminLastUpdated'),
                      children: [
                        if (updated.isNotEmpty)
                          _KeyPreviewRow(
                            title: l10n.getString('adminLastUpdated'),
                            value: updated,
                          ),
                      ],
                    ),
                  if (reviewedAt.isNotEmpty)
                    timelineEvent(
                      icon: switch (row.status) {
                        'approved' => Icons.check_circle,
                        'rejected' => Icons.cancel,
                        _ => Icons.rate_review,
                      },
                      title: l10n.getString('adminVerificationReviewed'),
                      children: [
                        _KeyPreviewRow(
                          title: l10n.getString('adminProfileEditsReviewedAt'),
                          value: reviewerNote.isNotEmpty
                              ? '$reviewedAt — $reviewerNote'
                              : reviewedAt,
                        ),
                        _KeyPreviewRow(
                          title: l10n.getString('adminProfileEditsReviewedBy'),
                          value: reviewerName.isNotEmpty
                              ? maskUserDisplayName(reviewerName)
                              : (reviewerId.isNotEmpty ? reviewerId : ''),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.of(ctx).pop(),
              icon: const Icon(Icons.close),
              label: Text(l10n.getString('generalClose')),
            ),
            ElevatedButton.icon(
              onPressed: (row.status == 'approved' || row.changeComplete)
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      unawaited(_review(l10n, row, 'approved'));
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                disabledForegroundColor: Theme.of(context).colorScheme.onSurface.withAlpha(97),
              ),
              icon: const Icon(Icons.check),
              label: Text(l10n.getString('adminApprove')),
            ),
            ElevatedButton.icon(
              onPressed: (row.status == 'rejected' || row.changeComplete)
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      unawaited(_review(l10n, row, 'rejected'));
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                disabledForegroundColor: Theme.of(context).colorScheme.onSurface.withAlpha(97),
              ),
              icon: const Icon(Icons.close),
              label: Text(l10n.getString('adminReject')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    if (_isLoading) {
      return Center(child: Text(l10n.getString('generalLoading')));
    }

    if (_errorKey != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString(_errorKey!), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.getString('generalRefresh')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final filtered = _rows.where((r) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return r.userId.toLowerCase().contains(q) ||
          r.userName.toLowerCase().contains(q) ||
          r.requestedFields.join(',').toLowerCase().contains(q) ||
          r.message.toLowerCase().contains(q);
    }).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('adminNavProfileEdits'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.getString('generalRefresh')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: l10n.getString('adminProfileEditsSearchHint'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              DropdownMenu<String>(
                initialSelection: _status,
                dropdownMenuEntries: [
                  DropdownMenuEntry(value: 'all', label: l10n.getString('adminStatusAll')),
                  DropdownMenuEntry(value: 'pending', label: l10n.getString('adminStatusPending')),
                  DropdownMenuEntry(value: 'approved', label: l10n.getString('adminStatusApproved')),
                  DropdownMenuEntry(value: 'rejected', label: l10n.getString('adminStatusRejected')),
                ],
                onSelected: (v) {
                  if (v == null) return;
                  setState(() {
                    _status = v;
                  });
                  unawaited(_load(force: true));
                },
                label: Text(l10n.getString('adminProfileEditsStatusFilter')),
                inputDecorationTheme: const InputDecorationTheme(
                  border: OutlineInputBorder(),
                ),
              ),
              Text(
                l10n
                    .getString('adminProfileEditsCount')
                    .replaceAll('{count}', filtered.length.toString()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text(l10n.getString('adminProfileEditsEmpty')))
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final row = filtered[i];
                      final statusLabel = _statusLabel(l10n, row.status);
                      final created = row.createdAt == null
                          ? ''
                          : _formatAdminDateTime(l10n, row.createdAt!);
                      final reviewedAt = row.reviewedAt == null
                          ? ''
                          : _formatAdminDateTime(l10n, row.reviewedAt!);
                      final reviewer = maskUserDisplayName(row.reviewerName.trim());
                      final reviewerNote = row.reviewerNote.trim();
                      final reason = row.message.trim();
                      String shortNote(String v) {
                        final singleLine = v.replaceAll(RegExp(r'\s+'), ' ').trim();
                        if (singleLine.length <= 80) return singleLine;
                        return '${singleLine.substring(0, 77)}…';
                      }

                      String shortReason(String v) {
                        final singleLine = v.replaceAll(RegExp(r'\s+'), ' ').trim();
                        if (singleLine.length <= 220) return singleLine;
                        return '${singleLine.substring(0, 217)}…';
                      }

                      bool isRtlText(String text) {
                        bool isStrongRtl(int rune) {
                          return (rune >= 0x0590 && rune <= 0x08FF) ||
                              (rune >= 0xFB1D && rune <= 0xFEFC);
                        }

                        bool isStrongLtr(int rune) {
                          return (rune >= 0x0041 && rune <= 0x005A) ||
                              (rune >= 0x0061 && rune <= 0x007A);
                        }

                        for (final rune in text.runes) {
                          if (isStrongRtl(rune)) return true;
                          if (isStrongLtr(rune)) return false;
                        }
                        return false;
                      }

                      final reviewed = [
                        if (reviewedAt.isNotEmpty) reviewedAt,
                        if (reviewerNote.isNotEmpty) shortNote(reviewerNote),
                        if (reviewer.isNotEmpty) reviewer,
                      ].join(' • ');

                      String requestedFieldSummary(List<String> fields) {
                        final clean = fields
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList(growable: false);
                        if (clean.isEmpty) return '';
                        if (clean.length == 1) return clean.first;
                        return '${clean.first} +${clean.length - 1}';
                      }

                      Widget statusBadge() {
                        final scheme = Theme.of(context).colorScheme;
                        final (bg, fg, border) = switch (row.status) {
                          'approved' => (Colors.green.shade700, Colors.white, null),
                          'rejected' => (Colors.red.shade700, Colors.white, null),
                          _ => (
                              scheme.surface,
                              scheme.onSurface,
                              BorderSide(color: Theme.of(context).dividerColor),
                            ),
                        };
                        return DecoratedBox(
                          decoration: ShapeDecoration(
                            color: bg,
                            shape: StadiumBorder(side: border ?? BorderSide.none),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Text(
                              statusLabel,
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: fg,
                                  ),
                            ),
                          ),
                        );
                      }

                      Widget changeCompleteBadge() {
                        final scheme = Theme.of(context).colorScheme;
                        return DecoratedBox(
                          decoration: ShapeDecoration(
                            color: scheme.surfaceContainerHighest,
                            shape: StadiumBorder(side: BorderSide(color: Theme.of(context).dividerColor)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Text(
                              l10n.getString('adminProfileEditsChangeComplete'),
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                        );
                      }

                      final fieldSummary = requestedFieldSummary(row.requestedFields);

                      return Card(
                        child: InkWell(
                          onTap: () => _showDetails(l10n, row),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        row.userName.trim().isEmpty ? row.userId : maskUserDisplayName(row.userName),
                                        style: Theme.of(context).textTheme.titleMedium,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (fieldSummary.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Theme.of(context).dividerColor,
                                          ),
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          child: Text(
                                            fieldSummary,
                                            style: Theme.of(context).textTheme.labelMedium,
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        statusBadge(),
                                        if (row.status == 'approved' && row.changeComplete) changeCompleteBadge(),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (created.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminProfileEditsCreated'),
                                        value: created,
                                      ),
                                    if (reviewed.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminVerificationReviewed'),
                                        value: reviewed,
                                      ),
                                    if (row.attachments.isNotEmpty)
                                      _MetaChip(
                                        label: l10n.getString('adminProfileEditsAttachmentsShort'),
                                        value: row.attachments.length.toString(),
                                      ),
                                  ],
                                ),
                                if (reason.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    shortReason(reason),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: isRtlText(reason) ? TextAlign.right : TextAlign.left,
                                    textDirection: isRtlText(reason) ? TextDirection.rtl : TextDirection.ltr,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () => _showDetails(l10n, row),
                                        icon: const Icon(Icons.open_in_new),
                                        label: Text(
                                          l10n.getString('adminProfileEditsDetails'),
                                        ),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: (row.status == 'approved' || row.changeComplete)
                                            ? null
                                            : () => _review(l10n, row, 'approved'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.green.shade700,
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          disabledForegroundColor: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withAlpha(97),
                                        ),
                                        icon: const Icon(Icons.check),
                                        label: Text(l10n.getString('adminApprove')),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: (row.status == 'rejected' || row.changeComplete)
                                            ? null
                                            : () => _review(l10n, row, 'rejected'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red.shade700,
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          disabledForegroundColor: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withAlpha(97),
                                        ),
                                        icon: const Icon(Icons.close),
                                        label: Text(l10n.getString('adminReject')),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

const Map<String, String> _defaultTranslations = {
  'adminAppTitle': 'MatchMe Admin',
  'adminLoginTitle': 'Admin Login',
  'adminNotAuthorized': 'You do not have access to this app.',
  'adminAuthCheckFailed': 'Failed to verify admin access.',
  'authStreamError': 'Auth Stream Error',
  'supabaseConfigMissing': 'Supabase configuration missing',
  'generalLoading': 'Loading…',
  'authEmail': 'Email',
  'authEmailRequired': 'Email is required',
  'authPassword': 'Password',
  'authPasswordRequired': 'Password is required',
  'authLogin': 'Log In',
  'authLoginFailed': 'Login failed. Please try again.',
  'authSignOut': 'Sign Out',
  'adminChangeLanguage': 'Change language',
  'languageShort_en': 'EN',
  'languageShort_es': 'ES',
  'languageShort_he': 'HE',
  'generalSave': 'Save',
  'generalCancel': 'Cancel',
  'generalClose': 'Close',
  'generalApply': 'Apply',
  'generalClear': 'Clear',
  'generalFilters': 'Filters',
  'generalAny': 'Any',
  'generalLoadMore': 'Load more',
  'generalDelete': 'Delete',
  'generalEdit': 'Edit',
  'generalAdd': 'Add',
  'generalRefresh': 'Refresh',
  'adminNavDashboard': 'Dashboard',
  'adminNavAppConfig': 'App Config',
  'adminNavTranslations': 'Translations',
  'adminNavSubscriptions': 'Subscriptions',
  'adminNavBroadcasts': 'Broadcasts',
  'adminNavIntentsInterests': 'Intents & Interests',
  'adminNavVerification': 'User Verification',
  'adminNavProfileEdits': 'Profile Edit Requests',
  'adminProfileEditsChangeComplete': 'Change complete',
  'adminDashboardLoadFailed': 'Failed to load dashboard.',
  'adminDashboardWindow24h': '24h',
  'adminDashboardWindow7d': '7d',
  'adminDashboardLastUpdated': 'Last updated: {time}',
  'adminDashboardEngagement': 'Engagement',
  'adminDashboardOperations': 'Operations',
  'adminDashboardRevenue': 'Revenue',
  'adminDashboardSafety': 'Safety',
  'adminDashboardEarnings': 'Earnings',
  'adminDashboardAI': 'AI',
  'adminDashboardAIUsageTitle': 'AI usage',
  'adminDashboardAIUsageEmpty': 'No AI calls in this window.',
  'adminDashboardAIProvider': 'Provider',
  'adminDashboardAIModel': 'Model',
  'adminDashboardAITask': 'Task',
  'adminDashboardAICalls': 'Calls',
  'adminDashboardAIFailures': 'Failures',
  'adminDashboardAIQuotaTitle': 'AI quotas',
  'adminDashboardAIQuotaUpdatedAt': 'Updated',
  'adminDashboardAIQuotaEmpty': 'No quota data yet.',
  'adminDashboardAIQuotaMetric': 'Metric',
  'adminDashboardAIQuotaWindow': 'Window',
  'adminDashboardAIQuotaUsed': 'Used',
  'adminDashboardAIQuotaLimit': 'Limit',
  'adminDashboardAIQuotaPercent': '%',
  'adminDashboardAIQuotaStatus': 'Status',
  'adminDashboardAIQuotaWindowBillingPeriod': 'Billing period',
  'adminAiProviderDeepL': 'DeepL',
  'adminAiProviderGemini': 'Gemini',
  'adminAiQuotaStatusOk': 'OK',
  'adminAiQuotaStatusWarn': 'Warning',
  'adminAiQuotaStatusCritical': 'Critical',
  'adminAiQuotaStatusUnknown': 'Unknown',
  'adminDashboardAIRecentErrorsTitle': 'AI errors (recent)',
  'adminDashboardEdgeFunctions': 'Edge Functions',
  'adminDashboardEdgeFunctionsUsageTitle': 'Edge Function usage',
  'adminDashboardEdgeFunctionsUsageEmpty': 'No Edge Function calls in this window.',
  'adminDashboardEdgeFunctionName': 'Function',
  'adminDashboardEdgeFunctionCalls': 'Calls',
  'adminDashboardEdgeFunctionFailures': 'Failures',
  'adminDashboardEdgeFunctionLastErrorAt': 'Last error',
  'adminDashboardEdgeFunctionsRecentErrorsTitle': 'Edge Function errors (recent)',
  'adminDashboardNoRecentErrors': 'No errors in this window.',
  'adminDrilldownLoadFailed': 'Failed to load details.',
  'adminDrilldownEmpty': 'No results.',
  'adminDrilldownUser': 'User',
  'adminDrilldownUserA': 'User A',
  'adminDrilldownUserB': 'User B',
  'adminDrilldownUserId': 'User ID',
  'adminDrilldownCreatedAt': 'Created',
  'adminDrilldownLastActivity': 'Last activity',
  'adminDrilldownMessages': 'Messages',
  'adminDrilldownMatchedAt': 'Matched',
  'adminDrilldownMatchType': 'Basis',
  'adminDrilldownBasis': 'Basis',
  'adminDrilldownBasisProximity': 'Proximity',
  'adminDrilldownBasisEvent': 'Event',
  'adminDrilldownBasisSharedIntent': 'Shared intent',
  'adminDrilldownBasisSharedInterest': 'Shared interest',
  'adminDrilldownUnknown': 'Unknown',
  'adminDrilldownSharedIntent': 'Shared intent',
  'adminDrilldownSharedInterest': 'Shared interest',
  'adminDrilldownEvent': 'Event',
  'adminDrilldownSubmittedAt': 'Submitted',
  'adminDrilldownStatus': 'Status',
  'adminDrilldownTitle': 'Title',
  'adminDrilldownScheduledAt': 'Scheduled',
  'adminDrilldownAttempts': 'Attempts',
  'adminDrilldownFailureReason': 'Failure reason',
  'adminDrilldownSubscriptionTier': 'Tier',
  'adminDrilldownExpiresAt': 'Expires',
  'adminDrilldownInvokedAt': 'Invoked',
  'adminDrilldownFunction': 'Function',
  'adminDrilldownSuccess': 'Success',
  'adminDrilldownDurationMs': 'Duration (ms)',
  'adminDrilldownHttpStatus': 'HTTP',
  'adminDrilldownErrorType': 'Error type',
  'adminDrilldownErrorMessage': 'Error message',
  'adminDrilldownAIUsed': 'AI used',
  'adminDrilldownProvider': 'Provider',
  'adminDrilldownModel': 'Model',
  'adminDrilldownTask': 'Task',
  'adminDashboardSeriesCaption': 'Trends ({window})',
  'adminDashboardSeriesBucketsHourly': '24 bars (hourly)',
  'adminDashboardSeriesBucketsDaily': '7 bars (daily)',
  'adminDashboardBucketHour': 'hour',
  'adminDashboardBucketDay': 'day',
  'adminDashboardSeriesExplanation': 'Each bar is the total for one {bucket}. Rightmost is newest.',
  'adminDashboardSeriesOldest': 'Older',
  'adminDashboardSeriesNewest': 'Newer',
  'adminDashboardSeriesTooltip': '{label}: {value} ({range})',
  'adminDashboardSeriesScrollHint': 'Tip: swipe horizontally on charts to see all bars.',
  'adminDashboardOnlineUsers': 'Online users',
  'adminDashboardVisibleUsers': 'Visible users',
  'adminDashboardNearbyUsers': 'Nearby users (10km)',
  'adminDashboardMatchesCreated': 'Matches created',
  'adminDashboardMessagesSent': 'Messages sent',
  'adminDashboardNewUsers': 'New users',
  'adminDashboardActiveMatches': 'Active matches',
  'adminDashboardVerificationPending': 'Verification pending',
  'adminDashboardVerificationAnalyzing': 'Verification analyzing',
  'adminDashboardProfileEditsPending': 'Profile edits pending',
  'adminDashboardBroadcastsDraft': 'Broadcasts (draft)',
  'adminDashboardBroadcastsScheduled': 'Broadcasts (scheduled)',
  'adminDashboardNotificationsPending': 'Notifications (pending)',
  'adminDashboardNotificationsFailed': 'Notifications (failed)',
  'adminDashboardPaidActiveUsers': 'Paid active users',
  'adminDashboardPaidExpiring7d': 'Paid expiring (7d)',
  'adminDashboardPaidByTier': 'Paid by tier',
  'adminDashboardNoSafetyData': 'Safety signals are not available yet.',
  'adminDashboardSafetyAvailable': 'Safety signals are available.',
  'adminPlaceholderAppConfig': 'Manage app_config values.',
  'adminPlaceholderTranslations': 'Manage translations (en / es / he).',
  'adminPlaceholderSubscriptions': 'Manage subscription tiers and plans.',
  'adminPlaceholderBroadcasts': 'Create and schedule admin broadcasts.',
  'adminPlaceholderIntentsInterests': 'Manage intents, subintents, interests, and subinterests.',
  'adminPlaceholderVerification': 'Review and update user verification status.',
  'adminPlaceholderProfileEdits': 'Approve or deny user profile edit requests.',
  'adminIntentsInterestsTabIntents': 'Intents',
  'adminIntentsInterestsTabInterests': 'Interests',
  'adminIntentsInterestsFilterAll': 'All',
  'adminIntentsInterestsFilterSocial': 'Social',
  'adminIntentsInterestsFilterBusiness': 'Business',
  'adminIntentsInterestsSearchHint': 'Search by key, translation key, or preview',
  'adminIntentsInterestsEmpty': 'No items found.',
  'adminIntentsInterestsLoadFailed': 'Failed to load. Please try again.',
  'adminIntentsInterestsRpcMissing': 'This admin action is not deployed yet. Apply the latest Supabase migrations.',
  'adminIntentsInterestsSaveFailed': 'Failed to save. Please try again.',
  'adminIntentsInterestsDeleteFailed': 'Failed to delete. Please try again.',
  'adminIntentsInterestsEditText': 'Edit text',
  'adminIntentsInterestsEditTextTitle': 'Edit text: {key}',
  'adminIntentsInterestsLocaleEn': 'English',
  'adminIntentsInterestsLocaleEs': 'Spanish',
  'adminIntentsInterestsLocaleHe': 'Hebrew',
  'adminIntentsInterestsAddIntent': 'Add Intent',
  'adminIntentsInterestsEditIntent': 'Edit Intent',
  'adminIntentsInterestsDeleteIntentTitle': 'Delete intent?',
  'adminIntentsInterestsDeleteIntentBody': 'Delete intent "{key}"?',
  'adminIntentsInterestsAddInterest': 'Add Interest',
  'adminIntentsInterestsEditInterest': 'Edit Interest',
  'adminIntentsInterestsDeleteInterestTitle': 'Delete interest?',
  'adminIntentsInterestsDeleteInterestBody': 'Delete interest "{key}"?',
  'adminIntentsInterestsAddChild': 'Add child',
  'adminIntentsInterestsKey': 'Key',
  'adminIntentsInterestsKeyRequired': 'Key is required',
  'adminIntentsInterestsTranslationKey': 'Translation key',
  'adminIntentsInterestsTranslationKeyRequired': 'Translation key is required',
  'adminIntentsInterestsSortOrder': 'Sort order',
  'adminIntentsInterestsParent': 'Parent',
  'adminIntentsInterestsNoParent': 'No parent',
  'adminIntentsInterestsIsSocial': 'Social',
  'adminIntentsInterestsIsBusiness': 'Business',
  'adminAppConfigLoadFailed': 'Failed to load app config.',
  'adminAppConfigSaveFailed': 'Failed to save. Please try again.',
  'adminAppConfigDeleteFailed': 'Failed to delete. Please try again.',
  'adminAppConfigAdd': 'Add Config',
  'adminAppConfigEdit': 'Edit Config',
  'adminAppConfigDeleteTitle': 'Delete config?',
  'adminAppConfigDeleteBody': 'Delete config "{key}"?',
  'adminAppConfigKey': 'Config key',
  'adminAppConfigKeyRequired': 'Config key is required',
  'adminAppConfigValue': 'Config value (JSON)',
  'adminAppConfigValueRequired': 'Config value is required',
  'adminAppConfigType': 'Type',
  'adminAppConfigTypeRequired': 'Type is required',
  'adminAppConfigCategory': 'Category',
  'adminAppConfigCategoryRequired': 'Category is required',
  'adminAppConfigDescription': 'Description',
  'adminAppConfigDescriptionRequired': 'Description is required',
  'adminAppConfigIsUserConfigurable': 'User configurable',
  'adminAppConfigMinValue': 'Min',
  'adminAppConfigMaxValue': 'Max',
  'adminAppConfigAllowedValues': 'Allowed values (JSON)',
  'adminAppConfigAllowedValuesShort': 'Allowed',
  'adminAppConfigSearchHint': 'Search by key, category, type, or description',
  'adminAppConfigClearFilters': 'Clear filters',
  'adminAppConfigAllCategories': 'All categories',
  'adminAppConfigAllUserConfigurable': 'All',
  'adminAppConfigCount': '{count} configs',
  'adminSaved': 'Saved.',
  'adminDeleted': 'Deleted.',
  'adminTranslationsLoadFailed': 'Failed to load translations.',
  'adminTranslationsSaveFailed': 'Failed to save. Please try again.',
  'adminTranslationsDeleteFailed': 'Failed to delete. Please try again.',
  'adminTranslationsAddKey': 'Add Key',
  'adminTranslationsEditKey': 'Edit Key',
  'adminTranslationsDeleteTitle': 'Delete translation key?',
  'adminTranslationsDeleteBody': 'Delete "{key}" for all languages?',
  'adminTranslationsKey': 'Key',
  'adminTranslationsKeyRequired': 'Key is required',
  'adminTranslationsSearchHint': 'Search by key or value',
  'adminTranslationsCount': '{count} keys',
  'adminTranslationsMissingAny': 'Missing any locale',
  'adminTranslationsMissingLocale': 'Missing locale',
  'adminTranslationsAll': 'All',
  'adminTranslationsBulkImport': 'Bulk import',
  'adminTranslationsBulkImportTitle': 'Bulk import translations',
  'adminTranslationsBulkImportFormat':
      'Paste one line per key: key<TAB>en<TAB>es<TAB>he (or key|en|es|he).',
  'adminTranslationsBulkImportDelimiter': 'Delimiter',
  'adminTranslationsBulkImportDelimiterAuto': 'Auto',
  'adminTranslationsBulkImportDelimiterTab': 'Tab',
  'adminTranslationsBulkImportDelimiterPipe': 'Pipe (|)',
  'adminTranslationsBulkImportAllowEmpty': 'Allow empty values (overwrites)',
  'adminTranslationsBulkImportHint':
      'example.key\tEnglish text\tTexto en español\tטקסט בעברית',
  'adminTranslationsBulkImportParsedCount': '{count} rows ready',
  'adminTranslationsBulkImportNothingParsed': 'Nothing to import.',
  'adminTranslationsBulkImportImport': 'Import',
  'adminSubscriptionsLoadFailed': 'Failed to load subscriptions.',
  'adminSubscriptionsSaveFailed': 'Failed to save. Please try again.',
  'adminSubscriptionsDeleteFailed': 'Failed to delete. Please try again.',
  'adminSubscriptionsAddTier': 'Add Tier',
  'adminSubscriptionsEditTier': 'Edit Tier',
  'adminSubscriptionsDeleteTierTitle': 'Delete tier?',
  'adminSubscriptionsDeleteTierBody': 'Delete tier "{id}" and all its plans?',
  'adminSubscriptionsAddPlan': 'Add Plan',
  'adminSubscriptionsEditPlan': 'Edit Plan',
  'adminSubscriptionsDeletePlanTitle': 'Delete plan?',
  'adminSubscriptionsDeletePlanBody': 'Delete plan "{id}"?',
  'adminSubscriptionsTierId': 'Tier ID',
  'adminSubscriptionsTierIdRequired': 'Tier ID is required',
  'adminSubscriptionsPlanId': 'Plan ID',
  'adminSubscriptionsPlanIdRequired': 'Plan ID is required',
  'adminSubscriptionsDuration': 'Duration',
  'adminSubscriptionsPriceDisplay': 'Price display',
  'adminSubscriptionsPriceDisplayRequired': 'Price display is required',
  'adminSubscriptionsSavingsText': 'Savings text',
  'adminSubscriptionsRevenueCatId': 'RevenueCat package identifier',
  'adminSubscriptionsRevenueCatIdRequired': 'RevenueCat identifier is required',
  'adminSubscriptionsSortOrder': 'Sort order',
  'adminSubscriptionsIsActive': 'Active',
  'adminSubscriptionsYes': 'Yes',
  'adminSubscriptionsNo': 'No',
  'adminSubscriptionsTitleKey': 'Title key',
  'adminSubscriptionsTitleKeyRequired': 'Title key is required',
  'adminSubscriptionsSubtitleKey': 'Subtitle key',
  'adminSubscriptionsFeaturesKey': 'Features key',
  'adminSubscriptionsFeaturesKeyRequired': 'Features key is required',
  'adminSubscriptionsBadgeKey': 'Badge key',
  'adminSubscriptionsPreview': 'Preview',
  'adminSubscriptionsPlansHeader': 'Plans',
  'adminSubscriptionsNoPlans': 'No plans yet.',
  'adminSubscriptionsActions': 'Actions',
  'adminYes': 'Yes',
  'adminNo': 'No',
  'adminUnknown': 'Unknown',
  'adminApprove': 'Approve',
  'adminReject': 'Reject',
  'adminAttachment': 'Attachment',
  'adminAttachmentLoadFailed': 'Failed to load attachment.',
  'adminAttachmentOpenInSystem': 'Open in system',
  'adminAttachmentOpenFailed': 'Failed to open attachment.',
  'adminAttachmentNotPreviewable': 'This file cannot be previewed here. Copy the link to open it.',
  'adminAttachmentCopyLink': 'Copy link',
  'adminAttachmentLinkCopied': 'Link copied.',
  'adminReviewerNote': 'Reviewer note',
  'adminStatusAll': 'All',
  'adminStatusPending': 'Pending',
  'adminStatusApproved': 'Approved',
  'adminStatusRejected': 'Rejected',
  'adminStatusUnverified': 'Unverified',
  'adminStatusAnalyzing': 'Analyzing',
  'adminPlatformIos': 'iOS',
  'adminPlatformAndroid': 'Android',
  'adminPlatformWeb': 'Web',
  'adminVerificationLoadFailed': 'Failed to load verification users.',
  'adminVerificationUpdateFailed': 'Failed to update verification. Please try again.',
  'adminVerificationSearchHint': 'Search by user id, name, or status',
  'adminVerificationStatusFilter': 'Status',
  'adminVerificationCount': '{count} users',
  'adminVerificationEmpty': 'No users found.',
  'adminVerificationStatus': 'Status',
  'adminVerificationSubmitted': 'Submitted',
  'adminVerificationReviewed': 'Reviewed',
  'adminVerificationReviewedBy': 'Reviewed by',
  'adminVerificationReviewerAi': 'AI',
  'adminVerificationScore': 'Score',
  'adminVerificationAutoRejected': 'Auto-rejected',
  'adminVerificationViewPhoto': 'View photo',
  'adminVerificationNoPhoto': 'No verification photo.',
  'adminVerificationReviewTitle': 'Verification review',
  'adminVerificationProfilePhoto': 'Profile photo',
  'adminVerificationNoProfilePhoto': 'No profile photo.',
  'adminVerificationAiAnalysis': 'AI analysis',
  'adminVerificationNoAnalysis': 'No AI analysis available.',
  'adminVerificationAiSummaryTitle': 'Summary',
  'adminVerificationAiSummaryUnavailable': 'No summary fields available.',
  'adminVerificationAiDecision': 'Decision',
  'adminVerificationAiMatch': 'Match',
  'adminVerificationAiConfidence': 'Confidence',
  'adminVerificationAiReasons': 'Reasons',
  'adminVerificationAiFlags': 'Flags',
  'adminVerificationAiDetailsTitle': 'Details',
  'adminVerificationAiDetailsRoot': 'Analysis',
  'adminVerificationAiRawJson': 'Raw JSON',
  'adminVerificationAiFieldAuthenticityAudit': 'Authenticity audit',
  'adminVerificationAiFieldAuthentic': 'Authentic',
  'adminVerificationAiFieldComparedAt': 'Compared at',
  'adminVerificationAiFieldConfidence': 'Confidence',
  'adminVerificationAiFieldGesture': 'Gesture',
  'adminVerificationAiFieldGestureRequirement': 'Gesture requirement',
  'adminVerificationAiFieldMatch': 'Face match',
  'adminVerificationAiFieldNote': 'Note',
  'adminVerificationAiFieldReasoning': 'Reasoning',
  'adminVerificationAiFieldService': 'Service',
  'adminVerificationAiFieldSimilarity': 'Similarity',
  'adminVerificationPhotoTitle': 'Verification photo',
  'adminVerificationPhotoLoadFailed': 'Failed to load photo.',
  'adminProfileEditsLoadFailed': 'Failed to load profile edit requests.',
  'adminProfileEditsUpdateFailed': 'Failed to update request. Please try again.',
  'adminProfileEditsSearchHint': 'Search by user, field, or message',
  'adminProfileEditsStatusFilter': 'Status',
  'adminProfileEditsCount': '{count} requests',
  'adminProfileEditsEmpty': 'No requests found.',
  'adminProfileEditsStatus': 'Status',
  'adminProfileEditsCreated': 'Created',
  'adminProfileEditsFields': 'Fields',
  'adminProfileEditsAttachments': 'Attachments',
  'adminProfileEditsAttachmentsShort': 'Files',
  'adminProfileEditsNoAttachments': 'No attachments.',
  'adminProfileEditsDetails': 'Details',
  'adminProfileEditsDetailsTitle': 'Request details',
  'adminProfileEditsUser': 'User',
  'adminProfileEditsMessage': 'Message',
  'adminProfileEditsReviewedAt': 'Reviewed at',
  'adminProfileEditsReviewedBy': 'Reviewed by',
  'adminRequestId': 'Request ID',
  'adminUserId': 'User ID',
  'adminAuditTrail': 'Audit trail',
  'adminLastUpdated': 'Last updated',
  'adminProfileEditsApproveTitle': 'Approve request',
  'adminProfileEditsRejectTitle': 'Reject request',
  'adminBroadcastsLoadFailed': 'Failed to load broadcasts.',
  'adminBroadcastsSaveFailed': 'Failed to save. Please try again.',
  'adminBroadcastsDeleteFailed': 'Failed to delete. Please try again.',
  'adminBroadcastsAdd': 'Add Broadcast',
  'adminBroadcastsEdit': 'Edit Broadcast',
  'adminBroadcastsDeleteTitle': 'Delete broadcast?',
  'adminBroadcastsDeleteBody': 'Delete "{title}"?',
  'adminBroadcastsSearchHint': 'Search by title, message, status, or id',
  'adminBroadcastsEmpty': 'No broadcasts found.',
  'adminBroadcastsStatus': 'Status',
  'adminBroadcastsStatusDraft': 'Draft',
  'adminBroadcastsStatusScheduled': 'Scheduled',
  'adminBroadcastsStatusSending': 'Sending',
  'adminBroadcastsStatusSent': 'Sent',
  'adminBroadcastsStatusFailed': 'Failed',
  'adminBroadcastsTimeFilter': 'Time',
  'adminBroadcastsTimeAll': 'All',
  'adminBroadcastsTimeUpcoming': 'Upcoming',
  'adminBroadcastsTimePast': 'Past',
  'adminBroadcastsType': 'Type',
  'adminBroadcastsTypeInfo': 'Info',
  'adminBroadcastsTypeWarning': 'Warning',
  'adminBroadcastsTypePromotion': 'Promotion',
  'adminBroadcastsTypeUpdate': 'Update',
  'adminBroadcastsTitle': 'Title',
  'adminBroadcastsTitleRequired': 'Title is required',
  'adminBroadcastsMessage': 'Message',
  'adminBroadcastsMessageRequired': 'Message is required',
  'adminBroadcastsActionUrl': 'Action URL',
  'adminBroadcastsActionUrlInvalid': 'Please enter a valid http(s) URL',
  'adminBroadcastsActionUrlText': 'Action button text',
  'adminBroadcastsActionUrlTextDefault': 'Learn more',
  'adminBroadcastsFilterCriteria': 'Filter criteria (JSON)',
  'adminBroadcastsInvalidJson': 'Invalid JSON.',
  'adminBroadcastsTargetingTitle': 'Targeting',
  'adminBroadcastsTargetingEmpty': 'No targeting filters selected.',
  'adminBroadcastsTargetingFiltersTitle': 'Targeting filters',
  'adminBroadcastsAdvancedJsonTitle': 'Advanced (JSON)',
  'adminBroadcastsApplyJson': 'Apply JSON',
  'adminBroadcastsFilterAllUsers': 'All users',
  'adminBroadcastsFilterGender': 'Gender',
  'adminBroadcastsFilterAgeRange': 'Age range',
  'adminBroadcastsFilterSubscriptionTiers': 'Subscription tiers',
  'adminBroadcastsFilterVerificationStatus': 'Verification status',
  'adminBroadcastsFilterPlatform': 'Platform',
  'adminBroadcastsFilterLastActiveDays': 'Last active',
  'adminBroadcastsFilterVisibleOnly': 'Visible only',
  'adminBroadcastsFilterUiLanguage': 'UI language',
  'adminBroadcastsFilterUiLanguages': 'UI languages',
  'adminBroadcastsLastActiveLabel': 'Last active within',
  'adminBroadcastsLastActiveValue': '{days} days',
  'adminBroadcastsLanguageLabel': 'Language',
  'adminBroadcastsViewUsers': 'View users',
  'adminBroadcastsTargetUsersTitle': 'Target users',
  'adminBroadcastsTargetUsersEmpty': 'No users found.',
  'adminBroadcastsTargetUsersLoadFailed': 'Failed to load users.',
  'adminSubscriptionTierFree': 'Free',
  'adminBroadcastsFilterStatus': 'Status',
  'adminBroadcastsStatusAll': 'All',
  'adminBroadcastsStatusVisible': 'Visible',
  'adminBroadcastsStatusInvisible': 'Invisible',
  'adminBroadcastsStatusOffline': 'Offline',
  'adminBroadcastsCountTargets': 'Count target users',
  'adminBroadcastsTargetUnknown': 'Target user count unavailable.',
  'adminBroadcastsTargetCountValue': 'Target users: {count}',
  'adminBroadcastsScheduledAt': 'Scheduled',
  'adminBroadcastsScheduleNone': 'Not scheduled',
  'adminBroadcastsPickDateTime': 'Pick',
  'adminBroadcastsClearDateTime': 'Clear',
  'adminBroadcastsSentAt': 'Sent',
  'adminBroadcastsTargetCount': 'Target',
  'adminBroadcastsActualSent': 'Queued',
  'adminBroadcastsScheduleNow': 'Schedule now',
  'adminBroadcastsResendNow': 'Resend now',
  'adminBroadcastsReschedule': 'Reschedule',
  'adminBroadcastsResent': 'Broadcast resent.',
  'adminBroadcastsResendFailed': 'Failed to resend broadcast',
  'adminBroadcastsRescheduled': 'Broadcast rescheduled.',
  'adminBroadcastsRescheduleFailed': 'Failed to reschedule broadcast',
  'adminBroadcastsRescheduleMustBeFuture': 'Please pick a time in the future.',
  'adminBroadcastsDetails': 'Details',
  'adminBroadcastsConfirmTitle': 'Confirm',
  'adminBroadcastsConfirmSendNowBody': 'Review the message and recipients before sending.',
  'adminBroadcastsConfirmScheduleBody': 'Review the message and recipients before scheduling for {time}.',
  'adminBroadcastsRecipientsButton': 'Recipients',
  'adminBroadcastsRecipientsTitle': 'Select recipients',
  'adminBroadcastsRecipientsChip': 'Recipients: {count}',
  'adminBroadcastsRecipientsSearchLabel': 'Search by name or user ID',
  'adminBroadcastsRecipientsSelectedValue': 'Selected: {count}',
  'adminBroadcastsRecipientsLoadFailed': 'Failed to load users.',
  'adminBroadcastsRecipientsEmpty': 'No users found.',
  'adminBroadcastsSendNow': 'Send now',
  'adminBroadcastsSchedule': 'Schedule',
  'adminBroadcastsDetailsTitle': 'Broadcast details',
  'adminBroadcastsStatsTitle': 'Delivery stats',
  'adminBroadcastsStatsTotal': 'Total',
  'adminBroadcastsStatsSent': 'Sent',
  'adminBroadcastsStatsDelivered': 'Delivered',
  'adminBroadcastsStatsFailed': 'Failed',
  'adminBroadcastsStatsRate': 'Rate',
  'adminBroadcastsMode': 'Mode',
  'adminBroadcastsModePerLanguage': 'Per-language',
  'adminBroadcastsModeSingle': 'Single message',
  'adminBroadcastsPreview': 'Preview',
  'adminBroadcastsLanguage': 'Lang',
  'paywallPeriodDaily': 'Daily',
  'paywallPeriodWeekly': 'Weekly',
  'paywallPeriodMonthly': 'Monthly',
  'paywallPeriodAnnual': 'Annual',
};
