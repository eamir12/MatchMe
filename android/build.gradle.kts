buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// NOTE: do NOT force `split-per-abi` here for APK release builds.
//
// Flutter's plugin reacts to that project property with
// `splits.abi { isUniversalApk = false }`, so it suppresses `app-release.apk`
// entirely and emits only `app-<abi>-release.apk`. The CLI then looks for the
// one name it was told to expect and aborts with "Gradle build failed to
// produce an .apk file" *after* a successful 5-minute build:
//
//   * `flutter run --release` passes `splitPerAbi: false` and a single
//     targetArch (android_device.dart), so it only ever looks for
//     `app-release.apk` — and `flutter run` has no `--split-per-abi` flag, so
//     there is no way to talk it into the per-ABI layout.
//   * `scripts/build_release_local.ps1` builds `--target-platform
//     android-arm64` without `--split-per-abi` and asserts on
//     `flutter-apk\app-release.apk`.
//   * a plain `flutter build apk --release` (all three ABIs) has the same
//     expectation, and is what the docs in this repo tell people to run.
//
// Per-ABI APKs are still one flag away, and that is the supported way to keep
// them small: `flutter build apk --release --split-per-abi` (~88 MB arm64 /
// 81 MB armv7 / 92 MB x86_64 instead of one 121 MB universal APK). App bundles
// are unaffected either way — Play splits those per ABI and per density.

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// Set :app's build dir override *before* the subprojects loop below. Gradle
// evaluates subprojects alphabetically, so any plugin whose name sorts before
// "app" (android_file_picker!) would be evaluated first. The Flutter Gradle
// plugin relies on :app being evaluated before plugin projects: while :app is
// evaluated it creates the "flutter" extension on every plugin project and
// registers afterEvaluate hooks on them (PluginHandler.kt:109/122). A plugin
// evaluated too early fails with "Extension with name 'flutter' does not
// exist" (when its build script reads it) or "Cannot run
// Project.afterEvaluate(Action) when the project is already evaluated" (when
// :app later tries to register the hook). evaluationDependsOn(":app") in the
// loop below forces :app to evaluate first, but it does so *eagerly* — before
// the loop would otherwise reach :app — so :app's build dir must already be
// in place here or AGP/R8 resolve paths against the default
// android/app/build instead of the overridden build/app.
project(":app") {
    layout.buildDirectory.value(newBuildDir.dir("app"))
}

subprojects {
    // Force :app to evaluate before this (plugin) subproject. Excluded for
    // :app itself to avoid a self-dependency. See comment above.
    if (name != "app") {
        evaluationDependsOn(":app")
    }

    layout.buildDirectory.value(newBuildDir.dir(name))

    // Keep Java warning noise down without overriding each plugin's chosen target.
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.addAll(listOf("-Xlint:-options", "-Xlint:-unchecked", "-Xlint:-deprecation"))
    }

    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            // Register Kotlin sources before applying external Kotlin support.
            // A few AGP 9-aware plugins otherwise compile an empty AAR when
            // built-in Kotlin is disabled.
            sourceSets.getByName("main").java.srcDir("src/main/kotlin")
            compileSdk = 36
            // Third-party dependency lint crashes under the AGP 9 toolchain
            // must not block assembling this app's release artifact.
            lint {
                checkReleaseBuilds = false
            }
            if (namespace.isNullOrBlank()) {
                val fallbackGroup = project.group.toString().trim()
                namespace = if (fallbackGroup.isNotEmpty() && fallbackGroup != "unspecified") {
                    fallbackGroup
                } else {
                    "com.matchme.${project.name.replace('-', '_')}"
                }
            }
        }

        // Some AGP 9-aware Flutter plugins omit KGP and expect built-in Kotlin.
        // Built-in Kotlin is disabled until the remaining plugins migrate, so
        // provide the current project KGP consistently to every Android library.
        apply(plugin = "org.jetbrains.kotlin.android")

        // Make late-declared Kotlin folders visible to external KGP as well.
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            source(file("src/main/kotlin"))
        }

        // AGP still creates lintVital tasks for libraries even when release
        // lint checks are disabled. These dependency-only scans crash in AGP 9.
        tasks.matching { it.name.startsWith("lintVital") }.configureEach {
            enabled = false
        }
    }

    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension> {
            if (namespace.isNullOrBlank()) {
                val fallbackGroup = project.group.toString().trim()
                namespace = if (fallbackGroup.isNotEmpty() && fallbackGroup != "unspecified") {
                    fallbackGroup
                } else {
                    "com.matchme.${project.name.replace('-', '_')}"
                }
            }
        }
    }


}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
