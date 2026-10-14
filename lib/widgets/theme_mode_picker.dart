import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/theme_provider.dart';

/// Shows the system/light/dark theme picker in its own dialog.
///
/// Theme mode used to be changeable only from Settings > App Display. The
/// requirement is that everywhere the UI language can be switched — auth
/// screen, profile wizard, settings — the theme can be switched too, but via
/// a separate button (like Settings), never from inside the language dialog.
Future<void> showThemeModePickerDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => const _ThemeModePickerDialog(),
  );
}

class _ThemeModePickerDialog extends ConsumerWidget {
  const _ThemeModePickerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final currentMode = ref.watch(themeModeProvider);
    final theme = Theme.of(context);
    final options = <(ThemeMode, String, IconData)>[
      (
        ThemeMode.system,
        'settingsThemeModeSystem',
        Icons.brightness_auto_outlined,
      ),
      (ThemeMode.light, 'settingsThemeModeLight', Icons.light_mode_outlined),
      (ThemeMode.dark, 'settingsThemeModeDark', Icons.dark_mode_outlined),
    ];

    return AlertDialog(
      scrollable: true,
      title: Text(l10n.getString('settingsThemeMode')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (mode, labelKey, icon) in options)
            ListTile(
              dense: true,
              leading: Icon(icon),
              title: Text(l10n.getString(labelKey)),
              trailing: currentMode == mode
                  ? Icon(Icons.check, color: theme.colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.of(context).pop();
                ref.read(themeModeProvider.notifier).setThemeMode(mode);
              },
            ),
        ],
      ),
    );
  }
}
