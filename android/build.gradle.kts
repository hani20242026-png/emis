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

// Some Flutter Android plugins (notably file_picker) declare an older
// compileSdk in their own Gradle files. Their dependencies can require API 36,
// so align every Android library module with the application's compileSdk.
// This does not change targetSdk, minSdk, or runtime behavior.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            compileSdk = 36
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
