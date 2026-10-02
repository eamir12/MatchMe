# Separating Enforcement Mode Per Intent and Feature

This plan outlines the design and implementation details to separate the "Gender & Age Preferences" enforcement mode (Strict vs Flexible) on a per-intent AND per-feature (Gender vs Age) basis, updating the matching logic in Supabase and the user interface in both the Settings and Profile Wizard screens.

## User Review Required

> [!IMPORTANT]
> **Database Schema Migration**: The `strict_gender_age_enforcement` column in the `users` table will be migrated from `BOOLEAN` to `JSONB` to store intent-specific AND feature-specific enforcement values (e.g., `{"romantic": {"gender": true, "age": false}, "friendship": {"gender": false, "age": false}}`). Existing values will be migrated automatically so that users' previous global choices are preserved as defaults for both gender and age across all their active intents.

## Proposed Changes

---

### Backend (Database & Matching Logic)

#### [NEW] [20260701000000_separate_enforcement_mode_per_intent.sql](file:///c:/App/MatchMeGPT5.21/MatchMe4/supabase/migrations/20260701000000_separate_enforcement_mode_per_intent.sql)
- Migration file to:
  1. Alter `users.strict_gender_age_enforcement` to `JSONB` with default `'{}'::jsonb`.
  2. Populate it with existing values mapping active intents and both features (`gender` and `age`) to the old boolean value.
  3. Redefine the `perform_continuous_user_matching` function to fetch and apply intent-specific and feature-specific enforcement logic.
  4. Redefine the `perform_event_matching` function to apply intent-specific and feature-specific enforcement logic.
  5. Implement prioritization logic: a "Flexible" match (matching outside age/gender preferences) will only be allowed between two users for a shared intent if *neither* user has any "Compliant" matching candidate nearby for that intent. A "Compliant" candidate is one that meets both gender and age requirements.

---

### Frontend Models & State Providers

#### [MODIFY] [profile_provider.dart](file:///c:/App/MatchMeGPT5.21/MatchMe4/lib/providers/profile_provider.dart)
- Update `UserProfile.strictGenderAgeEnforcement` type from `bool` to `Map<String, Map<String, bool>>`.
- Update `fromMap` to deserialize a JSONB boolean or JSONB object into `Map<String, Map<String, bool>>` using a new `_mapOfMapOfBools` helper.
- Update `toMap` and `copyWith` to support the new `Map<String, Map<String, bool>>` type.
- Update `updateGenderAgePreferences` and `updateGenderAgePreferencesDraft` signatures and implementations in `profileEditProvider` to pass `Map<String, Map<String, bool>>`.

---

### Frontend UI Screens

#### [MODIFY] [gender_age_preferences_screen.dart](file:///c:/App/MatchMeGPT5.21/MatchMe4/lib/screens/settings/gender_age_preferences_screen.dart)
- Change `_strictEnforcement` value notifier type from `ValueNotifier<bool>` to `ValueNotifier<Map<String, Map<String, bool>>>`.
- Remove the global "Enforcement Mode" card from the top of the list view.
- In `_buildIntentPreferenceCard`, under the Gender Preferences and Age Range sections, add two separate toggle sections:
  1. **Gender Requirements Enforcement**: ChoiceChips ("Flexible" / "Strict").
  2. **Age Requirements Enforcement**: ChoiceChips ("Flexible" / "Strict").
- Bind the state of each choice chip to `_strictEnforcement.value[intentKey]['gender']` and `_strictEnforcement.value[intentKey]['age']` respectively.
- Update `_applyProfilePreferences` and `_savePreferences` to handle the nested map structure correctly.

#### [MODIFY] [profile_wizard_screen.dart](file:///c:/App/MatchMeGPT5.21/MatchMe4/lib/screens/profile/profile_wizard_screen.dart)
- Change `_strictEnforcement` in `_GenderAgePreferencesWizardPageState` from `bool` to `Map<String, Map<String, bool>>`.
- Remove the global "Enforcement Mode" card.
- In the intent-specific preferences loop, render the two ChoiceChip rows ("Flexible" / "Strict" for Gender, and "Flexible" / "Strict" for Age) inside each card.
- Bind them to `_strictEnforcement[intentKey]['gender']` and `_strictEnforcement[intentKey]['age']`.
- Update state synchronization and parent update callbacks.

---

## Verification Plan

### Automated Tests
- Build and run the project locally to ensure compiler and analyzer pass:
  ```powershell
  flutter analyze
  ```

### Manual Verification
1. Open the "Gender & Age Preferences" screen in Settings, select "Strict" gender enforcement but "Flexible" age enforcement for Romantic, and verify that changes persist across page reloads.
2. Complete the Profile Wizard and verify that the initial choices of enforcement mode per intent and per feature are saved correctly.
3. Perform database checks to verify that the `strict_gender_age_enforcement` JSONB column stores intent keys and features correctly.
