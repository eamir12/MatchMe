// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/theme_provider.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/screens/auth/auth_screen.dart';
import 'package:matchme/screens/auth/profile_check_screen.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/outbox_sync_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:google_fonts/google_fonts.dart';

final container = ProviderContainer();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ensure status bar is visible and matches the app theme on mobile
  // Use edge-to-edge mode but keep status bar visible with a white background and dark icons on Android
  try {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
  } catch (e) {
    debugPrint('Failed to set system UI mode: $e');
  }

  // Hive initialization
  await Hive.initFlutter();
  // Diagnostics: log run identifier so we can detect if the process was restarted
  ResumeDiagnostics.log('main() start - runId=${ResumeDiagnostics.runId}');

  // Attempt to load .env if present (mobile). Web falls back to --dart-define.
  try {
    await dotenv.load(fileName: '.env');
  } catch (e, st) {
    debugPrint('dotenv.load() warning: $e\n$st');
  }

  // Prefer dotenv, then --dart-define
  final supabaseUrl = dotenv.env['SUPABASE_URL']?.trim().isNotEmpty == true
      ? dotenv.env['SUPABASE_URL']!.trim()
      : const String.fromEnvironment('SUPABASE_URL', defaultValue: '').trim();

  final supabaseAnonKey =
      dotenv.env['SUPABASE_ANON_KEY']?.trim().isNotEmpty == true
          ? dotenv.env['SUPABASE_ANON_KEY']!.trim()
          : const String.fromEnvironment(
            'SUPABASE_ANON_KEY',
            defaultValue: '',
          ).trim();

  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    runApp(
      ProviderScope(
        child: MissingSupabaseKeyApp(
          missingUrl: supabaseUrl.isEmpty,
          missingKey: supabaseAnonKey.isEmpty,
        ),
      ),
    );
    return;
  }

  // Initialize Supabase
  try {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
    debugPrint('Supabase.initialize succeeded');
  } catch (e, st) {
    debugPrint('Supabase.initialize failed: $e\n$st');
    runApp(
      ProviderScope(
        child: SupabaseInitErrorApp(error: e.toString()),
      ),
    );
    return;
  }

  // Lightweight health check
  await _performSupabaseHealthCheck();

  // Defensive provider pre-inits
  try {
    // Initialize LocalDbService
    container.read(localDbProvider);
  } catch (e, st) {
    debugPrint('Warning: localDbProvider pre-init failed: $e\n$st');
  }

  try {
    // Initialize OutboxSyncService
    container.read(outboxSyncProvider);
  } catch (e, st) {
    debugPrint('Warning: outboxSyncProvider read failed: $e\n$st');
  }

  try {
    // Initialize BackgroundService with Supabase config
    await BackgroundService.initialize(
      supabaseUrl: supabaseUrl,
      supabaseKey: supabaseAnonKey,
    );

    // Set up token refresh listener
    supabase.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.tokenRefreshed) {
        final session = supabase.auth.currentSession;
        if (session?.accessToken != null) {
          BackgroundService.updateToken(session!.accessToken);
          debugPrint('Updated background service with refreshed JWT token');
        }
      }
    });
  } catch (e, st) {
    debugPrint('Warning: BackgroundService init failed: $e\n$st');
  }

  // Ensure diagnostics are disabled by default for now.
  ResumeDiagnostics.setEnabled(false);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MatchMeApp(),
    ),
  );
}

final supabase = Supabase.instance.client;

/// Simple sanity check that the Supabase client can talk to your backend.
/// Uses a lightweight RPC `health_check()` (SECURITY DEFINER) so anonymous clients
/// do not need direct table access to perform the check.
Future<void> _performSupabaseHealthCheck() async {
  try {
    final dynamic data = await supabase.rpc('health_check').maybeSingle();

    // Handle both JSON responses and legacy boolean responses gracefully
    if (data is Map || data is Map<String, dynamic>) {
      final ok = (data['ok'] == true);
      debugPrint('Supabase health check OK. ok=$ok result=$data');
    } else if (data is bool) {
      // Older DB function returned boolean; accept it for backward compatibility
      debugPrint('Supabase health check OK (legacy bool) result=$data');
    } else {
      debugPrint('Supabase health check unexpected result type: ${data.runtimeType} value=$data');
    }
  } catch (e, st) {
    debugPrint('Supabase health check failed: $e\n$st');
  }
}

