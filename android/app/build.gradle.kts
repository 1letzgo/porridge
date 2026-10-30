import java.net.URI
import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
}

fun gitCommitCount(): Int = runCatching {
    providers.exec { commandLine("git", "rev-list", "--count", "HEAD") }.standardOutput.asText.get().trim().toInt()
}.getOrDefault(1)

/** Eine Versionsquelle für alle Plattformen: `MARKETING_VERSION` aus `project.yml` (wie scripts/release-mac.sh). */
fun marketingVersion(): String = runCatching {
    val yml = rootProject.file("../project.yml").readText()
    Regex("""(?m)^\s*MARKETING_VERSION:\s*([^\s#]+)""").find(yml)!!.groupValues[1].trim()
}.getOrDefault("0.0.0")

android {
    namespace = "de.letzgo.porridge"
    compileSdk = 36
    defaultConfig {
        applicationId = "de.letzgo.porridge"
        minSdk = 26
        targetSdk = 36
        // Monoton ohne manuelles Hochzählen: Anzahl Commits (-PporridgeVersionCode=… überschreibt).
        versionCode = (project.findProperty("porridgeVersionCode") as String?)?.toIntOrNull() ?: gitCommitCount()
        versionName = marketingVersion()
    }
    // Verteilung: `sideload` = APK als GitHub-Release mit Update-Prüfung in der App (Tag android-v<version>),
    // `play` = Google Play (vorbereitet), aktualisiert selbst.
    flavorDimensions += "distribution"
    productFlavors {
        create("sideload") { dimension = "distribution"; buildConfigField("Boolean", "SIDELOAD", "true") }
        create("play") { dimension = "distribution"; buildConfigField("Boolean", "SIDELOAD", "false") }
    }
    sourceSets {
        // Golden-Files, die iOS und Android gemeinsam nutzen (gleiche Logik beweisen).
        getByName("test").resources.srcDir("../../shared/fixtures")
    }
    // Ein eigener Schlüssel außerhalb von Repo und iCloud (wie stede). Er darf sich nie ändern, sonst lehnt
    // Android Updates ab. Ohne die Datei sind Release-Builds unsigniert.
    val signingFile = file("${System.getProperty("user.home")}/Library/Application Support/porridge-signing/keystore.properties")
    signingConfigs {
        if (signingFile.exists()) create("upload") {
            val props = Properties().apply { signingFile.inputStream().use { load(it) } }
            storeFile = file(props.getProperty("storeFile"))
            storePassword = props.getProperty("storePassword")
            keyAlias = props.getProperty("keyAlias")
            keyPassword = props.getProperty("keyPassword")
        }
    }
    buildTypes {
        // Debug mit demselben Schlüssel, damit Debug- und Release-APKs übereinander installieren.
        debug { signingConfigs.findByName("upload")?.let { signingConfig = it } }
        release {
            signingConfigs.findByName("upload")?.let { signingConfig = it }
            // Die nativen ML-Bibliotheken (sherpa-onnx, llama.cpp) gibt es sinnvoll nur für 64 Bit.
            ndk { abiFilters += listOf("arm64-v8a") }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    packaging { jniLibs { useLegacyPackaging = true; pickFirsts += "**/libc++_shared.so" } }
    testOptions { unitTests.isReturnDefaultValues = true }
}

ksp { arg("room.schemaLocation", "$projectDir/schemas") }

// sherpa-onnx (Spracherkennung, Sprecher) als AAR aus den GitHub-Releases: 49 MB, daher nicht im Repo, sondern beim
// ersten Build geladen und gegen die Prüfsumme geprüft.
val sherpaVersion = "2.0.1"
val sherpaSha256 = "a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7"
val sherpaAar = file("libs/sherpa-onnx-$sherpaVersion.aar")
fun sha256(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
if (!sherpaAar.exists() || sha256(sherpaAar) != sherpaSha256) {
    sherpaAar.parentFile.mkdirs()
    val part = File(sherpaAar.path + ".part")
    URI("https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpaVersion/sherpa-onnx-$sherpaVersion.aar").toURL()
        .openStream().use { input -> part.outputStream().use { input.copyTo(it) } }
    check(sha256(part) == sherpaSha256) { "sherpa-onnx AAR: wrong checksum" }
    part.renameTo(sherpaAar)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.animation:animation")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-cbor:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    val room = "2.6.1"
    implementation("androidx.room:room-runtime:$room")
    implementation("androidx.room:room-ktx:$room")
    ksp("androidx.room:room-compiler:$room")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation(files("libs/sherpa-onnx-$sherpaVersion.aar"))
    // llama.cpp (Zusammenfassungen, Chat, Satzvektoren auf dem Gerät), nur arm64.
    implementation("dev.ffmpegkit-maintained:llama-android:0.1.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.3.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}
