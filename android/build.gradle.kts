allprojects {
    // llamafu 0.1.0's Android build.gradle references the legacy
    // `kotlin_version` project property when declaring kotlin-stdlib.
    // The app declares Kotlin through the plugins DSL in settings.gradle.kts,
    // so expose the same version to every Android subproject/plugin.
    extensions.extraProperties.set("kotlin_version", "2.4.0")

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

// Enforce API 36 after each Android library plugin has completed its own
// Gradle configuration. Some Flutter plugins (including file_picker 8.x)
// overwrite compileSdk during their build-script evaluation; configuring
// LibraryExtension only when the plugin is first applied is therefore too
// early. This changes compileSdk only, not minSdk or targetSdk.
subprojects {
    plugins.withId("com.android.library") {
        afterEvaluate {
            extensions.findByType<com.android.build.api.dsl.LibraryExtension>()
                ?.compileSdk = 36
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
