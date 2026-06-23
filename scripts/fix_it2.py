#!/usr/bin/env python3
import re
import os

# Read versions from project gradle.properties
props_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'android', 'gradle.properties')
versions = {}
with open(props_path, 'r') as f:
    for line in f:
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            key, val = line.split('=', 1)
            versions[key.strip()] = val.strip()

runner_ver = versions.get('androidxTestRunnerVersion', '1.6.2')
rules_ver = versions.get('androidxTestRulesVersion', '1.6.2')
espresso_ver = versions.get('androidxEspressoCoreVersion', '3.6.1')

path = '/Users/ironion/develop/flutter/packages/integration_test/android/build.gradle.kts'
with open(path, 'r') as f:
    content = f.read()

# Replace rootProject.allprojects with direct repositories
old_rp = 'rootProject.allprojects {\n    repositories {\n        maven { url = uri("https://maven.aliyun.com/repository/google") }\n        maven { url = uri("https://maven.aliyun.com/repository/public") }\n        google()\n        mavenCentral()\n    }\n}'

new_rp = 'repositories {\n    maven { url = uri("https://maven.aliyun.com/repository/google") }\n    maven { url = uri("https://maven.aliyun.com/repository/public") }\n    google()\n    mavenCentral()\n}'

if old_rp in content:
    content = content.replace(old_rp, new_rp)
    print("Replaced rootProject.allprojects with direct repositories")
else:
    print("old_rp NOT FOUND!")
    # Check what's there
    idx = content.find('rootProject')
    if idx >= 0:
        print("Found rootProject at index", idx)
        print(repr(content[idx:idx+200]))

# Fix dynamic versions - replace "+" ranges with specific versions from gradle.properties
def replace_dynamic_version(content, artifact, pinned_version):
    pattern = re.compile(
        r'api\("' + re.escape(artifact) + r':[^"]*\+"'
        + r'|api\("' + re.escape(artifact) + r':\d+\.\d+\+"\)'
    )
    replacement = 'api("' + artifact + ':' + pinned_version + '")'
    new_content, count = pattern.subn(replacement, content)
    if count > 0:
        print(f"Fixed {artifact} version to {pinned_version}")
    else:
        print(f"{artifact} dynamic version pattern not found")
    return new_content

content = replace_dynamic_version(content, 'androidx.test:runner', runner_ver)
content = replace_dynamic_version(content, 'androidx.test:rules', rules_ver)
content = replace_dynamic_version(content, 'androidx.test.espresso:espresso-core', espresso_ver)

with open(path, 'w') as f:
    f.write(content)
print("Done - wrote file")