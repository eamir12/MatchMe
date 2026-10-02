import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';

/// Public Typing row widget which displays a localized, gender-aware "{name} is typing" message.
class TypingRow extends ConsumerWidget {
  final String name;
  final String otherUserId;
  const TypingRow({super.key, required this.name, required this.otherUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final profileAsync = ref.watch(userProfileProvider(otherUserId));
    final profile = profileAsync.asData?.value;
    final gender = profile?.gender;
    final displayName = name.isNotEmpty
        ? name
        : l10n.getString('generalUnknown');
    // Try gender-aware translation first (with parameter substitution)
    final typed = l10n.getString(
      'chatIsTyping',
      gender: gender,
      params: {'name': displayName},
    );

    String text;
    if (typed.contains(displayName)) {
      text = typed;
    } else {
      // Fallback to base translation with name parameter
      final baseWithName = l10n.getString(
        'chatIsTyping',
        params: {'name': displayName},
      );
      if (baseWithName.contains(displayName)) {
        text = baseWithName;
      } else {
        // Final fallback: prepend the name to the (possibly gendered) translation
        text = '$displayName ${typed.trim()}';
      }
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ),
      ],
    );
  }
}
