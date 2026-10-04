#!/usr/bin/env python3
import os
import re

def configure_android_manifest():
    manifest_path = "android/app/src/main/AndroidManifest.xml"
    if not os.path.exists(manifest_path):
        print(f"Notice: {manifest_path} not found.")
        return

    with open(manifest_path, "r", encoding="utf-8") as f:
        content = f.read()

    permissions = """
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
"""
    if "<uses-permission android:name=\"android.permission.RECORD_AUDIO\"/>" not in content:
        manifest_tag = re.search(r'<manifest[^>]*>', content)
        if manifest_tag:
            idx = manifest_tag.end()
            content = content[:idx] + permissions + content[idx:]
            print("Injected permissions into AndroidManifest.xml")

    service_decl = """
        <service
            android:name="dev.labscribe.app.AudioRecordingService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="microphone" />
"""
    if "AudioRecordingService" not in content:
        app_close_idx = content.find("</application>")
        if app_close_idx != -1:
            content = content[:app_close_idx] + service_decl + content[app_close_idx:]
            print("Injected AudioRecordingService into AndroidManifest.xml")

    content = re.sub(r'android:label="[^"]*"', 'android:label="LabScribe AI"', content)

    with open(manifest_path, "w", encoding="utf-8") as f:
        f.write(content)

def configure_gradle_properties():
    props_path = "android/gradle.properties"
    content = ""
    if os.path.exists(props_path):
        with open(props_path, "r", encoding="utf-8") as f:
            content = f.read()

    flags = [
        "android.experimental.disableCompileSdkChecks=true",
        "android.suppressUnsupportedCompileSdk=36",
        "android.suppressUnsupportedCompileSdk=35",
    ]
    for flag in flags:
        if flag not in content:
            content += f"\n{flag}\n"
            print(f"Added {flag} to android/gradle.properties")

    with open(props_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("Configured android/gradle.properties successfully")

def configure_app_gradle():
    # Handle Groovy (build.gradle)
    groovy_path = "android/app/build.gradle"
    if os.path.exists(groovy_path):
        with open(groovy_path, "r", encoding="utf-8") as f:
            content = f.read()

        content = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', content)
        content = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', content)
        content = re.sub(r'compileSdkVersion\s+flutter\.compileSdkVersion', 'compileSdkVersion 35', content)
        content = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 35', content)
        content = re.sub(r'compileSdkVersion\s+\d+', 'compileSdkVersion 35', content)
        content = re.sub(r'compileSdk\s*=\s*\d+', 'compileSdk = 35', content)
        content = re.sub(r'compileSdk\s+\d+', 'compileSdk 35', content)

        if "signingConfig signingConfigs.debug" not in content and "signingConfig = signingConfigs.debug" not in content:
            if "buildTypes {" in content:
                content = re.sub(
                    r'buildTypes\s*\{\s*release\s*\{',
                    'buildTypes {\n        release {\n            signingConfig signingConfigs.debug',
                    content
                )
                print("Added debug signingConfig to release build type (Groovy)")

        with open(groovy_path, "w", encoding="utf-8") as f:
            f.write(content)
        print("Configured android/app/build.gradle successfully")

    # Handle Kotlin DSL (build.gradle.kts)
    kts_path = "android/app/build.gradle.kts"
    if os.path.exists(kts_path):
        with open(kts_path, "r", encoding="utf-8") as f:
            content = f.read()

        content = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', content)
        content = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 35', content)
        content = re.sub(r'compileSdk\s*=\s*\d+', 'compileSdk = 35', content)

        if "signingConfig = signingConfigs.getByName(\"debug\")" not in content and "signingConfig = signingConfigs.debug" not in content:
            if "buildTypes {" in content:
                content = re.sub(
                    r'buildTypes\s*\{\s*release\s*\{',
                    'buildTypes {\n        release {\n            signingConfig = signingConfigs.getByName("debug")',
                    content
                )
                print("Added debug signingConfig to release build type (Kotlin DSL)")

        with open(kts_path, "w", encoding="utf-8") as f:
            f.write(content)
        print("Configured android/app/build.gradle.kts successfully")

if __name__ == "__main__":
    configure_android_manifest()
    configure_gradle_properties()
    configure_app_gradle()
