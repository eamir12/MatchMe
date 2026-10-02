// lib/widgets/custom_app_bar.dart
import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';

PreferredSizeWidget buildCustomAppBar(
  BuildContext context,
  LocalizationState l10n,
  String screenName,
  List<Widget> actions, {
  required VoidCallback onHomePressed,
  Widget? centerWidget,

  /// Extra space consumed on the leading edge of the body by something outside
  /// the app bar - a navigation rail, for example.
  ///
  /// The app bar spans the full window while the body starts after the rail, so
  /// centring the strip over the window would leave it visibly off-centre
  /// relative to the content it describes. Pass the rail width to centre it over
  /// the content column instead.
  double centerStripLeadingInset = 0,
}) {
  final textDirection = Directionality.of(context);

  return AppBar(
    backgroundColor:
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.surface,
    foregroundColor:
        Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface,
    elevation: 0,
    centerTitle: false,
    titleSpacing: 12,
    title: Row(
      textDirection: textDirection,
      children: [
        Semantics(
          container: true,
          button: true,
          label: l10n.getString('navHome'),
          onTap: onHomePressed,
          excludeSemantics: true,
          child: IconButton(
            onPressed: onHomePressed,
            tooltip: l10n.getString('navHome'),
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              fixedSize: const Size(48, 48),
              padding: const EdgeInsets.all(8),
            ),
            icon: ExcludeSemantics(
              child: Image.asset(
                'assets/images/logo.png',
                height: 32,
                width: 32,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            screenName,
            maxLines: 2,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color:
                  Theme.of(context).appBarTheme.foregroundColor ??
                  Theme.of(context).colorScheme.onSurface,
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
            preferredSize: const Size.fromHeight(56),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const pad = 12.0;
                // The strip is centred by an `Align`, so its centre lands at
                // W/2 + leftExtra/2. Adding the full inset to the leading padding
                // therefore moves the centre by inset/2, which is exactly what
                // re-centres it over a column that starts at the inset.
                // Clamped so an inset wider than the window cannot overflow.
                final maxInset = constraints.maxWidth - 2 * pad - 1;
                final extra = centerStripLeadingInset <= 0
                    ? 0.0
                    : centerStripLeadingInset.clamp(
                        0.0,
                        maxInset > 0 ? maxInset : 0.0,
                      );
                return Padding(
                  padding: EdgeInsets.fromLTRB(pad + extra, 0, pad, 8),
                  child: Align(
                    alignment: Alignment.center,
                    child: centerWidget,
                  ),
                );
              },
            ),
          ),
  );
}