/// App shown when Supabase keys are missing
class MissingSupabaseKeyApp extends StatelessWidget {
  final bool missingUrl;
  final bool missingKey;
  const MissingSupabaseKeyApp({
    super.key,
    required this.missingUrl,
    required this.missingKey,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    if (missingUrl) {
      lines.add(LocalizationState.defaultTranslation('supabaseUrlMissing'));
    }
    if (missingKey) {
      lines.add(LocalizationState.defaultTranslation('supabaseAnonKeyMissing'));
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text(LocalizationState.defaultTranslation('configRequired'))),
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                LocalizationState.defaultTranslation('supabaseConfigMissing'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...lines.map((l) => Text(l)),
            ],
          ),
        ),
      ),
    );
  }
}

/// App shown when Supabase initialization fails
class SupabaseInitErrorApp extends StatelessWidget {
  final String error;
  const SupabaseInitErrorApp({super.key, required this.error});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text(LocalizationState.defaultTranslation('supabaseInitFailed'))),
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: SingleChildScrollView(child: Text('${LocalizationState.defaultTranslation('supabaseInitFailed')}: $error')),
        ),
      ),
    );
  }
}

/// Smooth scroll behavior (mouse wheel smoothing)
class _SmoothScrollBehavior extends ScrollBehavior {
  const _SmoothScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics().applyTo(
      const BouncingScrollPhysics(),
    );
  }
}

class MatchMeApp extends ConsumerStatefulWidget {
  const MatchMeApp({super.key});

  @override
  ConsumerState<MatchMeApp> createState() => _MatchMeAppState();
}

