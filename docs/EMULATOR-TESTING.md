# Android Emulator Testing

This project includes command-line scripts for launching an Android Emulator,
installing the Armin debug APK, checking network access, and running a basic
smoke test against a local Bridge service.

## Requirements

Install Android Studio or the Android SDK command-line tools. The scripts do
not require the Android Studio GUI once the SDK is installed.

Required tools:

- `emulator`
- `adb`
- `avdmanager`
- Android SDK Platform Tools
- Android Emulator package
- Android system image for the AVD you want to run

Set one of these environment variables if the tools are not already on `PATH`:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
```

On macOS, the default Android Studio SDK path is usually
`$HOME/Library/Android/sdk`.

## Create the AVD

Install the Android 35 Google APIs x86_64 system image, then create the default
test emulator:

```sh
avdmanager create avd \
  -n armin_test \
  -k "system-images;android-35;google_apis;x86_64" \
  -d pixel_6
```

The scripts default to `AVD_NAME=armin_test`. Override it when needed:

```sh
AVD_NAME=my_avd make emulator-start
```

## Start the Emulator

```sh
make emulator-start
make emulator-ready
```

For headless runs:

```sh
HEADLESS=true make emulator-start
make emulator-ready
```

Check connected devices:

```sh
adb devices
```

If more than one device is attached, set `DEVICE_ID`:

```sh
DEVICE_ID=emulator-5554 make emulator-ready
```

## Bridge Networking

Android Emulator cannot reach the host machine with `localhost`. Use
`10.0.2.2` instead.

Default Bridge health URL:

```text
http://10.0.2.2:8080/health
```

Override the Bridge port:

```sh
BRIDGE_PORT=9090 make emulator-check-network
```

The base host URL for the app should use:

```text
http://10.0.2.2:8080
```

## Install the APK

Build or provide an APK. If `APK_PATH` is not set, the install script uses the
Flutter default debug output:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Install it:

```sh
make emulator-install
```

Or use a custom APK:

```sh
APK_PATH=/path/to/app-debug.apk make emulator-install
```

## Run a Full Smoke Test

Start your local Bridge service first. It must answer:

```text
http://localhost:8080/health
```

Then run:

```sh
flutter build apk --debug
HEADLESS=true BRIDGE_PORT=8080 make emulator-smoke-test
```

The smoke test performs:

1. Start the configured AVD.
2. Wait for `adb` and `sys.boot_completed=1`.
3. Unlock the screen and keep it awake.
4. Check public network access.
5. Check Bridge health at `http://10.0.2.2:8080/health`.
6. Install the Armin APK.
7. Launch Armin with `adb shell monkey`.

## Reset the App

Clear Armin app data:

```sh
make emulator-reset
```

Clear and uninstall:

```sh
UNINSTALL=true make emulator-reset
```

The default package name is `com.ironion.armin`. Override it with `APP_ID`:

```sh
APP_ID=com.example.app make emulator-reset
```

## Troubleshooting

### `adb: more than one device/emulator`

Run:

```sh
adb devices
```

Then provide the target:

```sh
DEVICE_ID=emulator-5554 make emulator-smoke-test
```

### Emulator cannot reach the internet

Verify the host has internet access, restart the emulator, and run:

```sh
make emulator-check-network
```

If DNS is broken inside the emulator, cold boot the AVD from Android Studio or
delete and recreate the AVD.

### Cannot access host `localhost`

Use `10.0.2.2` from inside the emulator. For example:

```text
http://10.0.2.2:8080
```

Do not use `http://localhost:8080` from the Android app or emulator shell.

### APK install failed

Check that the APK exists:

```sh
ls build/app/outputs/flutter-apk/app-debug.apk
```

Rebuild it:

```sh
flutter build apk --debug
```

If the app was installed with a different signature, uninstall first:

```sh
UNINSTALL=true make emulator-reset
make emulator-install
```

### App cannot connect to Bridge

Confirm the Bridge service is running on the host:

```sh
curl http://localhost:8080/health
```

Then confirm the emulator can reach it through the host gateway:

```sh
BRIDGE_PORT=8080 make emulator-check-network
```
