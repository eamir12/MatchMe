allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")

    // Suppress verbose obsolete 'source/target 8' warnings coming from some older dependencies
    // and ensure Kotlin JVM target is set consistently for the build.
    tasks.withType<JavaCompile>().configureEach {
        // Suppress the 'options' lint which complains about obsolete source/target settings in some libs
        options.compilerArgs.addAll(listOf("-Xlint:-options", "-Xlint:-unchecked"))
        // Default Java source/target to 17 so JavaCompile tasks align with AGP/JBR defaults
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        // Dynamically match the Kotlin jvmTarget to the module's JavaCompile targetCompatibility when possible.
        val javaTaskName = name.replace("Kotlin", "JavaWithJavac")
        val javaCompile = project.tasks.findByName(javaTaskName) as? JavaCompile
        kotlinOptions {
            jvmTarget = javaCompile?.targetCompatibility ?: JavaVersion.VERSION_17.toString()
        }
    }

    // Ensure Java/Kotlin compilation alignment across Android subprojects.
    // NOTE: Do NOT use `options.release` (the `--release` flag) because the Android Gradle
    // Plugin rejects it for JavaCompile tasks; instead set source/target compatibility or use
    // the Java toolchain so libraries/plugins compile consistently.
    subprojects {
        // Configure Android modules after they've been evaluated so their android extension exists.
        plugins.withId("com.android.library") {
            // Ensure all Android library modules (including third-party plugins) have a namespace
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                if (namespace == null || namespace!!.isEmpty()) {
                    namespace = project.group.toString()
                }
            }
            afterEvaluate {
                extensions.configure<com.android.build.gradle.LibraryExtension> {
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
        }
        plugins.withId("com.android.application") {
            afterEvaluate {
                extensions.configure<com.android.build.gradle.AppExtension> {
                    if (namespace == null || namespace!!.isEmpty()) {
                        namespace = project.group.toString()
                    }
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
        }

        // Also set JavaCompile source/target in case a plugin doesn't set them itself.
        // Doing this in afterEvaluate ensures it applies after plugins have configured their tasks.
        afterEvaluate {
            tasks.withType<JavaCompile>().configureEach {
                sourceCompatibility = JavaVersion.VERSION_17.toString()
                targetCompatibility = JavaVersion.VERSION_17.toString()
            }

            // Match Kotlin's jvmTarget to the corresponding JavaCompile target when possible.
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                val javaTaskName = name.replace("Kotlin", "JavaWithJavac")
                val javaCompile = project.tasks.findByName(javaTaskName) as? JavaCompile
                kotlinOptions {
                    jvmTarget = javaCompile?.targetCompatibility ?: JavaVersion.VERSION_17.toString()
                }
            }
        }
    }
}

// Note: configuring the Kotlin JVM toolchain globally caused finalization errors in some
// plugin configurations. For now, we align Kotlin's jvmTarget and Android compileOptions to
// Java 11 (see above) which avoids the mismatches while keeping builds stable.
// If needed later, we can opt into per-module `kotlin { jvmToolchain { ... } }` changes.

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
