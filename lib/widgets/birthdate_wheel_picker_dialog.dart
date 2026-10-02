import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/services/voice_guidance_service.dart';

/// Fool-proof birthday picker: three labeled wheels (Month / Day / Year)
/// with explicit instructions, a live age preview, and a hard under-18 guard.
class BirthdateWheelPickerDialog extends ConsumerStatefulWidget {
  final LocalizationState l10n;
  final DateTime initialDate;
  final int minYear;
  final String Function(DateTime date) formatDate;

  const BirthdateWheelPickerDialog({
    super.key,
    required this.l10n,
    required this.initialDate,
    required this.minYear,
    required this.formatDate,
  });

  /// Returns the picked date, or null if cancelled.
  static Future<DateTime?> show(
    BuildContext context, {
    required LocalizationState l10n,
    required DateTime initialDate,
    required int minYear,
    required String Function(DateTime date) formatDate,
  }) {
    return showDialog<DateTime>(
      context: context,
      builder: (_) => BirthdateWheelPickerDialog(
        l10n: l10n,
        initialDate: initialDate,
        minYear: minYear,
        formatDate: formatDate,
      ),
    );
  }

  @override
  ConsumerState<BirthdateWheelPickerDialog> createState() =>
      _BirthdateWheelPickerDialogState();
}

class _BirthdateWheelPickerDialogState
    extends ConsumerState<BirthdateWheelPickerDialog> {
  static const List<String> _monthKeys = [
    'month_january',
    'month_february',
    'month_march',
    'month_april',
    'month_may',
    'month_june',
    'month_july',
    'month_august',
    'month_september',
    'month_october',
    'month_november',
    'month_december',
  ];

  late int _month;
  late int _day;
  late int _year;
  late final List<int> _years;
  late final FixedExtentScrollController _monthController;
  late FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _yearController;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // Youngest first: users cluster near 18, so the likely years sit at the top.
    _years = [
      for (int y = now.year - 18; y >= widget.minYear; y--) y,
    ];
    _month = widget.initialDate.month;
    _day = widget.initialDate.day;
    _year = _years.contains(widget.initialDate.year)
        ? widget.initialDate.year
        : _years.first;
    if (_day > _daysInMonth) _day = _daysInMonth;
    _monthController = FixedExtentScrollController(initialItem: _month - 1);
    _dayController = FixedExtentScrollController(initialItem: _day - 1);
    _yearController = FixedExtentScrollController(
      initialItem: _years.indexOf(_year),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ref.read(voiceGuidanceEnabledProvider)) return;
      unawaited(
        VoiceGuidanceService.instance.speakText(
          widget.l10n.getString('birthdayPickerInstruction'),
        ),
      );
    });
  }

  @override
  void dispose() {
    _monthController.dispose();
    _dayController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  int get _daysInMonth {
    final nextMonth = _month == 12 ? 1 : _month + 1;
    // Day 0 of nextMonth is the last day of the current month.
    return DateTime(_year, nextMonth, 0).day;
  }

  DateTime get _selectedDate => DateTime(_year, _month, _day);

  int get _selectedAge {
    final now = DateTime.now();
    final d = _selectedDate;
    int age = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) {
      age--;
    }
    return age;
  }

  bool get _isUnder18 => _selectedAge < 18;

  void _clampDayAfterWheelChange() {
    final maxDay = _daysInMonth;
    if (_day > maxDay) {
      _day = maxDay;
      // Rebuild the day wheel so it only offers days that exist.
      final old = _dayController;
      _dayController = FixedExtentScrollController(initialItem: maxDay - 1);
      old.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final age = _selectedAge;

    return AlertDialog(
      title: Text(l10n.getString('profileBirthday')),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.getString('birthdayPickerInstruction'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildWheel(
                  flex: 5,
                  label: l10n.getString('birthdayWheelMonth'),
                  child: _picker(
                    controller: _monthController,
                    itemCount: 12,
                    onChanged: (i) => setState(() {
                      _month = i + 1;
                      _clampDayAfterWheelChange();
                    }),
                    itemBuilder: (i) => Text(
                      l10n.getString(_monthKeys[i]),
                      textDirection: isRtl
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                _buildWheel(
                  flex: 3,
                  label: l10n.getString('birthdayWheelDay'),
                  child: _picker(
                    controller: _dayController,
                    itemCount: _daysInMonth,
                    onChanged: (i) => setState(() => _day = i + 1),
                    itemBuilder: (i) => Text('${i + 1}'),
                  ),
                ),
                _buildWheel(
                  flex: 4,
                  label: l10n.getString('birthdayWheelYear'),
                  child: _picker(
                    controller: _yearController,
                    itemCount: _years.length,
                    onChanged: (i) => setState(() {
                      _year = _years[i];
                      _clampDayAfterWheelChange();
                    }),
                    itemBuilder: (i) => Text('${_years[i]}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _isUnder18
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _isUnder18
                    ? l10n.getString('profileAgeRequirementNote')
                    : '${widget.formatDate(_selectedDate)}\n'
                        '${l10n.getString('generalAgeYearsOld', params: {'age': '$age'})}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _isUnder18
                      ? Theme.of(context).colorScheme.onErrorContainer
                      : Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.getString('generalCancel')),
        ),
        FilledButton(
          onPressed: _isUnder18
              ? null
              : () => Navigator.of(context).pop(_selectedDate),
          child: Text(l10n.getString('generalSave')),
        ),
      ],
    );
  }

  Widget _buildWheel({
    required int flex,
    required String label,
    required Widget child,
  }) {
    return Expanded(
      flex: flex,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(height: 132, child: child),
        ],
      ),
    );
  }

  Widget _picker({
    required FixedExtentScrollController controller,
    required int itemCount,
    required ValueChanged<int> onChanged,
    required Widget Function(int index) itemBuilder,
  }) {
    return CupertinoPicker(
      scrollController: controller,
      itemExtent: 36,
      squeeze: 1.2,
      useMagnifier: true,
      magnification: 1.15,
      selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
        background: Theme.of(context).colorScheme.primary.withValues(
          alpha: 0.12,
        ),
      ),
      onSelectedItemChanged: onChanged,
      children: [
        for (int i = 0; i < itemCount; i++)
          Center(child: itemBuilder(i)),
      ],
    );
  }
}
