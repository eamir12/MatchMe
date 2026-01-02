// lib/widgets/custom_app_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/home_providers.dart';

PreferredSizeWidget buildCustomAppBar(BuildContext context, WidgetRef ref, LocalizationState l10n, String screenName, List<Widget> actions, {Widget? centerWidget}) {
  final textDirection = Directionality.of(context);

  return AppBar(
    backgroundColor: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
    foregroundColor: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
    elevation: 0,
    centerTitle: false,
    titleSpacing: 12,
    title: Row(
      textDirection: textDirection,
      children: [
        GestureDetector(
          onTap: () {
            // Navigate to Home screen (index 0)
            ref.read(navigationIndexProvider.notifier).setIndex(0);
          },
          child: Image.asset(
            'assets/images/logo.png',
            height: 32,
            width: 32,
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            screenName,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
              fontSize: 16,
            ),
          ),
        ),
      ],
    ),
    actions: actions,
    bottom: centerWidget == null
        ? null
        : PreferredSize(
            preferredSize: const Size.fromHeight(40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.center,
                child: centerWidget,
              ),
            ),
          ),
  );
}