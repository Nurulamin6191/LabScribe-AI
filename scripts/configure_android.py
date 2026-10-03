#!/usr/bin/env python3
import os
import re

def configure_android_manifest():
    manifest_path = "android/app/src/main/AndroidManifest.xml"
    if not os.path.exists(manifest_path):
        print(f"Error: {manifest_path} not found.")
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

def configure_app_build_gradle():
    gradle_path = "android/app/build.gradle"
    if not os.path.exists(gradle_path):
        print(f"Error: {gradle_path} not found.")
        return

    with open(gradle_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Update minSdk to 23
    content = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 23', content)
    content = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 23', content)

    # Force compileSdk to 34
    content = re.sub(r'compileSdkVersion\s+flutter\.compileSdkVersion', 'compileSdkVersion 34', content)
    content = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 34', content)
    content = re.sub(r'compileSdkVersion\s+\d+', 'compileSdkVersion 34', content)
    content = re.sub(r'compileSdk\s*=\s*\d+', 'compileSdk = 34', content)
    content = re.sub(r'compileSdk\s+\d+', 'compileSdk 34', content)

    # Ensure debug signingConfig in release build type for installable release APK
    if "signingConfig signingConfigs.debug" not in content and "signingConfig = signingConfigs.debug" not in content:
        if "buildTypes {" in content:
            content = re.sub(
                r'buildTypes\s*\{\s*release\s*\{',
                'buildTypes {\n        release {\n            signingConfig signingConfigs.debug',
                content
            )
            print("Added debug signingConfig to release build type")

    with open(gradle_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("Configured android/app/build.gradle successfully")

def configure_root_build_gradle():
    root_gradle = "android/build.gradle"
    if not os.path.exists(root_gradle):
        print(f"Error: {root_gradle} not found.")
        return

    with open(root_gradle, "r", encoding="utf-8") as f:
        content = f.read()

    # Override compileSdk for all plugin subprojects (e.g. audioplayers_android requires SDK 34)
    override_block = """
subprojects {
    afterEvaluate { project ->
        if (project.hasProperty('android')) {
            project.android {
                compileSdkVersion 34
            }
        }
    }
}
"""
    if "compileSdkVersion 34" not in content:
        content += override_block
        with open(root_gradle, "w", encoding="utf-8") as f:
            f.write(content)
        print("Forced compileSdkVersion 34 for all plugin subprojects in root android/build.gradle")

if __name__ == "__main__":
    configure_android_manifest()
    configure_app_build_gradle()
    configure_root_build_gradle()
