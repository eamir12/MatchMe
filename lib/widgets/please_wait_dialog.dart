import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../main.dart' show navigatorKey;
import '../providers/locale_provider.dart';

class PleaseWaitDialog extends ConsumerWidget {
  final String? messageOverride;

  const PleaseWaitDialog({super.key, this.messageOverride});

  static int _activeCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localization = ref.watch(localizationProvider);
    final message = messageOverride ?? localization.getString('pleaseWait');

    return AlertDialog(
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void show(BuildContext context, {String? message}) {
    _activeCount += 1;
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => PleaseWaitDialog(messageOverride: message),
    ).whenComplete(() {
      if (_activeCount > 0) _activeCount -= 1;
    });
  }

  static void hide([BuildContext? context]) {
    if (_activeCount <= 0) return;
    try {
      if (navigatorKey.currentContext != null) {
        Navigator.of(navigatorKey.currentContext!, rootNavigator: true).pop();
      } else if (context != null) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    } catch (_) {}
  }
}
