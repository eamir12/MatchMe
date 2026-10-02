// lib/widgets/event_matched_attendees.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/events/attendees_screen.dart'
    show eventMatchesProvider;
import 'package:matchme/widgets/signed_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Renders the users the current user matched with at [event] as an
/// overlapping avatar row with a count label. Shrinks to nothing when the
/// event has no matches yet or the match data is still loading.
class EventMatchedAttendees extends ConsumerWidget {
  final EventModel event;
  final LocalizationState l10n;
  final int maxAvatars;

  const EventMatchedAttendees({
    super.key,
    required this.event,
    required this.l10n,
    this.maxAvatars = 5,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(eventMatchesProvider(event));

    return matchesAsync.when(
      data: (matches) {
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        final otherUserIds = <String>{};
        for (final match in matches) {
          final user1Id = match['user1_id'] as String?;
          final user2Id = match['user2_id'] as String?;
          final String? otherUserId;
          if (user1Id == currentUserId) {
            otherUserId = user2Id;
          } else if (user2Id == currentUserId) {
            otherUserId = user1Id;
          } else {
            otherUserId = null;
          }
          if (otherUserId != null && otherUserId.isNotEmpty) {
            otherUserIds.add(otherUserId);
          }
        }
        if (otherUserIds.isEmpty) return const SizedBox.shrink();

        final visibleIds = otherUserIds.take(maxAvatars).toList();
        final hiddenCount = otherUserIds.length - visibleIds.length;

        const avatarSize = 28.0;
        const overlap = 8.0;
        final stackWidth =
            avatarSize +
            (visibleIds.length - 1 + (hiddenCount > 0 ? 1 : 0)) *
                (avatarSize - overlap);

        final avatarStack = SizedBox(
          width: stackWidth,
          height: avatarSize,
          child: Stack(
            children: [
              for (var i = 0; i < visibleIds.length; i++)
                Positioned(
                  left: i * (avatarSize - overlap),
                  top: 0,
                  child: _MatchedAttendeeAvatar(
                    userId: visibleIds[i],
                    size: avatarSize,
                  ),
                ),
              if (hiddenCount > 0)
                Positioned(
                  left: visibleIds.length * (avatarSize - overlap),
                  top: 0,
                  child: Container(
                    width: avatarSize,
                    height: avatarSize,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 2,
                      ),
                    ),
                    child: Text(
                      '+$hiddenCount',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            textDirection: l10n.textDirection,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatarStack,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString(
                    'eventMatchedAttendeesCount',
                    params: {'count': otherUserIds.length.toString()},
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => const SizedBox.shrink(),
    );
  }
}

class _MatchedAttendeeAvatar extends ConsumerWidget {
  final String userId;
  final double size;

  const _MatchedAttendeeAvatar({required this.userId, required this.size});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(userProfileProvider(userId));
    final colorScheme = Theme.of(context).colorScheme;
    final fallbackIcon = Icon(
      Icons.person,
      size: size * 0.6,
      color: colorScheme.primary,
    );

    return Container(
      width: size,
      height: size,
      // Surface-colored ring keeps overlapping avatars visually separated.
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.surface, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: profileAsync.when(
        data: (profile) {
          final photo = (profile?.photos.isNotEmpty == true)
              ? profile!.photos.first
              : null;
          if (photo == null) return fallbackIcon;
          return SignedImage(
            source: photo,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: Center(
              child: SizedBox(
                width: size * 0.5,
                height: size * 0.5,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
            errorWidget: fallbackIcon,
          );
        },
        loading: () => fallbackIcon,
        error: (error, stack) => fallbackIcon,
      ),
    );
  }
}
