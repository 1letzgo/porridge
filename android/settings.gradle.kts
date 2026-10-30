pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // sherpa-onnx (Spracherkennung, Sprecher, Satzvektoren) als AAR aus den GitHub-Releases.
        flatDir { dirs("app/libs") }
    }
}
rootProject.name = "porridge"
include(":app")
