import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/widgets/pinned_location_sheet.dart';

import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/offline_trail_service.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/utils/matching_background_status.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui' as ui;
import 'package:matchme/widgets/safe_text.dart';

class MatchingSettingsScreen extends ConsumerStatefulWidget {
  const MatchingSettingsScreen({super.key});

  @override
  ConsumerState<MatchingSettingsScreen> createState() =>
      _MatchingSettingsScreenState();
}

class _MatchingSettingsScreenState extends ConsumerState<MatchingSettingsScreen>
    with WidgetsBindingObserver {
  late String _currentUserId;
  final AppConfigService appConfigService = AppConfigService();
  Future<bool>? _backgroundPermissionFuture;

  void _refreshBackgroundPermissionStatus() {
    if (!kIsWeb && Platform.isAndroid) {
      _backgroundPermissionFuture =
          PermissionCoordinator.hasBackgroundLocationPermission();
    } else {
      _backgroundPermissionFuture = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;
    _refreshBackgroundPermissionStatus();

    if (!kIsWeb && Platform.isAndroid) {
      Future.microtask(() async {
        try {
          await ref
              .read(userPreferencesProvider.notifier)
              .syncBackgroundMatchingPermissionState();
        } catch (e) {
          print('Failed to validate Background Matching Mode permission: $e');
        }
      });
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
    if (state == AppLifecycleState.resumed && !kIsWeb && Platform.isAndroid) {
      _refreshBackgroundPermissionStatus();
      Future.microtask(() async {
        try {
          await ref
              .read(userPreferencesProvider.notifier)
              .syncBackgroundMatchingPermissionState();
        } catch (e) {
          print('Failed to validate Background Matching Mode permission: $e');
        }
      });
    }
  }

  Widget _buildBackgroundStatus(
    BuildContext context,
    LocalizationState l10n,
    UserPreferencesState prefs,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final permissionFuture = isAndroid ? _backgroundPermissionFuture : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: FutureBuilder<bool>(
        future: permissionFuture,
        builder: (context, snapshot) {
          final status = resolveMatchingBackgroundStatus(
            isWeb: kIsWeb,
            isAndroid: isAndroid,
            preferenceEnabled: prefs.backgroundMatchingMode,
            permissionCheckComplete:
                !isAndroid || snapshot.connectionState == ConnectionState.done,
            permissionGranted: snapshot.data,
          );
          final needsPermission =
              status == MatchingBackgroundStatus.permissionNeeded;
          final isOn = status == MatchingBackgroundStatus.on;

          final title = switch (status) {
            MatchingBackgroundStatus.webUnavailable => l10n.getString(
              'settingsBackgroundStatusWebTitle',
            ),
            MatchingBackgroundStatus.off => l10n.getString(
              'settingsBackgroundStatusOffTitle',
            ),
            MatchingBackgroundStatus.permissionNeeded => l10n.getString(
              'settingsBackgroundStatusPermissionTitle',
            ),
            MatchingBackgroundStatus.checking => l10n.getString(
              'settingsBackgroundStatusCheckingTitle',
            ),
            MatchingBackgroundStatus.on => l10n.getString(
              'settingsBackgroundStatusOnTitle',
            ),
          };
          final description = switch (status) {
            MatchingBackgroundStatus.webUnavailable => l10n.getString(
              'settingsBackgroundStatusWebDescription',
            ),
            MatchingBackgroundStatus.off => l10n.getString(
              'settingsBackgroundStatusOffDescription',
            ),
            MatchingBackgroundStatus.permissionNeeded => l10n.getString(
              'settingsBackgroundStatusPermissionDescription',
            ),
            MatchingBackgroundStatus.checking => l10n.getString(
              'settingsBackgroundStatusCheckingDescription',
            ),
            MatchingBackgroundStatus.on => l10n.getString(
              'settingsBackgroundStatusOnDescription',
            ),
          };
          final icon = switch (status) {
            MatchingBackgroundStatus.webUnavailable => Icons.language,
            MatchingBackgroundStatus.off => Icons.pause_circle_outline,
            MatchingBackgroundStatus.permissionNeeded =>
              Icons.location_off_outlined,
            MatchingBackgroundStatus.checking => Icons.sync,
            MatchingBackgroundStatus.on => Icons.radar,
          };
          final color = isOn
              ? colors.primary
              : needsPermission
              ? colors.error
              : colors.onSurfaceVariant;

          return Semantics(
            container: true,
            label: '$title. $description',
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.35,
                              ),
                        ),
                        if (needsPermission && !kIsWeb) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton.icon(
                              onPressed: () => unawaited(openAppSettings()),
                              icon: const Icon(
                                Icons.settings_outlined,
                                size: 18,
                              ),
                              label: Text(
                                l10n.getString('permActionOpenSettings'),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final profileEditState = ref.watch(profileEditProvider(_currentUserId));
    final prefs = ref.watch(userPreferencesProvider);
    final useImperialAsync = ref.watch(unitSystemProvider);

    final effectiveUseImperial = useImperialAsync.maybeWhen(
      data: (v) => v,
      orElse: () {
        final unitPref = prefs.unitSystem;
        if (unitPref == UnitSystemPreference.imperial) return true;
        if (unitPref == UnitSystemPreference.metric) return false;
        final deviceCountry =
            ui.PlatformDispatcher.instance.locale.countryCode ?? '';
        if (deviceCountry.isNotEmpty) {
          return usesImperialUnitsByCountry(deviceCountry);
        }
        return false;
      },
    );

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('settingsMatching'))),
      body: profileEditState.when(
        data: (profile) {
          if (profile == null) {
            return Center(
              child: Text(l10n.getString('generalErrorLoadingProfile')),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              _buildBackgroundStatus(context, l10n, prefs),
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: theme.shadowColor.withValues(alpha: 0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<List<int>>(
                      future: appConfigService.getIntList(
                        'profile.match_radius_options_meters',
                        defaultValue: [5, 10, 20, 50, 100],
                      ),
                      builder: (context, snapshot) {
                        final allowedRadii =
                            snapshot.data ?? [5, 10, 20, 50, 100];
                        final currentRadius = profile.matchRadiusDefault;
                        final radii = Set<int>.from(allowedRadii)
                          ..add(currentRadius);
                        final sortedRadii = radii.toList()..sort();
                        return DropdownButtonFormField<int>(
                          key: ValueKey(currentRadius),
                          initialValue: currentRadius,
                          decoration: InputDecoration(
                            labelText: l10n.getString('settingsRadius'),
                            prefixIcon: Icon(
                              Icons.radar_outlined,
                              color: colors.secondary,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colors.secondary,
                                width: 2,
                              ),
                            ),
                            filled: true,
                            fillColor: colors.surface,
                          ),
                          items: sortedRadii
                              .map(
                                (radius) => DropdownMenuItem(
                                  value: radius,
                                  child: Text(
                                    formatDistanceWithImperial(
                                      radius.toDouble(),
                                      effectiveUseImperial,
                                      l10n,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) async {
                            if (value != null && allowedRadii.contains(value)) {
                              try {
                                await ref
                                    .read(
                                      profileEditProvider(
                                        _currentUserId,
                                      ).notifier,
                                    )
                                    .updateRadius(value);
                              } catch (e) {
                                debugPrint(
                                  '[Settings] updateRadius failed: $e',
                                );
                                if (!mounted) return;
                                final errorKey =
                                    ErrorLocalizationService.getErrorTranslationKey(
                                      e,
                                    );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n.getString('settingsRadiusUpdateFailed')}: ${l10n.getString(errorKey)}',
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    FutureBuilder<List<int>>(
                      future: appConfigService.getIntList(
                        'gps.interval_options_seconds',
                        defaultValue: [5, 10, 20, 30, 60],
                      ),
                      builder: (context, snapshot) {
                        final allowedRates =
                            snapshot.data ?? [5, 10, 20, 30, 60];
                        final currentRate = profile.gpsIntervalDefault;
                        final rates = Set<int>.from(allowedRates)
                          ..add(currentRate);
                        final sortedRates = rates.toList()..sort();
                        return DropdownButtonFormField<int>(
                          key: ValueKey(currentRate),
                          initialValue: currentRate,
                          decoration: InputDecoration(
                            labelText: l10n.getString('settingsGpsRate'),
                            prefixIcon: Icon(
                              Icons.timer_outlined,
                              color: colors.tertiary,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: theme.dividerColor),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colors.tertiary,
                                width: 2,
                              ),
                            ),
                            filled: true,
                            fillColor: colors.surface,
                          ),
                          items: sortedRates
                              .map(
                                (rate) => DropdownMenuItem(
                                  value: rate,
                                  child: Text(
                                    '${rate.toString()} ${l10n.getString('settingsGpsRateUnit')}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) async {
                            if (value != null && allowedRates.contains(value)) {
                              try {
                                await ref
                                    .read(
                                      profileEditProvider(
                                        _currentUserId,
                                      ).notifier,
                                    )
                                    .updateGpsRate(value);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.getString('settingsGpsRateUpdated'),
                                    ),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                final errorKey =
                                    ErrorLocalizationService.getErrorTranslationKey(
                                      e,
                                    );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n.getString('settingsGpsRateUpdateFailed')}: ${l10n.getString(errorKey)}',
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsHighAccuracyMode'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: prefs.backgroundMatchingMode,
                          onChanged: (value) async {
                            if (!value) {
                              // Turning OFF — show confirmation warning first.
                              if (!context.mounted) return;
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(
                                    l10n.getString('settingsHighAccuracyMode'),
                                  ),
                                  content: Text(
                                    l10n.getString(
                                      'background_matching_off_warning',
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: Text(l10n.getString('cancel')),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      child: Text(
                                        l10n.getString(
                                          'settingsBackgroundMatchingTurnOff',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                            }
                            if (value && !kIsWeb && Platform.isAndroid) {
                              if (!context.mounted) return;
                              final hasBackgroundLocation =
                                  await PermissionCoordinator.hasBackgroundLocationPermission();
                              if (!hasBackgroundLocation && context.mounted) {
                                final granted =
                                    await PermissionCoordinator.requestBackgroundLocationPermission(
                                      context,
                                      ref,
                                    );
                                if (!granted) return;
                              }
                            }
                            if (context.mounted) {
                              await ref
                                  .read(userPreferencesProvider.notifier)
                                  .setBackgroundMatchingMode(value);
                            }
                          },
                          activeThumbColor: Theme.of(
                            context,
                          ).colorScheme.tertiary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.tertiary.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0, right: 8.0),
                      child: Text(
                        kIsWeb
                            ? l10n.getString('settingsHighAccuracyModeDesc_web')
                            : (defaultTargetPlatform == TargetPlatform.android
                                  ? l10n.getString(
                                      'settingsHighAccuracyModeDesc_android',
                                    )
                                  : (defaultTargetPlatform == TargetPlatform.iOS
                                        ? l10n.getString(
                                            'settingsHighAccuracyModeDesc_ios',
                                          )
                                        : l10n.getString(
                                            'settingsHighAccuracyModeDesc',
                                          ))),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurface.withAlpha(
                            (0.6 * 255).round(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsSmartGpsThrottling'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: profile.smartGpsThrottlingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref
                                  .read(
                                    profileEditProvider(
                                      _currentUserId,
                                    ).notifier,
                                  )
                                  .updateSmartGpsThrottling(value);
                              await ref
                                  .read(isVisibleProvider.notifier)
                                  .updateLocationStreamInterval();
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString(
                                      'settingsSmartGpsThrottlingUpdated',
                                    ),
                                  ),
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              final errorKey =
                                  ErrorLocalizationService.getErrorTranslationKey(
                                    e,
                                  );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${l10n.getString('settingsSmartGpsThrottlingUpdateFailed')}: ${l10n.getString(errorKey)}',
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(
                            context,
                          ).colorScheme.tertiary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.tertiary.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0, right: 8.0),
                      child: Text(
                        l10n.getString('settingsSmartGpsThrottlingDesc'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurface.withAlpha(
                            (0.6 * 255).round(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.getString('settingsSharedEventMatching'),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: colors.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.getString(
                                  'settingsSharedEventMatchingSubtitle',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurface.withAlpha(
                                    (0.6 * 255).round(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: profile.sharedEventMatchingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref
                                  .read(
                                    profileEditProvider(
                                      _currentUserId,
                                    ).notifier,
                                  )
                                  .updateSharedEventMatching(value);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString(
                                      'settingsSharedEventMatchingUpdated',
                                    ),
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              final errorKey =
                                  ErrorLocalizationService.getErrorTranslationKey(
                                    e,
                                  );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${l10n.getString('settingsSharedEventMatchingUpdateFailed')}: ${l10n.getString(errorKey)}',
                                  ),
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(
                            context,
                          ).colorScheme.secondary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.getString(
                                  'settingsSharedMovementMatching',
                                ),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: colors.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.getString(
                                  'settingsSharedMovementMatchingSubtitle',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurface.withAlpha(
                                    (0.6 * 255).round(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: profile.sharedMovementMatchingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref
                                  .read(
                                    profileEditProvider(
                                      _currentUserId,
                                    ).notifier,
                                  )
                                  .updateSharedMovementMatching(value);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString(
                                      'settingsSharedMovementMatchingUpdated',
                                    ),
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              final errorKey =
                                  ErrorLocalizationService.getErrorTranslationKey(
                                    e,
                                  );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${l10n.getString('settingsSharedMovementMatchingUpdateFailed')}: ${l10n.getString(errorKey)}',
                                  ),
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(
                            context,
                          ).colorScheme.secondary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    // Retroactive matching: find people met without internet.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.getString('settingsRetroMatching'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        Switch(
                          value: profile.retroMatchingEnabled,
                          onChanged: (value) async {
                            try {
                              await ref
                                  .read(
                                    profileEditProvider(
                                      _currentUserId,
                                    ).notifier,
                                  )
                                  .updateRetroMatching(value);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString(
                                      'settingsRetroMatchingUpdated',
                                    ),
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              final errorKey =
                                  ErrorLocalizationService.getErrorTranslationKey(
                                    e,
                                  );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${l10n.getString('settingsRetroMatchingUpdateFailed')}: ${l10n.getString(errorKey)}',
                                  ),
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                              );
                            }
                          },
                          activeThumbColor: Theme.of(
                            context,
                          ).colorScheme.secondary,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.secondary.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 4.0, right: 8.0),
                      child: Text(
                        l10n.getString('settingsRetroMatchingDesc'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurface.withAlpha(
                            (0.6 * 255).round(),
                          ),
                        ),
                      ),
                    ),
                    if (profile.retroMatchingEnabled) ...[
                      const SizedBox(height: 16),
                      FutureBuilder<List<int>>(
                        future: appConfigService.getIntList(
                          'retro.retention_options_hours',
                          defaultValue: const [2, 6, 12, 24, 72],
                        ),
                        builder: (context, snapshot) {
                          final allowed =
                              (snapshot.data ?? const [2, 6, 12, 24, 72])
                                  .toSet()
                                  .toList()
                                ..sort();
                          final current =
                              allowed.contains(profile.retroRetentionHours)
                              ? profile.retroRetentionHours
                              : 24;
                          String label(int h) {
                            if (h < 24) {
                              return l10n.getPluralString(
                                'settingsRetroHours',
                                h,
                              );
                            }
                            if (h == 24) {
                              return l10n.getPluralString(
                                'settingsRetroDays',
                                1,
                              );
                            }
                            return l10n.getPluralString(
                              'settingsRetroDays',
                              h ~/ 24,
                            );
                          }

                          return DropdownButtonFormField<int>(
                            key: ValueKey(current),
                            initialValue: current,
                            decoration: InputDecoration(
                              labelText: l10n.getString(
                                'settingsRetroRetention',
                              ),
                              prefixIcon: Icon(
                                Icons.history_outlined,
                                color: colors.secondary,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: theme.dividerColor,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: theme.dividerColor,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: colors.secondary,
                                  width: 2,
                                ),
                              ),
                              filled: true,
                              fillColor: colors.surface,
                            ),
                            items: allowed
                                .map(
                                  (h) => DropdownMenuItem(
                                    value: h,
                                    child: Text(label(h)),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) async {
                              if (value == null || !allowed.contains(value)) {
                                return;
                              }
                              try {
                                await ref
                                    .read(
                                      profileEditProvider(
                                        _currentUserId,
                                      ).notifier,
                                    )
                                    .updateRetroRetention(value);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.getString(
                                        'settingsRetroRetentionUpdated',
                                      ),
                                    ),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                final errorKey =
                                    ErrorLocalizationService.getErrorTranslationKey(
                                      e,
                                    );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n.getString('settingsRetroMatchingUpdateFailed')}: ${l10n.getString(errorKey)}',
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(left: 4.0, right: 8.0),
                        child: Text(
                          '${l10n.getString('settingsRetroRetentionDesc')}\n\n${l10n.getString('settingsRetroRetentionExample')}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurface.withAlpha(
                              (0.6 * 255).round(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _RetroPendingCounter(userId: _currentUserId),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const _PinnedLocationCard(),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${l10n.getString('generalError')}: ${l10n.getString(ErrorLocalizationService.getErrorTranslationKey(e))}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => ref
                      .read(profileEditProvider(_currentUserId).notifier)
                      .loadInitialProfile(),
                  child: Text(l10n.getString('generalRetry')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live counter of locally kept offline places + delete action.
/// Polls every 5s so it ticks up while places accumulate offline,
/// and drops immediately after upload ack or "delete now".
class _RetroPendingCounter extends ConsumerStatefulWidget {
  final String userId;
  const _RetroPendingCounter({required this.userId});

  @override
  ConsumerState<_RetroPendingCounter> createState() =>
      _RetroPendingCounterState();
}

class _RetroPendingCounterState extends ConsumerState<_RetroPendingCounter> {
  static const _pollInterval = Duration(seconds: 5);
  Timer? _timer;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final n = await OfflineTrailService.instance.pendingCount(widget.userId);
      if (!mounted) return;
      if (n != _count) setState(() => _count = n);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4.0, right: 8.0),
          child: Text(
            l10n.getString(
              'settingsRetroPending',
              params: {'count': '$_count'},
            ),
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurface.withAlpha((0.6 * 255).round()),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l10n.getString('settingsRetroDeleteNow')),
                  content: Text(
                    l10n.getString('settingsRetroDeleteNowConfirm'),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(l10n.getString('generalCancel')),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(l10n.getString('generalDelete')),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              try {
                await OfflineTrailService.instance.deleteEverywhere();
                if (!mounted) return;
                await _refresh();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.getString('settingsRetroDeleteNowDone')),
                    backgroundColor: Colors.green,
                  ),
                );
              } catch (e) {
                if (!context.mounted) return;
                final errorKey =
                    ErrorLocalizationService.getErrorTranslationKey(e);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.getString(errorKey)),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            icon: const Icon(Icons.delete_outline),
            label: Text(l10n.getString('settingsRetroDeleteNow')),
          ),
        ),
      ],
    );
  }
}

/// Home-base pinned location card: pin the matching spot for a chosen
/// duration while traveling. GPS pauses; matches use the pin.
class _PinnedLocationCard extends ConsumerWidget {
  const _PinnedLocationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final pin = ref.watch(pinnedLocationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final now = DateTime.now().toUtc();
    final remaining = pin.remainingFrom(now);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.push_pin_outlined, color: colors.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('pinnedLocationSectionTitle'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
              if (pin.isActive && remaining != null && !remaining.isNegative)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    pinnedRemainingText(remaining, l10n),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.green,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('pinnedLocationSectionDesc'),
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurface.withAlpha((0.6 * 255).round()),
            ),
          ),
          const SizedBox(height: 12),
          if (!pin.initialized)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            )
          else if (!pin.isActive)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: pin.isLoading
                    ? null
                    : () => showPinnedLocationSheet(context, ref),
                icon: const Icon(Icons.push_pin_outlined),
                label: Text(l10n.getString('pinnedLocationPinAction')),
              ),
            )
          else ...[
            Text(
              l10n.getString(
                'pinnedLocationActiveUntil',
                params: {
                  'label': (pin.label == null || pin.label!.isEmpty)
                      ? ''
                      : ' "${pin.label}"',
                  'date': pin.expiresAt == null
                      ? ''
                      : pinnedFormatExpiry(pin.expiresAt!),
                },
              ),
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
            const SizedBox(height: 12),
            if (pin.isLoading) const LinearProgressIndicator(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: pin.isLoading
                        ? null
                        : () => showPinnedLocationSheet(
                            context,
                            ref,
                            extensionOnly: true,
                          ),
                    child: Text(l10n.getString('pinnedLocationExtend')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: pin.isLoading
                        ? null
                        : () async {
                            try {
                              await ref
                                  .read(pinnedLocationProvider.notifier)
                                  .unpin();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString('pinnedLocationUnpinned'),
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.getString(
                                      ErrorLocalizationService.getErrorTranslationKey(
                                        e,
                                      ),
                                    ),
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                    child: Text(l10n.getString('pinnedLocationUnpin')),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
