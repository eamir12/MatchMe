// lib/screens/settings/invisibility_rules_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/models/invisibility_rules.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/web_location_service.dart';
import '../../providers/current_location_provider.dart';
import '../../providers/unit_provider.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';

class InvisibilityRulesScreen extends ConsumerStatefulWidget {
  final String? highlightRuleId;
  
  const InvisibilityRulesScreen({super.key, this.highlightRuleId});

  @override
  ConsumerState<InvisibilityRulesScreen> createState() => _InvisibilityRulesScreenState();
}

class _InvisibilityRulesScreenState extends ConsumerState<InvisibilityRulesScreen> {
  final Map<String, GlobalKey> _ruleKeys = {};
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Rules are automatically loaded by the provider
    
    // Scroll to highlighted rule after build
    if (widget.highlightRuleId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToHighlightedRule();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // Helper method to get device's system locale for date/time formatting
  String _getSystemLocale(BuildContext context) {
    // Get the device's locale from the platform, not the app's UI locale
    final platformLocale = View.of(context).platformDispatcher.locale;
    return '${platformLocale.languageCode}_${platformLocale.countryCode ?? platformLocale.languageCode.toUpperCase()}';
  }

  String _formatTime(BuildContext context, TimeOfDay time) {
    final l10n = ref.watch(localizationProvider);
    return formatTimeOfDayWithPrefs(context, ref, l10n, time);
  }

  void _scrollToHighlightedRule() {
    if (widget.highlightRuleId == null) return;
    
    final key = _ruleKeys[widget.highlightRuleId!];
    if (key != null && key.currentContext != null) {
      Scrollable.ensureVisible(
        key.currentContext!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        alignment: 0.2, // Position rule near top of visible area
      );
    }
  }

  Widget _buildInvisibilityRuleType(
    BuildContext context,
    LocalizationState l10n,
    IconData icon,
    String title,
    String description,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha:0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha:0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: color.withValues(alpha:0.7),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: color, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildExistingRule(
    BuildContext context,
    LocalizationState l10n,
    String title,
    IconData icon,
    Color color,
    VoidCallback onDelete, {
    bool canEdit = false,
    VoidCallback? onEdit,
    bool isPast = false,
    required bool enabled,
    ValueChanged<bool>? onToggle,
    required String ruleId,
    required String type,
    bool isActive = false,
  }) {
    final isHighlighted = widget.highlightRuleId == ruleId;
    
    // Create or retrieve key for this rule
    if (!_ruleKeys.containsKey(ruleId)) {
      _ruleKeys[ruleId] = GlobalKey();
    }

    return Container(
      key: isHighlighted ? _ruleKeys[ruleId] : null,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isHighlighted
            ? color.withValues(alpha:0.15)
            : (isPast
                ? Theme.of(context).colorScheme.onSurface.withValues(alpha:0.05)
                : color.withValues(alpha:0.05)),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isHighlighted
              ? color
              : (isPast
                  ? Theme.of(context).colorScheme.onSurface.withValues(alpha:0.1)
                  : color.withValues(alpha:0.1)),
          width: isHighlighted ? 2 : 1,
        ),
        boxShadow: isHighlighted ? [
          BoxShadow(
            color: color.withValues(alpha:0.3),
            blurRadius: 8,
            spreadRadius: 0,
          ),
        ] : null,
      ),
      child: ListTile(
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, color: isPast ? Theme.of(context).disabledColor : color, size: 20),
            if (isActive && !isPast)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isPast ? Theme.of(context).disabledColor : Theme.of(context).colorScheme.onSurface,
            decoration: isPast ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: isPast
            ? Text(
                l10n.getString('settingsRuleExpired'),
                style: TextStyle(fontSize: 11, color: Theme.of(context).disabledColor),
              )
            : null,
        trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onToggle != null)
                    Switch(
                      value: enabled,
                      onChanged: onToggle,
                      activeThumbColor: color,
                    ),
                  if (canEdit && onEdit != null)
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      color: color,
                      onPressed: onEdit,
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 18),
                    color: Theme.of(context).colorScheme.error,
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(l10n.getString('confirmDelete')),
                          content: Text(l10n.getString('confirmDeleteInvisibilityRule')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(l10n.getString('generalCancel')),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                              child: Text(l10n.getString('generalDelete')),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        onDelete();
                      }
                    },
                  ),
                ],
              ),
      ),
    );
  }

  void _showLocationRulesDialog(BuildContext context, LocalizationState l10n) {
    final nameController = TextEditingController();
    final nameFocusNode = FocusNode();

    String locationName = '';
    double? latitude;
    double? longitude;
    double radiusMeters = kIsWeb ? 50.0 : 20.0; // Default based on platform
    bool isDialogOpen = true;
    bool isFetchingLocation = false;
    bool hasAutoFetched = false;

    Future<void> saveLocationRule() async {
      locationName = nameController.text.trim();
      final rule = LocationRule(
        id: const Uuid().v4(),
        name: locationName,
        latitude: latitude!,
        longitude: longitude!,
        radiusMeters: radiusMeters,
      );
      await ref.read(invisibilityRulesProvider.notifier).addLocationRule(rule);
      // Refresh current location to ensure invisibility rules are properly checked
      ref.read(currentLocationProvider.notifier).refreshLocation();
      isDialogOpen = false;
      Navigator.pop(context); // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
        SnackBar(content: Text(l10n.getString('settingsLocationRuleAdded'))),
      );
    }

    Future<void> fetchCurrentLocation(StateSetter setState) async {
      setState(() => isFetchingLocation = true);

      final locationService = ref.read(locationServiceProvider);

      // 1) Use the app's currentLocationProvider immediately if available (fast path)
      try {
        final current = ref.read(currentLocationProvider);
        if (current != null && isDialogOpen) {
          latitude ??= current.latitude;
          longitude ??= current.longitude;
        }
      } catch (_) {}

      // 2) Web: use high precision sampling
      if (locationService is WebLocationService) {
        final position = await locationService.getHighPrecisionPosition(
          sampleCount: 5,
          sampleInterval: const Duration(seconds: 2),
          maxAccuracyMeters: 50.0,
        );

        if (position != null && isDialogOpen && mounted) {
          setState(() {
            latitude = position.latitude;
            longitude = position.longitude;
            isFetchingLocation = false;
          });

          final accuracyText = position.accuracy.toStringAsFixed(0);
          final message = position.accuracy > 50
              ? '${l10n.getString('settingsLocationSuccess')} ($accuracyText${l10n.getString('settingsAccuracyMeters')} - ${l10n.getString('settingsConsiderIncreasingRadius')} ${formatDistanceWithImperial(position.accuracy * 2, ref.watch(unitSystemProvider).maybeWhen(data: (useImperial) => useImperial, orElse: () => false), l10n)})'
              : '${l10n.getString('settingsLocationSuccess')} ($accuracyText${l10n.getString('settingsAccuracyMeters')})';

          ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
            SnackBar(
              content: Text(message),
              duration: position.accuracy > 50 ? const Duration(seconds: 5) : const Duration(seconds: 3),
            ),
          );
        } else if (isDialogOpen && mounted) {
          setState(() => isFetchingLocation = false);
          ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
            SnackBar(content: Text(l10n.getString('settingsLocationFailed'))),
          );
        }
        return;
      }

      // 3) Mobile: permission + last-known + current (best effort)
      try {
        final hasPermission = await locationService.handleLocationPermission();
        if (!hasPermission) {
          if (isDialogOpen && mounted) {
            setState(() => isFetchingLocation = false);
          }
          return;
        }

        final last = await Geolocator.getLastKnownPosition();
        if (last != null && isDialogOpen && mounted) {
          setState(() {
            latitude ??= last.latitude;
            longitude ??= last.longitude;
          });
        }

        final current = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 10));

        if (isDialogOpen && mounted) {
          setState(() {
            latitude = current.latitude;
            longitude = current.longitude;
            isFetchingLocation = false;
          });
        }
      } catch (_) {
        if (isDialogOpen && mounted) {
          setState(() => isFetchingLocation = false);
          ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
            SnackBar(content: Text(l10n.getString('settingsLocationFailed'))),
          );
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          // Auto-fetch location on dialog open
          if (!hasAutoFetched) {
            hasAutoFetched = true;
            fetchCurrentLocation(setState);
          }

          // Ensure cursor starts on the name field
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (isDialogOpen && nameFocusNode.canRequestFocus) {
              nameFocusNode.requestFocus();
            }
          });

          return AlertDialog(
            title: Text(l10n.getString('settingsLocationRules')),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.getString('settingsLocationRulesDesc')),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: nameController,
                    focusNode: nameFocusNode,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: l10n.getString('settingsLocationName'),
                      hintText: l10n.getString('settingsLocationNameHint'),
                      prefixIcon: const Icon(Icons.location_on),
                    ),
                    onChanged: (value) {
                      setState(() => locationName = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (isFetchingLocation)
                    Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.getString('settingsGettingPreciseLocation'),
                          style: const TextStyle(fontSize: 12, color: Colors.blue),
                        ),
                      ],
                    )
                  else
                    if (latitude != null && longitude != null)
                      Text(
                        '${l10n.getString('settingsLocationPrefix')}: ${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}',
                        style: const TextStyle(fontSize: 12, color: Colors.green),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: () => fetchCurrentLocation(setState),
                        icon: const Icon(Icons.my_location),
                        label: Text(l10n.getString('settingsUseCurrentLocation')),
                      ),
                  const SizedBox(height: 16),
                Text(
                  '${l10n.getString('settingsRadius')}: ${formatDistanceWithImperial(radiusMeters, ref.watch(unitSystemProvider).maybeWhen(data: (useImperial) => useImperial, orElse: () => false), l10n)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: radiusMeters,
                  min: 5.0,
                  max: 500.0,
                  divisions: 99,
                  label: formatDistanceWithImperial(radiusMeters, ref.watch(unitSystemProvider).maybeWhen(data: (useImperial) => useImperial, orElse: () => false), l10n),
                  onChanged: (value) {
                    setState(() => radiusMeters = value);
                  },
                ),
                Text(
                  kIsWeb 
                    ? '${l10n.getString('settingsLocationRadiusDesc')} (${l10n.getString('settingsWebGpsAccuracy')})'
                    : '${l10n.getString('settingsLocationRadiusDesc')} (${l10n.getString('settingsMobileGpsAccuracy')})',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                isDialogOpen = false;
                Navigator.pop(context);
              },
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: (locationName.isNotEmpty && latitude != null && longitude != null) ? () => saveLocationRule() : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        );
      }
      ),
    ).then((_) {
      isDialogOpen = false;
      nameController.dispose();
      nameFocusNode.dispose();
    });
  }

  void _showDateTimeRangeRulesDialog(BuildContext context, LocalizationState l10n) {
    DateTime? startDateTime;
    DateTime? endDateTime;
    TimeOfDay startTime = const TimeOfDay(hour: 0, minute: 0); // Default midnight
    TimeOfDay endTime = const TimeOfDay(hour: 23, minute: 59); // Default 11:59 PM

    // Helper to show time picker with label
    Future<TimeOfDay?> showLabeledTimePicker(BuildContext context, String label, TimeOfDay initialTime) async {
      return showTimePicker(
        context: context,
        initialTime: initialTime,
        helpText: label,
      );
    }

    // Helper to show date picker with label
    Future<DateTime?> showLabeledDatePicker(BuildContext context, String label, DateTime initialDate, DateTime firstDate, DateTime lastDate) async {
      return showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
        helpText: label,
      );
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsDateTimeRange')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.getString('settingsDateTimeRangeDesc'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 20),
                
                // Start Date & Time
                Text(
                  l10n.getString('settingsStart'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final date = await showLabeledDatePicker(
                            context,
                            l10n.getString('settingsSelectStartDate'),
                            startDateTime ?? now,
                            now,
                            now.add(const Duration(days: 365)),
                          );
                          if (date != null) {
                            setState(() => startDateTime = DateTime(date.year, date.month, date.day, startTime.hour, startTime.minute));
                            
                            // Auto-show time picker after date selection
                            if (context.mounted) {
                              final time = await showLabeledTimePicker(context, l10n.getString('settingsStartTime'), startTime);
                              if (time != null) {
                                setState(() {
                                  startTime = time;
                                  startDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                });
                                
                                // Auto-show end date picker after start time selected
                                if (context.mounted && endDateTime == null) {
                                  final endDate = await showLabeledDatePicker(
                                    context,
                                    l10n.getString('settingsSelectEndDate'),
                                    date.isAfter(now) ? date : now,
                                    date,
                                    now.add(const Duration(days: 365)),
                                  );
                                  if (endDate != null) {
                                    setState(() => endDateTime = DateTime(endDate.year, endDate.month, endDate.day, endTime.hour, endTime.minute));
                                    
                                    // Auto-show end time picker
                                    if (context.mounted) {
                                      // If same day, end time must be after start time
                                      final isSameDay = endDate.year == date.year && 
                                                       endDate.month == date.month && 
                                                       endDate.day == date.day;
                                      
                                      final endTimeResult = await showLabeledTimePicker(
                                        context,
                                        l10n.getString('settingsEndTime'),
                                        isSameDay 
                                          ? TimeOfDay(hour: time.hour + 1 > 23 ? 23 : time.hour + 1, minute: time.minute)
                                          : endTime,
                                      );
                                      if (endTimeResult != null) {
                                        // Validate end time is after start time on same day
                                        if (isSameDay) {
                                          final startMinutes = time.hour * 60 + time.minute;
                                          final endMinutes = endTimeResult.hour * 60 + endTimeResult.minute;
                                          if (endMinutes <= startMinutes) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                              );
                                            }
                                            return;
                                          }
                                        }
                                        setState(() {
                                          endTime = endTimeResult;
                                          endDateTime = DateTime(endDate.year, endDate.month, endDate.day, endTimeResult.hour, endTimeResult.minute);
                                        });
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        },
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: Text(
                          startDateTime != null
                            ? DateFormat.yMd(_getSystemLocale(context)).format(startDateTime!)
                            : l10n.getString('settingsSelectDate'),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton.icon(
                        onPressed: startDateTime != null ? () async {
                          final time = await showLabeledTimePicker(context, l10n.getString('settingsStartTime'), startTime);
                          if (time != null) {
                            setState(() {
                              startTime = time;
                              startDateTime = DateTime(
                                startDateTime!.year,
                                startDateTime!.month,
                                startDateTime!.day,
                                time.hour,
                                time.minute,
                              );
                            });
                            
                            // Auto-show end date picker after start time modified manually
                            if (context.mounted && endDateTime == null) {
                              final now = DateTime.now();
                              final endDate = await showLabeledDatePicker(
                                context,
                                l10n.getString('settingsSelectEndDate'),
                                startDateTime!.isAfter(now) ? startDateTime! : now,
                                startDateTime!,
                                now.add(const Duration(days: 365)),
                              );
                              if (endDate != null && context.mounted) {
                                setState(() => endDateTime = DateTime(endDate.year, endDate.month, endDate.day, endTime.hour, endTime.minute));
                                
                                // Auto-show end time picker
                                final isSameDay = endDate.year == startDateTime!.year && 
                                                 endDate.month == startDateTime!.month && 
                                                 endDate.day == startDateTime!.day;
                                
                                final endTimeResult = await showLabeledTimePicker(
                                  context,
                                  l10n.getString('settingsEndTime'),
                                  isSameDay 
                                    ? TimeOfDay(hour: time.hour + 1 > 23 ? 23 : time.hour + 1, minute: time.minute)
                                    : endTime,
                                );
                                if (endTimeResult != null) {
                                  if (isSameDay) {
                                    final startMinutes = time.hour * 60 + time.minute;
                                    final endMinutes = endTimeResult.hour * 60 + endTimeResult.minute;
                                    if (endMinutes <= startMinutes) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                        );
                                      }
                                      return;
                                    }
                                  }
                                  setState(() {
                                    endTime = endTimeResult;
                                    endDateTime = DateTime(endDate.year, endDate.month, endDate.day, endTimeResult.hour, endTimeResult.minute);
                                  });
                                }
                              }
                            }
                          }
                        } : null,
                        icon: const Icon(Icons.access_time, size: 18),
                        label: Text(
                          _formatTime(context, startTime),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                
                // End Date & Time
                Text(
                  l10n.getString('settingsEnd'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: OutlinedButton.icon(
                        onPressed: startDateTime != null ? () async {
                          final now = DateTime.now();
                          final date = await showLabeledDatePicker(
                            context,
                            l10n.getString('settingsSelectEndDate'),
                            endDateTime ?? startDateTime ?? now,
                            startDateTime!,
                            now.add(const Duration(days: 365)),
                          );
                          if (date != null) {
                            setState(() => endDateTime = DateTime(date.year, date.month, date.day, endTime.hour, endTime.minute));
                            
                            // Auto-show time picker after date selection
                            if (context.mounted) {
                              // If same day, end time must be after start time
                              final isSameDay = date.year == startDateTime!.year && 
                                               date.month == startDateTime!.month && 
                                               date.day == startDateTime!.day;
                              
                              final time = await showLabeledTimePicker(
                                context,
                                l10n.getString('settingsEndTime'),
                                isSameDay 
                                  ? TimeOfDay(hour: startTime.hour + 1 > 23 ? 23 : startTime.hour + 1, minute: startTime.minute)
                                  : endTime,
                              );
                              if (time != null) {
                                // Validate end time is after start time on same day
                                if (isSameDay) {
                                  final startMinutes = startTime.hour * 60 + startTime.minute;
                                  final endMinutes = time.hour * 60 + time.minute;
                                  if (endMinutes <= startMinutes) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                      );
                                    }
                                    return;
                                  }
                                }
                                setState(() {
                                  endTime = time;
                                  endDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                });
                              }
                            }
                          }
                        } : null,
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: Text(
                          endDateTime != null
                            ? DateFormat.yMd(_getSystemLocale(context)).format(endDateTime!)
                            : l10n.getString('settingsSelectDate'),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton.icon(
                        onPressed: endDateTime != null ? () async {
                          // If same day, end time must be after start time
                          final isSameDay = endDateTime!.year == startDateTime!.year && 
                                           endDateTime!.month == startDateTime!.month && 
                                           endDateTime!.day == startDateTime!.day;
                          
                          final time = await showLabeledTimePicker(context, l10n.getString('settingsEndTime'), endTime);
                          if (time != null) {
                            // Validate end time is after start time on same day
                            if (isSameDay) {
                              final startMinutes = startTime.hour * 60 + startTime.minute;
                              final endMinutes = time.hour * 60 + time.minute;
                              if (endMinutes <= startMinutes) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                  );
                                }
                                return;
                              }
                            }
                            setState(() {
                              endTime = time;
                              endDateTime = DateTime(
                                endDateTime!.year,
                                endDateTime!.month,
                                endDateTime!.day,
                                time.hour,
                                time.minute,
                              );
                            });
                          }
                        } : null,
                        icon: const Icon(Icons.access_time, size: 18),
                        label: Text(
                          _formatTime(context, endTime),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Helper text
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary.withValues(alpha:0.7),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.getString('settingsTimesDefaultAllDay'),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            FilledButton(
              onPressed: startDateTime != null && endDateTime != null ? () async {
                // Final validation: ensure end is after start
                if (endDateTime!.isBefore(startDateTime!) || endDateTime!.isAtSameMomentAs(startDateTime!)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.getString('settingsEndDateTimeAfterStart'))),
                  );
                  return;
                }
                
                final rule = DateTimeRangeRule(
                  id: const Uuid().v4(),
                  startDateTime: startDateTime!,
                  endDateTime: endDateTime!,
                );
                await ref.read(invisibilityRulesProvider.notifier).addDateTimeRangeRule(rule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDateTimeRangeRuleAdded'))),
                  );
                }
              } : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showDayTimeRangeRulesDialog(BuildContext context, LocalizationState l10n) {
    final daysOfWeek = [
      l10n.getString('dayMonday'),
      l10n.getString('dayTuesday'),
      l10n.getString('dayWednesday'),
      l10n.getString('dayThursday'),
      l10n.getString('dayFriday'),
      l10n.getString('daySaturday'),
      l10n.getString('daySunday'),
    ];
    final selectedDays = <int>{};
    TimeOfDay startTime = const TimeOfDay(hour: 0, minute: 0); // Default midnight
    TimeOfDay endTime = const TimeOfDay(hour: 23, minute: 59); // Default 11:59 PM

    // Helper to show time picker with label
    Future<TimeOfDay?> showLabeledTimePicker(BuildContext context, String label, TimeOfDay initialTime) async {
      return showTimePicker(
        context: context,
        initialTime: initialTime,
        helpText: label,
      );
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsDayTimeRange')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.getString('settingsDayTimeRangeDesc'),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 20),
                
                // Day selection section
                Text(
                  l10n.getString('settingsDays'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (index) {
                    final dayIndex = index + 1; // 1 = Monday, 7 = Sunday
                    final isSelected = selectedDays.contains(dayIndex);
                    return FilterChip(
                      label: Text(daysOfWeek[index]),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            selectedDays.add(dayIndex);
                          } else {
                            selectedDays.remove(dayIndex);
                          }
                        });
                      },
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      selectedColor: Theme.of(context).colorScheme.tertiary.withValues(alpha:0.2),
                      checkmarkColor: Theme.of(context).colorScheme.tertiary,
                    );
                  }),
                ),
                const SizedBox(height: 20),
                
                // Time range section
                Text(
                  l10n.getString('settingsTimeRange'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showLabeledTimePicker(context, l10n.getString('settingsStartTime'), startTime);
                          if (picked != null) {
                            setState(() => startTime = picked);
                            
                            // Auto-show end time picker after start time selected
                            if (context.mounted) {
                              final endTimeResult = await showLabeledTimePicker(
                                context,
                                l10n.getString('settingsEndTime'),
                                TimeOfDay(
                                  hour: picked.hour + 1 > 23 ? 23 : picked.hour + 1,
                                  minute: picked.minute,
                                ),
                              );
                              if (endTimeResult != null) {
                                // Validate end time is after start time
                                final startMinutes = picked.hour * 60 + picked.minute;
                                final endMinutes = endTimeResult.hour * 60 + endTimeResult.minute;
                                if (endMinutes <= startMinutes) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                    );
                                  }
                                  return;
                                }
                                setState(() => endTime = endTimeResult);
                              }
                            }
                          }
                        },
                        icon: const Icon(Icons.access_time, size: 18),
                        label: Text(
                          _formatTime(context, startTime),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        l10n.getString('settingsTo'),
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7)),
                      ),
                    ),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showLabeledTimePicker(context, l10n.getString('settingsEndTime'), endTime);
                          if (picked != null) {
                            // Validate end time is after start time
                            final startMinutes = startTime.hour * 60 + startTime.minute;
                            final endMinutes = picked.hour * 60 + picked.minute;
                            if (endMinutes <= startMinutes) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                                );
                              }
                              return;
                            }
                            setState(() => endTime = picked);
                          }
                        },
                        icon: const Icon(Icons.access_time, size: 18),
                        label: Text(
                          _formatTime(context, endTime),
                          style: const TextStyle(fontSize: 14),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Helper text
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiary.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.tertiary.withValues(alpha:0.7),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.getString('settingsTimesDefaultAllDay'),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            FilledButton(
              onPressed: selectedDays.isNotEmpty ? () async {
                // Validate end time is after start time
                final startMinutes = startTime.hour * 60 + startTime.minute;
                final endMinutes = endTime.hour * 60 + endTime.minute;
                if (endMinutes <= startMinutes) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.getString('settingsEndTimeAfterStart'))),
                  );
                  return;
                }
                
                final rule = DayTimeRangeRule(
                  id: const Uuid().v4(),
                  daysOfWeek: selectedDays.toList(),
                  startTime: startTime,
                  endTime: endTime,
                );
                await ref.read(invisibilityRulesProvider.notifier).addDayTimeRangeRule(rule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDayTimeRangeRuleAdded'))),
                  );
                }
              } : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  // Edit dialog methods
  void _showEditLocationRuleDialog(BuildContext context, LocalizationState l10n, LocationRule rule) {
    String locationName = rule.name;
    double? latitude = rule.latitude;
    double? longitude = rule.longitude;
    double radiusMeters = rule.radiusMeters;
    bool isDialogOpen = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsEditLocationRule')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsLocationRulesDesc')),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: locationName,
                  decoration: InputDecoration(
                    labelText: l10n.getString('settingsLocationName'),
                    hintText: l10n.getString('settingsLocationNameHint'),
                    prefixIcon: const Icon(Icons.location_on),
                  ),
                  onChanged: (value) {
                    setState(() => locationName = value);
                  },
                ),
                const SizedBox(height: 12),
                if (latitude != null && longitude != null)
                  Text(
                    '${l10n.getString('settingsLocationPrefix')}: ${latitude!.toStringAsFixed(6)}, ${longitude!.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 12, color: Colors.green),
                  ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    // Show loading dialog
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => AlertDialog(
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(l10n.getString('settingsGettingPreciseLocation')),
                          ],
                        ),
                      ),
                    );

                    final locationService = ref.read(locationServiceProvider);
                    if (locationService is WebLocationService) {
                      // Use high-precision method with multiple samples
                      final position = await locationService.getHighPrecisionPosition(
                        sampleCount: 5,
                        sampleInterval: const Duration(seconds: 2),
                        maxAccuracyMeters: 50.0,
                      );
                      
                      // Close loading dialog
                      if (mounted) Navigator.of(context).pop(); // ignore: use_build_context_synchronously
                      
                      if (position != null && isDialogOpen) {
                        setState(() {
                          latitude = position.latitude;
                          longitude = position.longitude;
                        });
                        ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                          SnackBar(content: Text('${l10n.getString('settingsLocationSuccess')} (${position.accuracy.toStringAsFixed(0)}${l10n.getString('settingsAccuracyMeters')})')),
                        );
                      } else if (!isDialogOpen) {
                        // Dialog was closed, don't update state
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                          SnackBar(content: Text(l10n.getString('settingsLocationFailed'))),
                        );
                      }
                    } else {
                      // Close loading dialog
                      if (mounted) Navigator.of(context).pop();
                      // For mobile, use existing logic
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.getString('settingsLocationServiceUnavailable'))),
                      );
                    }
                  },
                  icon: const Icon(Icons.my_location),
                  label: Text(l10n.getString('settingsUseCurrentLocation')),
                ),
                const SizedBox(height: 16),
                Text(
                  '${l10n.getString('settingsRadius')}: ${formatDistanceWithImperial(radiusMeters, ref.watch(unitSystemProvider).maybeWhen(data: (useImperial) => useImperial, orElse: () => false), l10n)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: radiusMeters,
                  min: 5.0,
                  max: 500.0,
                  divisions: 99,
                  label: formatDistanceWithImperial(radiusMeters, ref.watch(unitSystemProvider).maybeWhen(data: (useImperial) => useImperial, orElse: () => false), l10n),
                  onChanged: (value) {
                    setState(() => radiusMeters = value);
                  },
                ),
                Text(
                  kIsWeb 
                    ? '${l10n.getString('settingsLocationRadiusDesc')} (${l10n.getString('settingsWebGpsAccuracy')})'
                    : '${l10n.getString('settingsLocationRadiusDesc')} (${l10n.getString('settingsMobileGpsAccuracy')})',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                isDialogOpen = false;
                Navigator.pop(context);
              },
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: locationName.isNotEmpty && latitude != null && longitude != null ? () async {
                final updatedRule = LocationRule(
                  id: rule.id,
                  name: locationName,
                  latitude: latitude!,
                  longitude: longitude!,
                  radiusMeters: radiusMeters,
                );
                await ref.read(invisibilityRulesProvider.notifier).updateLocationRule(updatedRule);
                // Refresh current location to ensure invisibility rules are properly checked
                ref.read(currentLocationProvider.notifier).refreshLocation();
                isDialogOpen = false;
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsLocationRuleUpdated'))),
                  );
                }
              } : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDateRangeRuleDialog(BuildContext context, LocalizationState l10n, DateRangeRule rule) {
    DateTime startDate = rule.startDate;
    DateTime endDate = rule.endDate;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsDateRangeRules')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsDateRangeRulesDesc')),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: startDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setState(() => startDate = picked);
                          }
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: Text(DateFormat.yMd(_getSystemLocale(context)).format(startDate)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.getString('settingsTo')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: endDate,
                            firstDate: startDate,
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setState(() => endDate = picked);
                          }
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: Text(DateFormat.yMd(_getSystemLocale(context)).format(endDate)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final updatedRule = DateRangeRule(
                  id: rule.id,
                  startDate: startDate,
                  endDate: endDate,
                );
                await ref.read(invisibilityRulesProvider.notifier).updateDateRangeRule(updatedRule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDateRangeRuleUpdated'))),
                  );
                }
              },
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditTimeRangeRuleDialog(BuildContext context, LocalizationState l10n, TimeRangeRule rule) {
    TimeOfDay startTime = rule.startTime;
    TimeOfDay endTime = rule.endTime;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsTimeRangeRules')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsTimeRangeRulesDesc')),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: startTime,
                          );
                          if (picked != null) {
                            setState(() => startTime = picked);
                          }
                        },
                        icon: const Icon(Icons.schedule),
                        label: Text(_formatTime(context, startTime)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.getString('settingsTo')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: endTime,
                          );
                          if (picked != null) {
                            setState(() => endTime = picked);
                          }
                        },
                        icon: const Icon(Icons.schedule),
                        label: Text(_formatTime(context, endTime)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final updatedRule = TimeRangeRule(
                  id: rule.id,
                  startTime: startTime,
                  endTime: endTime,
                );
                await ref.read(invisibilityRulesProvider.notifier).updateTimeRangeRule(updatedRule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsTimeRangeRuleUpdated'))),
                  );
                }
              },
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDayOfWeekRuleDialog(BuildContext context, LocalizationState l10n, DayOfWeekRule rule) {
    final daysOfWeek = [
      l10n.getString('dayMonday'),
      l10n.getString('dayTuesday'),
      l10n.getString('dayWednesday'),
      l10n.getString('dayThursday'),
      l10n.getString('dayFriday'),
      l10n.getString('daySaturday'),
      l10n.getString('daySunday'),
    ];
    final selectedDays = Set<int>.from(rule.daysOfWeek);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsDayOfWeekRules')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsDayOfWeekRulesDesc')),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (index) {
                    final dayIndex = index + 1; // 1 = Monday, 7 = Sunday
                    final isSelected = selectedDays.contains(dayIndex);
                    return FilterChip(
                      label: Text(daysOfWeek[index]),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            selectedDays.add(dayIndex);
                          } else {
                            selectedDays.remove(dayIndex);
                          }
                        });
                      },
                      backgroundColor: Colors.grey.shade100,
                      selectedColor: Theme.of(context).colorScheme.secondary.withValues(alpha:0.2),
                      checkmarkColor: Theme.of(context).colorScheme.secondary,
                    );
                  }),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: selectedDays.isNotEmpty ? () async {
                final updatedRule = DayOfWeekRule(
                  id: rule.id,
                  daysOfWeek: selectedDays.toList(),
                );
                await ref.read(invisibilityRulesProvider.notifier).updateDayOfWeekRule(updatedRule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDayOfWeekRuleUpdated'))),
                  );
                }
              } : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDateTimeRangeRuleDialog(BuildContext context, LocalizationState l10n, DateTimeRangeRule rule) {
    DateTime startDateTime = rule.startDateTime;
    DateTime endDateTime = rule.endDateTime;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsEditDateTimeRange')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsEditDateTimeRangeDesc')),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: startDateTime,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (!context.mounted || date == null) return;
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(startDateTime),
                          );
                          if (!context.mounted || time == null) return;
                          setState(() => startDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                        },
                        icon: const Icon(Icons.date_range),
                        label: Text(DateFormat.yMd(_getSystemLocale(context)).add_jm().format(startDateTime)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: endDateTime,
                            firstDate: startDateTime,
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (!context.mounted || date == null) return;
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(endDateTime),
                          );
                          if (!context.mounted || time == null) return;
                          setState(() => endDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                        },
                        icon: const Icon(Icons.date_range),
                        label: Text(DateFormat.yMd(_getSystemLocale(context)).add_jm().format(endDateTime)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final updatedRule = DateTimeRangeRule(
                  id: rule.id,
                  startDateTime: startDateTime,
                  endDateTime: endDateTime,
                );
                await ref.read(invisibilityRulesProvider.notifier).updateDateTimeRangeRule(updatedRule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDateTimeRangeUpdated'))),
                  );
                }
              },
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDayTimeRangeRuleDialog(BuildContext context, LocalizationState l10n, DayTimeRangeRule rule) {
    final daysOfWeek = [
      l10n.getString('dayMonday'),
      l10n.getString('dayTuesday'),
      l10n.getString('dayWednesday'),
      l10n.getString('dayThursday'),
      l10n.getString('dayFriday'),
      l10n.getString('daySaturday'),
      l10n.getString('daySunday'),
    ];
    final selectedDays = Set<int>.from(rule.daysOfWeek);
    TimeOfDay startTime = rule.startTime;
    TimeOfDay endTime = rule.endTime;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.getString('settingsEditDayTimeRange')),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.getString('settingsEditDayTimeRangeDesc')),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (index) {
                    final dayIndex = index + 1; // 1 = Monday, 7 = Sunday
                    final isSelected = selectedDays.contains(dayIndex);
                    return FilterChip(
                      label: Text(daysOfWeek[index]),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            selectedDays.add(dayIndex);
                          } else {
                            selectedDays.remove(dayIndex);
                          }
                        });
                      },
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      selectedColor: Theme.of(context).colorScheme.tertiary.withValues(alpha:0.2),
                      checkmarkColor: Theme.of(context).colorScheme.tertiary,
                    );
                  }),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: startTime,
                          );
                          if (picked != null) {
                            setState(() => startTime = picked);
                          }
                        },
                        icon: const Icon(Icons.schedule),
                        label: Text(_formatTime(context, startTime)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.getString('settingsTo')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: endTime,
                          );
                          if (picked != null) {
                            setState(() => endTime = picked);
                          }
                        },
                        icon: const Icon(Icons.schedule),
                        label: Text(_formatTime(context, endTime)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: selectedDays.isNotEmpty ? () async {
                final updatedRule = DayTimeRangeRule(
                  id: rule.id,
                  daysOfWeek: selectedDays.toList(),
                  startTime: startTime,
                  endTime: endTime,
                );
                await ref.read(invisibilityRulesProvider.notifier).updateDayTimeRangeRule(updatedRule);
                if (mounted) {
                  Navigator.pop(context); // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar( // ignore: use_build_context_synchronously
                    SnackBar(content: Text(l10n.getString('settingsDayTimeRangeUpdated'))),
                  );
                }
              } : null,
              child: Text(l10n.getString('generalSave')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final invisibilityRules = ref.watch(invisibilityRulesProvider);
    final activeRuleIds = ref.watch(activeRuleIdsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsInvisibilityRules')),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
        foregroundColor: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          // Header card with description
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                  Theme.of(context).colorScheme.primary.withValues(alpha:0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha:0.2)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.visibility_off, color: Theme.of(context).colorScheme.primary, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.getString('settingsInvisibilityRules'),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.getString('settingsInvisibilityRulesDesc'),
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Active Rules Section
          if (invisibilityRules.locationRules.isNotEmpty ||
              invisibilityRules.dateRangeRules.isNotEmpty ||
              invisibilityRules.timeRangeRules.isNotEmpty ||
              invisibilityRules.dayOfWeekRules.isNotEmpty ||
              invisibilityRules.dateTimeRangeRules.isNotEmpty ||
              invisibilityRules.dayTimeRangeRules.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
              Text(
                l10n.getString('settingsActiveRules'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),            // Display all active rules
            ...invisibilityRules.locationRules.map((rule) => _buildExistingRule(
              context,
              l10n,
              '${l10n.getString('settingsLocationPrefix')}: ${rule.name}',
              Icons.location_on,
              Theme.of(context).colorScheme.primary,
              () => ref.read(invisibilityRulesProvider.notifier).removeLocationRule(rule.id),
              canEdit: true,
              onEdit: () => _showEditLocationRuleDialog(context, l10n, rule),
              isPast: false,
              enabled: rule.enabled,
              onToggle: (value) => ref.read(invisibilityRulesProvider.notifier).toggleLocationRuleEnabled(rule.id),
              ruleId: rule.id,
              type: 'location',
              isActive: activeRuleIds.containsKey(rule.id),
            )),
            ...invisibilityRules.dateRangeRules.map((rule) => _buildExistingRule(
              context,
              l10n,
              '${l10n.getString('settingsDatePrefix')}: ${l10n.getString('rangeFrom')} ${DateFormat.yMd(_getSystemLocale(context)).format(rule.startDate)} ${l10n.getString('rangeTo')} ${DateFormat.yMd(_getSystemLocale(context)).format(rule.endDate)}',
              Icons.date_range,
              Theme.of(context).colorScheme.secondary,
              () => ref.read(invisibilityRulesProvider.notifier).removeDateRangeRule(rule.id),
              canEdit: true,
              onEdit: () => _showEditDateRangeRuleDialog(context, l10n, rule),
              isPast: false,
              enabled: rule.enabled,
              onToggle: (value) => ref.read(invisibilityRulesProvider.notifier).toggleDateRangeRuleEnabled(rule.id),
              ruleId: rule.id,
              type: 'dateRange',
              isActive: activeRuleIds.containsKey(rule.id),
            )),
            ...invisibilityRules.timeRangeRules.map((rule) => _buildExistingRule(
              context,
              l10n,
              '${l10n.getString('settingsTimePrefix')}: ${l10n.getString('rangeFrom')} ${_formatTime(context, rule.startTime)} ${l10n.getString('rangeTo')} ${_formatTime(context, rule.endTime)}',
              Icons.schedule,
              Theme.of(context).colorScheme.tertiary,
              () => ref.read(invisibilityRulesProvider.notifier).removeTimeRangeRule(rule.id),
              canEdit: true,
              onEdit: () => _showEditTimeRangeRuleDialog(context, l10n, rule),
              isPast: false,
              enabled: rule.enabled,
              onToggle: (value) => ref.read(invisibilityRulesProvider.notifier).toggleTimeRangeRuleEnabled(rule.id),
              ruleId: rule.id,
              type: 'timeRange',
              isActive: activeRuleIds.containsKey(rule.id),
            )),
            ...invisibilityRules.dayOfWeekRules.map((rule) => _buildExistingRule(
              context,
              l10n,
              '${l10n.getString('settingsDaysPrefix')}: ${rule.daysOfWeek.map((d) => l10n.getString(['dayMonday', 'dayTuesday', 'dayWednesday', 'dayThursday', 'dayFriday', 'daySaturday', 'daySunday'][d - 1])).join(', ')}',
              Icons.calendar_view_week,
              Theme.of(context).colorScheme.secondaryContainer,
              () => ref.read(invisibilityRulesProvider.notifier).removeDayOfWeekRule(rule.id),
              canEdit: true,
              onEdit: () => _showEditDayOfWeekRuleDialog(context, l10n, rule),
              isPast: false,
              enabled: rule.enabled,
              onToggle: (value) => ref.read(invisibilityRulesProvider.notifier).toggleDayOfWeekRuleEnabled(rule.id),
              ruleId: rule.id,
              type: 'dayOfWeek',
              isActive: activeRuleIds.containsKey(rule.id),
            )),
            ...invisibilityRules.dateTimeRangeRules.map((rule) {
              final isPast = rule.isInPast(DateTime.now());
              return _buildExistingRule(
                context,
                l10n,
                '${l10n.getString('settingsDateTimePrefix')}: ${l10n.getString('rangeFrom')} ${DateFormat.yMd(_getSystemLocale(context)).add_jm().format(rule.startDateTime)} ${l10n.getString('rangeTo')} ${DateFormat.yMd(_getSystemLocale(context)).add_jm().format(rule.endDateTime)}',
                Icons.date_range,
                Theme.of(context).colorScheme.primary,
                () => ref.read(invisibilityRulesProvider.notifier).removeDateTimeRangeRule(rule.id),
                canEdit: !isPast,
                onEdit: isPast ? null : () => _showEditDateTimeRangeRuleDialog(context, l10n, rule),
                isPast: isPast,
                enabled: rule.enabled,
                onToggle: isPast ? null : (value) => ref.read(invisibilityRulesProvider.notifier).toggleDateTimeRangeRuleEnabled(rule.id),
                ruleId: rule.id,
                type: 'dateTimeRange',
                isActive: activeRuleIds.containsKey(rule.id),
              );
            }),
            ...invisibilityRules.dayTimeRangeRules.map((rule) => _buildExistingRule(
              context,
              l10n,
              '${l10n.getString('settingsDaysTimePrefix')}: ${rule.daysOfWeek.map((d) => l10n.getString(['dayMonday', 'dayTuesday', 'dayWednesday', 'dayThursday', 'dayFriday', 'daySaturday', 'daySunday'][d - 1])).join(', ')} ${l10n.getString('rangeFrom')} ${_formatTime(context, rule.startTime)} ${l10n.getString('rangeTo')} ${_formatTime(context, rule.endTime)}',
              Icons.schedule,
              Theme.of(context).colorScheme.tertiary,
              () => ref.read(invisibilityRulesProvider.notifier).removeDayTimeRangeRule(rule.id),
              canEdit: true,
              onEdit: () => _showEditDayTimeRangeRuleDialog(context, l10n, rule),
              isPast: false,
              enabled: rule.enabled,
              onToggle: (value) => ref.read(invisibilityRulesProvider.notifier).toggleDayTimeRangeRuleEnabled(rule.id),
              ruleId: rule.id,
              type: 'dayTimeRange',
              isActive: activeRuleIds.containsKey(rule.id),
            )),
            
            // Separator between active rules and add new section
            const SizedBox(height: 32),
          ],
          
          // Add New Rule Section (always shown)
          Text(
            l10n.getString('settingsAddNewRule'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          _buildInvisibilityRuleType(
            context,
            l10n,
            Icons.location_on,
            l10n.getString('settingsLocationRules'),
            l10n.getString('settingsLocationRulesDesc'),
            Theme.of(context).colorScheme.primary,
            () => _showLocationRulesDialog(context, l10n),
          ),
          const SizedBox(height: 12),
          _buildInvisibilityRuleType(
            context,
            l10n,
            Icons.date_range,
            l10n.getString('settingsDateTimeRange'),
            l10n.getString('settingsDateTimeRangeDesc'),
            Theme.of(context).colorScheme.primary,
            () => _showDateTimeRangeRulesDialog(context, l10n),
          ),
          const SizedBox(height: 12),
          _buildInvisibilityRuleType(
            context,
            l10n,
            Icons.schedule,
            l10n.getString('settingsDayTimeRange'),
            l10n.getString('settingsDayTimeRangeDesc'),
            Theme.of(context).colorScheme.tertiary,
            () => _showDayTimeRangeRulesDialog(context, l10n),
          ),
        ],
      ),
    );
  }
}
