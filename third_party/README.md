# third_party — vendored plugin forks

Each folder here is a **verbatim copy of a pub.dev package** (including its
`example/`, `test/`, and licenses) with **minimal, documented patches**, wired
into the app via `dependency_overrides` in the root `pubspec.yaml`.

They are excluded from the root analyzer/formatter (`analysis_options.yaml`):
treat them as third-party code, not app code.

## Why they exist

| Fork | Upstream | Reason | Revisit when |
| --- | --- | --- | --- |
| `flutter_tts` | 4.2.5 | KGP removal (Built-in Kotlin); earlier web/Windows fixes | upstream ships KGP-free Android build + fixes |
| `passkeys_android` | 2.12.0 | Android/Java + Gradle fixes (prior sessions) | upstream release contains the fixes |
| `realtime_client` | 2.13.0 | FCM push pipeline fix (commit `863b6b6`) | upstream ships the fix |
| `webview_windows` | 0.4.0 | CMake `CMP0175` + webview fixes | new upstream release verified |
| `msal_auth` | 3.5.3 | `kotlin-android` applied unconditionally (unconditional in `plugins {}`); trips Flutter's KGP warning and would break under `android.builtInKotlin=true` | upstream applies Kotlin conditionally or via Built-in Kotlin |
| `aad_oauth` | 1.0.1 | Two patches for `flutter_secure_storage`: constraint `^9.0.0` → `^11.0.0`, and `config.dart`'s default `AndroidOptions(encryptedSharedPreferences: true)` → `AndroidOptions()` (parameter removed in FSS v11). Needed by Microsoft calendar OAuth (`calendar_sync_service.dart`) | upstream bumps FSS to ^11 |
| `android_file_picker` | 1.1.1 | `extensions.getByName("flutter")` throws when Gradle evaluates this plugin *before* `:app` (alphabetical project order: `android_file_picker` < `app`); patched to `findByName` + fallback `compileSdk = 36`. Also see the `evaluationDependsOn(":app")` fix in `android/build.gradle.kts` — it guarantees `:app` (which creates the `flutter` extension and registers `afterEvaluate` hooks on plugin projects) evaluates first | upstream guards the lookup |
| `emoji_picker_flutter` | 4.5.4 | Applies `kotlin-android` inside a conditional; Flutter's regex still flags it (conditionals are ignored). One-line deletion, root shim supplies KGP | upstream removes the textual apply or Flutter's scanner learns conditionals |
| `firebase_core` | 5.0.0 | Same pattern: `if (agpMajor < 9 \|\| !builtInKotlin) { apply ... }` — conditional, still flagged. Deleted the whole block (its vars were unused elsewhere) | upstream removes the textual apply |
| `purchases_ui_flutter` | 10.15.2 | Same pattern: `if (findByName('kotlin') == null) { apply ... }` — conditional, still flagged. One-line deletion | upstream removes the textual apply |
| `shared_preferences_android` | 2.4.28 | Serializes migrated legacy StringSets as Java `ArrayList`, safely accepts the old Kotlin empty-list singleton representation, and drops only unreadable legacy serialized-list preferences so they cannot block startup | upstream fixes empty-list serialization and corrupt legacy-value handling |

Historical forks **deleted** once the `win32 ^6` wall fell (FSS 10 upgrade):
`device_info_plus` (→ 13.3.0), `package_info_plus` (→ 10.2.2), `share_plus`
(→ 13.3.1), `file_picker` (→ 12.3.0, plus Dart call sites migrated to
`readAsBytes()`/`length()` — platform_interface 3.4.0 removed `bytes`/`size`).

## KGP / Built-in Kotlin context

Flutter 3.47's `detectApplyingKotlinGradlePlugin`
(`packages/flutter_tools/gradle/.../FlutterPluginUtils.kt:568`) warns on
AGP ≥ 9 for every plugin whose **build file textually declares** an imperative
KGP apply (`apply plugin: 'kotlin-android'` / kts `plugins { id(...) }`),
regardless of conditionals, and there is **no opt-out**. Future Flutter will
fail these builds.

The app runs `android.builtInKotlin=false` with a root shim
(`android/build.gradle.kts`) that applies `org.jetbrains.kotlin.android` to
every `com.android.library` subproject. All KGP-removal patches above rely on
that shim: only the plugin's own KGP declaration is removed; nothing else in
the build file changes. A **full Built-in-Kotlin migration** (drop the shim,
set `android.builtInKotlin=true`) is a separate follow-up and will need each
remaining plugin to ship a compatible release.

All three previously flagged plugins are now forked (table above), so the
resolved build flags **0** plugins. Note their upstream versions already
guarded the *runtime* apply — Flutter's check is a pure text regex
(`kgpRegexGroovy`/`kgpRegexKotlin`) that ignores `if`-conditions, so even a
correctly-conditional `apply plugin: 'kotlin-android'` line trips it. The fix
is always the same: delete the line, rely on the root shim. The app's own
release build log contains no KGP warning (verified 2026-10).

## Gradle evaluation order (plugin < "app")

Gradle evaluates subprojects alphabetically. Plugin build scripts historically
read the `flutter` extension (`flutter.compileSdkVersion` /
`extensions.getByName("flutter")`) that FlutterPlugin creates on each plugin
project *during* `:app` evaluation (`PluginHandler.kt:109`), and `:app` also
registers `afterEvaluate` hooks on them (`PluginHandler.kt:122`). Every plugin
name used to sort after `app`, so this always worked. `android_file_picker`
was the first to sort before `app`, which surfaced two failures:

1. Its build script read `flutter` before it existed → fixed by the fork
   (`findByName` + fallback).
2. `:app`'s `pluginProject.afterEvaluate` ran on an already-evaluated project
   → fixed in `android/build.gradle.kts` by `evaluationDependsOn(":app")` on
   every plugin subproject, with `:app`'s build-dir override hoisted *above*
   the loop (the eager evaluation would otherwise capture the default
   `android/app/build` path and break R8's default proguard file lookup).

## Re-sync procedure (per fork)

```pwsh
$cache = "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"
# 1. see what we changed:
robocopy "$cache\<pkg>-<ver>" "third_party\<pkg>" /L /S /NJH /NJS /NDL /NP /XJ
# 2. bump: copy the new upstream version into a temp dir, re-apply the patches
#    listed above (they are one-to-few lines each), replace the folder.
# 3. flutter pub get && flutter build apk --release
```

Never edit a fork without updating this table and the comment next to its
`dependency_overrides` entry in `pubspec.yaml`.