class _MatchMeAppState extends ConsumerState<MatchMeApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Re-apply system UI overlay styles at runtime to handle OEM quirks (e.g., Moto Android 15)
    void applyOverlays() {
      try {
        // Force both top and bottom system overlays visible (manual) and apply style
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom]);
        SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ));
        debugPrint('System UI overlays applied (manual) in MatchMeApp.initState');
      } catch (e) {
        debugPrint('Failed to set System UI overlays at runtime: $e');
      }
    }

    // Apply immediately and retry after short delays to handle OEM resets
    applyOverlays();

    // Avoid scheduling delayed retries during widget tests (which treat pending timers as failures)
    // Use a runtime-safe check on the binding's runtimeType name to avoid referencing test-only types
    final bindingTypeName = WidgetsBinding.instance.runtimeType.toString();
    if (!bindingTypeName.contains('TestWidgets')) {
      Future.delayed(const Duration(milliseconds: 250), applyOverlays);
      Future.delayed(const Duration(milliseconds: 1000), applyOverlays);
      Future.delayed(const Duration(milliseconds: 3000), applyOverlays);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    ResumeDiagnostics.log('AppLifecycleState changed: $state');

    // When app resumes, ensure locale is properly maintained
    if (state == AppLifecycleState.resumed) {
      // Force a rebuild to ensure locale and text direction are maintained
      if (mounted) {
        setState(() {});
      }
    }
  }

  static TextTheme _normalizeTextTheme(
    TextTheme src,
    List<String> fallbackFonts,
  ) {
    TextStyle? normalizeStyle(TextStyle? s) {
      if (s == null) return null;
      return s.copyWith(
        inherit: true,
        fontFamilyFallback: <String>[
          ...?s.fontFamilyFallback,
          ...fallbackFonts,
        ],
      );
    }

    return TextTheme(
      displayLarge: normalizeStyle(src.displayLarge),
      displayMedium: normalizeStyle(src.displayMedium),
      displaySmall: normalizeStyle(src.displaySmall),
      headlineLarge: normalizeStyle(src.headlineLarge),
      headlineMedium: normalizeStyle(src.headlineMedium),
      headlineSmall: normalizeStyle(src.headlineSmall),
      titleLarge: normalizeStyle(src.titleLarge),
      titleMedium: normalizeStyle(src.titleMedium),
      titleSmall: normalizeStyle(src.titleSmall),
      bodyLarge: normalizeStyle(src.bodyLarge),
      bodyMedium: normalizeStyle(src.bodyMedium),
      bodySmall: normalizeStyle(src.bodySmall),
      labelLarge: normalizeStyle(src.labelLarge),
      labelMedium: normalizeStyle(src.labelMedium),
      labelSmall: normalizeStyle(src.labelSmall),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localization = ref.watch(localizationProvider);
    final authState = ref.watch(authStateProvider);

    if (localization.isLoading && localization.supportedLanguages.isEmpty) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final String lang = localization.currentLocale.languageCode.toLowerCase();
    final TextTheme baseTextTheme = ThemeData.light().textTheme;

    TextTheme selectedTextTheme;
    if (lang == 'he') {
      selectedTextTheme = GoogleFonts.notoSansHebrewTextTheme(baseTextTheme);
    } else if (lang == 'ar') {
      selectedTextTheme = GoogleFonts.notoSansArabicTextTheme(baseTextTheme);
    } else {
      selectedTextTheme = GoogleFonts.notoSansTextTheme(baseTextTheme);
    }

    final List<String> emojiFallbacks = [
      'Noto Color Emoji',
      'Segoe UI Emoji',
      'Apple Color Emoji',
      'Noto Sans Hebrew',
      'Noto Sans Arabic',
      'Noto Sans TC',
    ];

    final TextTheme finalTextTheme =
        _normalizeTextTheme(selectedTextTheme, emojiFallbacks);

    // Theme mode controlled by provider
    final themeMode = ref.watch(themeModeProvider);

    // Dark theme
    final colorSchemeDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFFEC4899),
      surface: const Color(0xFF0F172A),
      onSurface: const Color(0xFFE6EEF8),
    );

    final darkTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorSchemeDark,
      appBarTheme: AppBarTheme(
        backgroundColor: colorSchemeDark.surface,
        foregroundColor: colorSchemeDark.onSurface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.notoSans(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorSchemeDark.onSurface,
        ),
      ),
      textTheme: finalTextTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      // Semantic success colors for status indicators (dark)
      extensions: const <ThemeExtension<dynamic>>[
        // success = green-400, successContainer = green-900 translucent
        // Chosen to be visible on dark backgrounds
        SemanticColors(success: Color(0xFF34D399), successContainer: Color(0xFF052E16)),
      ],
    );

    // Light theme color scheme declared here so we can reference 'surface' consistently
    final colorSchemeLight = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1), // Modern indigo
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFFEC4899), // Pink accent
      tertiary: const Color(0xFFF59E0B), // Amber
      surface: const Color(0xFFF8FAFC), // Light gray background
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: const Color(0xFF1E293B), // Dark slate
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: localization.getString('appName'),
      locale: localization.currentLocale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: localization.supportedLanguages
          .map((lang) => Locale(lang.code))
          .toList(),
      localeResolutionCallback: (locale, supportedLocales) {
        // Always return the current app locale to prevent system locale override
        return localization.currentLocale;
      },
      // Light theme defined inline below
      darkTheme: darkTheme,
      themeMode: themeMode,
      builder: (context, child) {
        // Keep system UI overlays in sync with the current theme (updates on rebuild)
        try {
          final currentTheme = Theme.of(context);
          final bool isDark = currentTheme.brightness == Brightness.dark;
          final Color statusBarColor = currentTheme.appBarTheme.backgroundColor ?? currentTheme.colorScheme.surface;
          final Color navBarColor = currentTheme.scaffoldBackgroundColor;
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: statusBarColor,
            statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: navBarColor,
            systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          ));
        } catch (e) {
          debugPrint('Failed to update system UI overlays dynamically: $e');
        }
        // ✅ Mouse wheel smoothing applied app-wide
        // Always wrap the app content in a SafeArea so all screens respect Android status/navigation bars
        // Additionally add a visual fallback overlay for Android devices that ignore status/nav bar color
        return ScrollConfiguration(
          behavior: const _SmoothScrollBehavior(),
          child: Builder(builder: (context) {
            final bool isAndroid = defaultTargetPlatform == TargetPlatform.android;
            final double topPadding = MediaQuery.of(context).padding.top;
            final double bottomPadding = MediaQuery.of(context).padding.bottom;
            final Color barColor = Theme.of(context).scaffoldBackgroundColor;

            return Stack(
              children: [
                SafeArea(child: child!),
                if (isAndroid && topPadding > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Container(
                      height: topPadding,
                      color: barColor,
                    ),
                  ),
                if (isAndroid && bottomPadding > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: bottomPadding,
                      color: barColor,
                    ),
                  ),
              ],
            );
          }),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Modern indigo
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFFEC4899), // Pink accent
          tertiary: const Color(0xFFF59E0B), // Amber
          surface: const Color(0xFFF8FAFC), // Light gray background
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: const Color(0xFF1E293B), // Dark slate
        ),
        // Semantic success colors for status indicators (light)
        extensions: const <ThemeExtension<dynamic>>[
          // success = green-500, successContainer = light green background
          SemanticColors(success: Color(0xFF10B981), successContainer: Color(0xFFDCFCE7)),
        ],

        appBarTheme: AppBarTheme(
          backgroundColor: colorSchemeLight.surface,
          foregroundColor: colorSchemeLight.onSurface,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: GoogleFonts.notoSans(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: colorSchemeLight.onSurface,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: colorSchemeLight.primary,
            foregroundColor: colorSchemeLight.onPrimary,
            elevation: 0,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: colorSchemeLight.primary,
            foregroundColor: colorSchemeLight.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: colorSchemeLight.primary,
            side: BorderSide(color: colorSchemeLight.primary, width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: colorSchemeLight.surface,
          selectedItemColor: colorSchemeLight.primary,
          unselectedItemColor: colorSchemeLight.onSurface.withValues(alpha:0.6),
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          elevation: 8,
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha:0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: colorSchemeLight.surface,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: colorSchemeLight.surfaceContainerHighest,
          selectedColor: colorSchemeLight.primary.withValues(alpha:0.1),
          checkmarkColor: colorSchemeLight.primary,
          labelStyle: TextStyle(color: colorSchemeLight.onSurface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorSchemeLight.surfaceContainerHighest),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorSchemeLight.primary, width: 2),
          ),
          labelStyle: TextStyle(color: colorSchemeLight.onSurface.withValues(alpha:0.7)),
          filled: true,
          fillColor: colorSchemeLight.surface,
        ),
        textTheme: finalTextTheme.copyWith(
          headlineLarge: finalTextTheme.headlineLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          headlineMedium: finalTextTheme.headlineMedium?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
          ),
          titleLarge: finalTextTheme.titleLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: finalTextTheme.bodyLarge?.copyWith(
            inherit: true,
            fontWeight: FontWeight.w400,
            height: 1.5,
          ),
        ),
        dividerTheme: DividerThemeData(
          color: colorSchemeLight.surfaceContainerHighest,
          thickness: 1,
        ),
      ),
      home: Directionality(
        textDirection: localization.textDirection,
        child: authState.when(
          data: (state) {
            final user = state.session?.user;
            if (user == null) {
              return const AuthScreen();
            } else {
              return ProfileCheckScreen(user: user);
            }
          },
          loading: () => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (err, stack) {
            debugPrint('Error in authStateProvider stream: $err');
            return Scaffold(
              body: Center(child: Text('${LocalizationState.defaultTranslation('authStreamError')}: $err')),
            );
          },
        ),
      ),
    );
  }
}
