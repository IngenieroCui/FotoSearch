import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}
val configuredNdkPath = localProperties.getProperty("fotosearch.ndkPath")
    ?: providers.gradleProperty("fotosearch.ndkPath").orNull
    ?: System.getenv("ANDROID_NDK_HOME")
val configuredFlutterSdkPath = localProperties.getProperty("flutter.sdk")
    ?: error("Configura flutter.sdk en android/local.properties")

android {
    namespace = "com.example.frontend"
    compileSdk = flutter.compileSdkVersion
    // Usa el NDK r29 instalado manualmente, no la instalación numérica defectuosa.
    ndkVersion = "29.0.14206865"
    ndkPath = configuredNdkPath
        ?: error("Configura fotosearch.ndkPath en android/local.properties o ANDROID_NDK_HOME")

    // Evita que el plugin de Flutter intente provisionar otro NDK mediante
    // sdkmanager durante flutter build appbundle --release.
    externalNativeBuild {
        cmake {
            path = file("$configuredFlutterSdkPath/packages/flutter_tools/gradle/src/main/scripts/CMakeLists.txt")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.frontend"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
