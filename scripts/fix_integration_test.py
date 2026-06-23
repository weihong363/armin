#!/usr/bin/env python3
"""Add Aliyun mirrors to Flutter SDK integration_test Android build file."""
import os

# Read AGP version from project gradle.properties
props_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'android', 'gradle.properties')
agp_version = '8.11.0'  # fallback default
with open(props_path, 'r') as f:
    for line in f:
        line = line.strip()
        if line.startswith('agpVersion='):
            agp_version = line.split('=', 1)[1].strip()
            break

path = '/Users/ironion/develop/flutter/packages/integration_test/android/build.gradle.kts'
with open(path, 'r') as f:
    content = f.read()

# Fix 1: buildscript repositories
old_bs = f'''buildscript {{
    repositories {{
        google()
        mavenCentral()
    }}

    dependencies {{
        classpath("com.android.tools.build:gradle:{agp_version}")
    }}
}}'''

new_bs = f'''buildscript {{
    repositories {{
        maven {{ url = uri("https://maven.aliyun.com/repository/google") }}
        maven {{ url = uri("https://maven.aliyun.com/repository/public") }}
        maven {{ url = uri("https://maven.aliyun.com/repository/gradle-plugin") }}
        google()
        mavenCentral()
    }}

    dependencies {{
        classpath("com.android.tools.build:gradle:{agp_version}")
    }}
}}'''

if old_bs in content:
    content = content.replace(old_bs, new_bs)
    print("Fixed buildscript repositories")
else:
    print("buildscript pattern not found (may already be fixed)")

# Fix 2: rootProject.allprojects repositories
old_rp = '''rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}'''

new_rp = '''rootProject.allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}'''

if old_rp in content:
    content = content.replace(old_rp, new_rp)
    print("Fixed rootProject.allprojects repositories")
else:
    print("rootProject.allprojects pattern not found (may already be fixed)")

with open(path, 'w') as f:
    f.write(content)
print("Done")