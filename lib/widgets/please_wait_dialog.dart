import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/locale_provider.dart';

class PleaseWaitDialog extends ConsumerWidget {
  const PleaseWaitDialog({super.key});

  static int _activeCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localization = ref.watch(localizationProvider);
    final message = localization.getString('pleaseWait');

    return AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Text(message),
        ],
      ),
    );
  }

  static void show(BuildContext context) {
    _activeCount += 1;
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => const PleaseWaitDialog(),
    ).whenComplete(() {
      if (_activeCount > 0) _activeCount -= 1;
    });
  }

  static void hide(BuildContext context) {
    if (_activeCount <= 0) return;
    if (!context.mounted) return;
    _activeCount -= 1;
    try {
      Navigator.of(context, rootNavigator: true).pop();
    } catch (_) {}
  }
}
