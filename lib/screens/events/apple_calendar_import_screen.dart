import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class AppleCalendarImportScreen extends ConsumerStatefulWidget {
  const AppleCalendarImportScreen({super.key});

  @override
  ConsumerState<AppleCalendarImportScreen> createState() =>
      _AppleCalendarImportScreenState();
}

class _AppleCalendarImportScreenState
    extends ConsumerState<AppleCalendarImportScreen> {
  final TextEditingController _urlController = TextEditingController();

  static final Uri _applePublicCalendarHelpUriEn = Uri.parse(
    'https://support.apple.com/en-us/guide/icloud/share-a-calendar-mm6b1a9479/icloud',
  );
  static final Uri _applePublicCalendarHelpUriEs = Uri.parse(
    'https://support.apple.com/es-es/guide/icloud/share-a-calendar-mm6b1a9479/icloud',
  );

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Uri _applePublicCalendarHelpUriForLocale(LocalizationState l10n) {
    final languageCode = l10n.currentLocale.languageCode.toLowerCase();
    if (languageCode.startsWith('es')) {
      return _applePublicCalendarHelpUriEs;
    }
    return _applePublicCalendarHelpUriEn;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.getString('eventsImportApple'))),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.phone_iphone, size: 64, color: Colors.blue),
                const SizedBox(height: 24),
                Text(
                  l10n.getString('calendarSyncConnectMessage'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 32),
                _buildApplePublicCalendarUrlField(l10n, context),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    final url = _urlController.text.trim();
                    if (url.isNotEmpty) {
                      Navigator.of(context).pop(url);
                    }
                  },
                  icon: const Icon(Icons.phone_iphone),
                  label: Text(l10n.getString('calendarSyncConnectApple')),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.getString('cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildApplePublicCalendarUrlField(
    LocalizationState l10n,
    BuildContext context,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.getString('calendarSyncApplePublicUrlHelp'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () async {
            final helpUri = _applePublicCalendarHelpUriForLocale(l10n);
            final launched = await launchUrl(
              helpUri,
              mode: LaunchMode.externalApplication,
            );
            if (!launched) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.getString('calendarSyncApplePublicHelpLinkOpenFailed'),
                  ),
                ),
              );
            }
          },
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            alignment: Alignment.centerLeft,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(
            children: [
              const Icon(Icons.help_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('calendarSyncApplePublicHelpLinkLabel'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.of(context).pop(value.trim());
            }
          },
          decoration: InputDecoration(
            labelText: l10n.getString('calendarSyncApplePublicUrlLabel'),
            hintText: l10n.getString('calendarSyncApplePublicUrlHint'),
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
