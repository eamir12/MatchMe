import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';

class LocationShareDurationDialog extends ConsumerStatefulWidget {
  final String? otherUserName;
  final bool isChangingDuration;
  final List<int>? durationOptions;

  const LocationShareDurationDialog({
    super.key,
    this.otherUserName,
    this.isChangingDuration = false,
    this.durationOptions,
  });

  @override
  ConsumerState<LocationShareDurationDialog> createState() =>
      _LocationShareDurationDialogState();
}

class _LocationShareDurationDialogState
    extends ConsumerState<LocationShareDurationDialog> {
  int? _selectedSeconds;
  List<int> _durationOptions = [];
  bool _loading = true;

  List<int> _normalizeOptions(Iterable<int> options) {
    final values = options.where((seconds) => seconds > 0).toSet().toList()
      ..sort();
    return values.isEmpty ? [900] : values;
  }

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final providedOptions = widget.durationOptions;
    if (providedOptions != null) {
      if (mounted) {
        setState(() {
          _durationOptions = _normalizeOptions(providedOptions);
          _selectedSeconds = _durationOptions.first;
          _loading = false;
        });
      }
      return;
    }
    try {
      final options = await appConfigService.getIntList(
        'location_sharing.duration_options_seconds',
        defaultValue: [900, 1800, 3600, 7200],
      );
      if (mounted) {
        setState(() {
          _durationOptions = _normalizeOptions(options);
          _selectedSeconds ??= _durationOptions.first;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _durationOptions = [900, 1800, 3600, 7200];
          _selectedSeconds ??= _durationOptions.first;
          _loading = false;
        });
      }
    }
  }

  String _formatDuration(int seconds, LocalizationState l10n) {
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      return l10n.getPluralString('locationShareHours', hours);
    } else {
      final minutes = seconds ~/ 60;
      return l10n.getPluralString('locationShareMinutes', minutes);
    }
  }

  String _recipientName(LocalizationState l10n) {
    final name = widget.otherUserName?.trim() ?? '';
    return name.isNotEmpty ? name : l10n.getString('generalUnknown');
  }

  Future<void> _submit(LocalizationState l10n) async {
    final selectedSeconds = _selectedSeconds;
    if (selectedSeconds == null) return;

    if (selectedSeconds == 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.getString('locationShareIndefiniteTitle')),
          content: Text(
            l10n.getString(
              'locationShareIndefiniteMessage',
              params: {'name': _recipientName(l10n)},
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.getString('locationShareStart')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    if (!mounted) return;
    final duration = selectedSeconds == 0
        ? Duration.zero
        : Duration(seconds: selectedSeconds);
    Navigator.of(context).pop(duration);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return AlertDialog(
      scrollable: true,
      title: Text(
        l10n.getString(
          widget.isChangingDuration
              ? 'locationShareChangeDurationTitle'
              : 'locationShareDurationTitle',
        ),
      ),
      content: _loading
          ? const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.otherUserName?.trim().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.getString(
                              'locationShareRecipientNotice',
                              params: {'name': _recipientName(l10n)},
                            ),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  l10n.getString('locationSharePrivacyNotice'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                RadioGroup<int>(
                  groupValue: _selectedSeconds,
                  onChanged: (value) {
                    setState(() => _selectedSeconds = value);
                  },
                  child: Column(
                    children: [
                      ..._durationOptions.map((seconds) {
                        return RadioListTile<int>(
                          title: Text(_formatDuration(seconds, l10n)),
                          value: seconds,
                        );
                      }),
                      RadioListTile<int>(
                        title: Text(l10n.getString('locationShareUntilOff')),
                        value: 0,
                      ),
                    ],
                  ),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        ElevatedButton(
          onPressed: _selectedSeconds == null ? null : () => _submit(l10n),
          child: Text(
            l10n.getString(
              widget.isChangingDuration
                  ? 'locationShareSaveDuration'
                  : 'locationShareStart',
            ),
          ),
        ),
      ],
    );
  }
}
