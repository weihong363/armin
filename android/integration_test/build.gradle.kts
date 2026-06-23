// Flutter integration_test Android build file.
// Explicitly declares both android library and kotlin-android plugins
// so that Flutter's detectApplyingKotlinGradlePlugin won't auto-inject KGP
// before the Android plugin is ready.

buildscript {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.flutter.integration_test"
    compileSdk = 35

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    dependencies {
        testImplementation("junit:junit:${providers.gradleProperty("junitVersion").get()}")
        testImplementation("org.mockito:mockito-core:${providers.gradleProperty("mockitoVersion").get()}")
        api("androidx.test:runner:${providers.gradleProperty("androidxTestRunnerVersion").get()}")
        api("androidx.test:rules:${providers.gradleProperty("androidxTestRulesVersion").get()}")
        api("androidx.test.espresso:espresso-core:${providers.gradleProperty("androidxEspressoCoreVersion").get()}")
        implementation("com.google.guava:guava:${providers.gradleProperty("guavaVersion").get()}")
    }
}
