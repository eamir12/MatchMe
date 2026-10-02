import 'package:flutter/material.dart';
import 'package:matchme/providers/currency_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/string_extensions.dart';

Future<String?> showCurrencyPickerBottomSheet({
  required BuildContext context,
  required LocalizationState l10n,
  required String selectedCurrency,
  required List<String> recentCurrencyCodes,
  required List<String> prioritizedCurrencyCodes,
  required List<CurrencyOption> allCurrencyOptions,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      return _CurrencyPickerSheet(
        l10n: l10n,
        selectedCurrency: selectedCurrency,
        recentCurrencyCodes: recentCurrencyCodes,
        prioritizedCurrencyCodes: prioritizedCurrencyCodes,
        allCurrencyOptions: allCurrencyOptions,
      );
    },
  );
}

class _CurrencyPickerSheet extends StatefulWidget {
  final LocalizationState l10n;
  final String selectedCurrency;
  final List<String> recentCurrencyCodes;
  final List<String> prioritizedCurrencyCodes;
  final List<CurrencyOption> allCurrencyOptions;

  const _CurrencyPickerSheet({
    required this.l10n,
    required this.selectedCurrency,
    required this.recentCurrencyCodes,
    required this.prioritizedCurrencyCodes,
    required this.allCurrencyOptions,
  });

  @override
  State<_CurrencyPickerSheet> createState() => _CurrencyPickerSheetState();
}

class _CurrencyPickerSheetState extends State<_CurrencyPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localeCode = widget.l10n.currentLocale.languageCode;
    final query = _query.trim().toLowerCase();
    final isSearching = query.isNotEmpty;
    final allOptions = widget.allCurrencyOptions
        .where(
          (option) => currencySearchText(
            option.code,
            localeCode: localeCode,
          ).contains(query),
        )
        .toList(growable: false);

    final recentCodes = widget.recentCurrencyCodes
        .where(
          (code) =>
              currencySearchText(code, localeCode: localeCode).contains(query),
        )
        .toList(growable: false);
    final topCodes = widget.prioritizedCurrencyCodes
        .where(
          (code) =>
              currencySearchText(code, localeCode: localeCode).contains(query),
        )
        .toList(growable: false);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.l10n.getString('currencyPickerTitle'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final rawText = _searchController.text;
                  final isEmpty = rawText.trim().isEmpty;
                  final isRtl =
                      !isEmpty && rawText.trimLeft().isRtlByFirstStrongChar();
                  return TextField(
                    controller: _searchController,
                    textDirection: isEmpty
                        ? Directionality.of(context)
                        : (isRtl ? TextDirection.rtl : TextDirection.ltr),
                    textAlign: isEmpty
                        ? TextAlign.start
                        : (isRtl ? TextAlign.right : TextAlign.left),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: widget.l10n.getString('currencySearchHint'),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _query = value;
                      });
                    },
                  );
                },
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    if (!isSearching && recentCodes.isNotEmpty) ...[
                      _SectionLabel(
                        label: widget.l10n.getString('currencyRecentSection'),
                      ),
                      ...recentCodes.map(
                        (code) => _buildCurrencyTile(code, localeCode),
                      ),
                    ],
                    if (!isSearching && topCodes.isNotEmpty) ...[
                      _SectionLabel(
                        label: widget.l10n.getString('currencyTopSection'),
                      ),
                      ...topCodes.map(
                        (code) => _buildCurrencyTile(code, localeCode),
                      ),
                    ],
                    _SectionLabel(
                      label: widget.l10n.getString('currencyAllSection'),
                    ),
                    if (allOptions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          widget.l10n.getString('currencyNoResults'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    else
                      ...allOptions.map(
                        (option) => _buildCurrencyTile(option.code, localeCode),
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

  Widget _buildCurrencyTile(String code, String localeCode) {
    final label = currencyPickerLabel(code, localeCode: localeCode);
    final subtitle = currencyChooserSecondaryLabel(code);
    final isSelected = code == widget.selectedCurrency;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(subtitle),
      trailing: isSelected ? const Icon(Icons.check_circle) : null,
      onTap: () => Navigator.of(context).pop(code),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
