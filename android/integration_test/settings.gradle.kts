// Minimal settings for integration_test subproject.
pluginManagement {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.library") version providers.gradleProperty("agpVersion").get() apply false
    id("org.jetbrains.kotlin.android") version providers.gradleProperty("kotlinVersion").get() apply false
}

rootProject.name = "integration_test"
