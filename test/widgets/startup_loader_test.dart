import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/startup_loader.dart';
import 'package:matchme/providers/locale_provider.dart';

void main() {
  testWidgets('startup loader uses the active theme surface', (tester) async {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    );

    await tester.pumpWidget(
      MaterialApp(theme: theme, home: const StartupLoaderScaffold()),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, theme.colorScheme.surface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup loader renders with reduced motion enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const StartupLoaderScaffold(),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(StartupLoaderScaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup loader shows the tagline under the logo', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: StartupLoaderScaffold()));

    expect(find.text('Connecting people, naturally!'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup loader tagline follows the loaded translations', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(
            LocalizationState.loading().copyWith(
              strings: const {'appTagline': 'Connecting people, organically!'},
              dbKeys: const {'appTagline'},
            ),
          ),
        ],
        child: const MaterialApp(home: StartupLoaderScaffold()),
      ),
    );

    expect(find.text('Connecting people, organically!'), findsOneWidget);
  });

  test('startup tagline has a built-in localization fallback', () {
    final l10n = LocalizationState.loading();
    expect(l10n.getString('appTagline'), 'Connecting people, naturally!');
  });

  testWidgets('skeleton placeholder renders with reduced motion enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: AppSkeletonList(itemCount: 2)),
      ),
    );

    expect(find.byType(AppSkeletonBox), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('skeleton list can expose an announced loading label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppSkeletonList(itemCount: 2, semanticLabel: 'Loading…'),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Loading…'), findsOneWidget);
  });

  test('Home closure copy has a built-in localization fallback', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('homeAllCaughtUp'),
      'You’re all caught up — MatchMe is working in the background.',
    );
  });

  test('Chats recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(l10n.getString('chatsBrowseMatches'), 'Browse Matches');
    expect(
      l10n.getString('chatsLoadErrorMessage'),
      'We couldn’t load your conversations. Try again.',
    );
    expect(l10n.getString('chatsUnreadOnly'), 'Unread only');
    expect(
      l10n.getString('chatsUnreadOnlyWithCount', params: {'count': '3'}),
      'Unread only (3)',
    );
    expect(
      l10n.getString('chatsResultsCount', params: {'count': '3'}),
      '3 conversations',
    );
    expect(
      l10n.getString('chatsUnreadMessages', params: {'count': '3'}),
      '3 unread messages',
    );
    expect(l10n.getString('chatsNoUnreadResults'), 'No unread conversations');
  });

  test('Nearby recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(l10n.getString('nearbyLocationLoading'), 'Finding your location…');
    expect(
      l10n.getString('nearbyLocationUnavailableTitle'),
      'We couldn’t find your location',
    );
    expect(
      l10n.getString('nearbyProfileErrorMessage'),
      'We couldn’t load your matching radius. Try again.',
    );
    expect(
      l10n.getString('nearbyLocationOfflineMessage'),
      'Reconnect to load the Nearby Map.',
    );
    expect(
      l10n.getString('networkErrorNoInternet'),
      'No internet connection. Please check your network and try again.',
    );
    expect(
      l10n.getString('networkErrorTimeout'),
      'The request timed out. Please check your internet connection and try again.',
    );
    expect(l10n.getString('generalError'), 'Something went wrong');
  });

  test('Location sharing consent copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('locationShareRecipientNotice', params: {'name': 'Alex'}),
      'You’re sharing your live location with Alex.',
    );
    expect(
      l10n.getString('locationShareIndefiniteTitle'),
      'Share until turned off?',
    );
  });

  test(
    'Background Matching status copy has built-in localization fallbacks',
    () {
      final l10n = LocalizationState.loading();
      expect(
        l10n.getString('settingsBackgroundStatusOnTitle'),
        'Background Matching is on',
      );
      expect(
        l10n.getString('settingsBackgroundStatusPermissionTitle'),
        'Permission needed',
      );
      expect(
        l10n.getString('settingsBackgroundStatusWebTitle'),
        'Unavailable on web',
      );
    },
  );

  test('Events recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('eventLoadErrorTitle'),
      'We couldn’t load your events',
    );
    expect(l10n.getString('eventMoreActions'), 'More actions');
    expect(
      l10n.getString(
        'eventMatchesTitle',
        params: {'eventName': 'Rooftop Mixer'},
      ),
      'Rooftop Mixer Matches',
    );
    expect(
      l10n.getString('eventRsvpAttending'),
      'You’re listed as attending on MatchMe',
    );
    expect(
      l10n.getString('eventAttendeeCountIncludingYou', params: {'count': '3'}),
      '3 attending, including you',
    );
    expect(
      l10n.getString('eventMatchedAttendeesOnly'),
      'Only your event matches are shown—not the full attendee list.',
    );
    expect(l10n.getString('eventLeave'), 'Leave event');
  });

  test(
    'Profile recovery and photo labels have built-in localization fallbacks',
    () {
      final l10n = LocalizationState.loading();
      expect(
        l10n.getString('profileLoadErrorTitle'),
        'We couldn’t load your profile',
      );
      expect(
        l10n.getString('profilePhotoPreviewLabel', params: {'index': '1'}),
        'Photo 1',
      );
      expect(
        l10n.getString('profileSyncStaleTitle'),
        'Profile data may be out of date',
      );
      expect(
        l10n.getString('profileSyncStaleMessage'),
        'We couldn’t refresh your profile. Showing the last saved version.',
      );
    },
  );

  testWidgets('profile load recovery exposes its retry action', (tester) async {
    var retried = false;
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppEmptyState(
            icon: Icons.person_off_outlined,
            title: l10n.getString('profileLoadErrorTitle'),
            message: l10n.getString('profileLoadErrorMessage'),
            actionLabel: l10n.getString('generalRetry'),
            onAction: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('We couldn’t load your profile'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  test(
    'Profile verification action copy has built-in localization fallbacks',
    () {
      final l10n = LocalizationState.loading();
      expect(l10n.getString('notVerified'), 'Not Verified');
      expect(l10n.getString('verificationReview'), 'Verification Review');
      expect(l10n.getString('verifyNow'), 'Verify Now');
    },
  );

  test('Profile wizard recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('profileWizardErrorLoadingIntents'),
      'Error loading intents',
    );
    expect(
      l10n.getString('profileWizardRecoveryMessage'),
      'Your progress is still here. Check your connection and try again.',
    );
    expect(
      l10n.getString('profileWizardReferenceDataErrorMessage'),
      'We couldn’t load the profile options. Try again.',
    );
  });

  test('Matches filter recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('matchesNoIntentResults'),
      'No matches for this connection type',
    );
    expect(
      l10n.getString('matchesNoIntentResultsMessage'),
      'Try another connection type or clear the filter to see all matches.',
    );
    expect(l10n.getString('matchesClearFilters'), 'Clear filters');
  });

  test('Chat accessibility copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(l10n.getString('chatSendMessage'), 'Send message');
    expect(l10n.getString('chatEmojiPicker'), 'Emoji picker');
    expect(l10n.getString('chatMessageStatusQueued'), 'Message queued');
    expect(l10n.getString('chatSafetyActions'), 'Safety actions');
    expect(
      l10n.getString('blockConfirm'),
      'Blocking removes this account from your matches and chats. This does not submit a report.',
    );
    expect(l10n.getString('reportSubmit'), 'Submit report');
    expect(l10n.getString('reportSuccess'), 'Report submitted');
  });

  test('Settings recovery copy has built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('settingsLoadErrorTitle'),
      'We couldn’t load Settings',
    );
    expect(
      l10n.getString('settingsProfileUnavailableTitle'),
      'Profile settings unavailable',
    );
  });

  test('Settings search descriptions have built-in localization fallbacks', () {
    final l10n = LocalizationState.loading();
    expect(
      l10n.getString('settingsAppDisplayDesc'),
      'Adjust language, currency, units, time format, and theme.',
    );
    expect(
      l10n.getString('settingsAccountManagementDesc'),
      'Change your password, update your email, or delete your account.',
    );
  });

  testWidgets('matches filter empty state exposes its clear action', (
    tester,
  ) async {
    var cleared = false;
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppEmptyState(
            icon: Icons.filter_alt_off_rounded,
            title: l10n.getString('matchesNoIntentResults'),
            message: l10n.getString('matchesNoIntentResultsMessage'),
            actionLabel: l10n.getString('matchesClearFilters'),
            onAction: () => cleared = true,
          ),
        ),
      ),
    );

    expect(find.text('No matches for this connection type'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    expect(cleared, isTrue);
  });

  testWidgets('home filter empty states keep section actions independent', (
    tester,
  ) async {
    var matchesCleared = false;
    var chatsCleared = false;
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppEmptyState(
                  icon: Icons.filter_alt_off_rounded,
                  title: l10n.getString('matchesNoIntentResults'),
                  message: l10n.getString('matchesNoIntentResultsMessage'),
                  actionLabel: l10n.getString('matchesClearFilters'),
                  onAction: () => matchesCleared = true,
                ),
                AppEmptyState(
                  icon: Icons.filter_alt_off_rounded,
                  title: l10n.getString('chatsNoIntentResults'),
                  message: l10n.getString('chatsNoIntentResultsMessage'),
                  actionLabel: l10n.getString('chatsClearFilters'),
                  onAction: () => chatsCleared = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Clear filters').first);
    expect(matchesCleared, isTrue);
    expect(chatsCleared, isFalse);
    await tester.ensureVisible(find.text('Clear filters').last);
    await tester.tap(find.text('Clear filters').last);
    expect(chatsCleared, isTrue);
  });

  testWidgets('empty state exposes its message and action', (tester) async {
    var actionPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppEmptyState(
            icon: Icons.people_outline,
            title: 'No matches',
            message: 'Try again later.',
            actionLabel: 'Retry',
            onAction: () => actionPressed = true,
          ),
        ),
      ),
    );

    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(actionPressed, isTrue);
  });
}
