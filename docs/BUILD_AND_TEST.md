# Build, run and test Auris

Every command below is run from the `app/` directory unless stated otherwise.

---

## 0. One-time setup

**Check Flutter.** You need Flutter 3.47 or newer (Dart 3.13 or newer): the package versions locked in `pubspec.lock` require it.

```bash
flutter --version
```

**Create your `.env`.** This is required even if you leave every value blank - Flutter bundles `.env` as an asset and the build fails if the file is missing.

```bash
cp .env.example .env
```

On Windows PowerShell:

```bash
Copy-Item .env.example .env
```

**Install dependencies.**

```bash
flutter pub get
```

---

## 1. Run the tests

```bash
flutter test
```

Expected: `+282: All tests passed!`

For one suite with names printed:

```bash
flutter test test/hughson_westlake_test.dart --reporter expanded
```

Static analysis - should print `No issues found!`:

```bash
flutter analyze
```

---

## 2. Run the app in development

**List what you can run on:**

```bash
flutter devices
```

> **Chrome and Edge will appear in that list, but the app will not run on them.** The web build compiles, then stops on a startup message: sqflite has no web backend. Pick Android, macOS, iOS or Windows.

**Run on a connected Android phone or tablet** (plug it in with USB debugging on):

```bash
flutter run -d android
```

**Run on a Mac:**

```bash
flutter run -d macos
```

**Run on an iPhone or iPad** (connected by cable, with Developer Mode on). The first time, open `ios/Runner.xcworkspace` in Xcode, select the **Runner** target, **Signing & Capabilities**, and pick your team, so Xcode can sign the app:

```bash
flutter run -d ios
```

The first iOS build creates `ios/Podfile` and installs the plugins with CocoaPods; that needs CocoaPods installed (`brew install cocoapods`) and an internet connection.

> **If a macOS build fails with "resource fork, Finder information, or similar detritus not allowed"**, the project is inside a synced folder (OneDrive, iCloud Drive) that adds file attributes the code signer refuses. Run `xattr -cr build macos assets`, then `flutter clean` and build again, or keep a working copy outside the synced folder.

**Run on Windows desktop** - quickest for checking screens, but you still need headphones plugged in to hear anything:

```bash
flutter run -d windows
```

> Windows desktop needs Visual Studio with the **"Desktop development with C++"** workload. Without it the build stops at *"Unable to find suitable Visual Studio toolchain"*. Having Visual Studio installed is not enough - the workload is a separate component.
>
> To add it: open **Visual Studio Installer** → **Modify** on your VS install → **Workloads** tab → tick **Desktop development with C++** → in the *Installation details* panel on the right, confirm these are ticked:
> - **MSVC v142 - VS 2019 C++ x64/x86 build tools** (under Optional; take the latest if several are offered)
> - **C++ CMake tools for Windows**
> - **Windows 10 SDK** (or Windows 11 SDK)
>
> Then **Modify** to install (~7 GB). Open a fresh terminal and confirm `flutter doctor` shows `[√] Visual Studio`.

Google sign-in is not offered on Windows and Linux: the browser cannot hand the user back to the app there. Use email and password on those.

Hot reload with `r`, hot restart with `R`, quit with `q`.

---

## 3. Build a release

### Android

```bash
flutter build apk --release
```

Output lands at `build/app/outputs/flutter-apk/app-release.apk`. Copy that to the clinic tablet and install it. For a smaller download per device, `flutter build apk --split-per-abi`. For the Play Store, `flutter build appbundle --release`.

**First build needs internet.** Gradle downloads its own distribution (Gradle 8.11.1, Android Gradle Plugin 8.9.1, Kotlin 2.1) and the Android dependencies on the first run. It needs Java 17 or newer; the one bundled with Android Studio is fine.

**Signing.** Without a signing key, a release build is signed with the debug key: that installs fine by sideloading, but the Play Store refuses it. To sign for the store, create an upload keystore (see [the Flutter signing guide](https://docs.flutter.dev/deployment/android#signing-the-app)) and put its details in `android/key.properties`:

```
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/full/path/to/upload-keystore.jks
```

The build uses it automatically when the file exists. Do **not** commit it or the keystore; `.gitignore` already blocks `key.properties`, `*.jks` and `*.keystore`.

### macOS

```bash
flutter build macos --release
```

The app is at `build/macos/Build/Products/Release/Auris.app`. It is sandboxed, with permission to reach the network (cloud sync), print, and save a PDF where the user chooses. To give it to another Mac, sign and notarise it with your Apple Developer account in Xcode (`macos/Runner.xcworkspace`, **Product → Archive**).

### iOS

```bash
flutter build ipa --release
```

This needs the signing team set in Xcode (see section 2). The archive lands in `build/ios/archive/`; upload it to App Store Connect or TestFlight from Xcode's Organizer or with Apple's Transporter app.

---

## 4. Verify the audio path - do this before any clinical use

Audio has been unit-tested at the byte level but **not yet verified on physical hardware**. Work through this once per device + headphone pair:

1. Plug in wired headphones. (Bluetooth adds unpredictable latency and its own processing - avoid it for testing.)
2. Open the app, register a throwaway patient, and tap **Start first test**.
3. On the *Before you start* screen, press **Right ear**, then answer where the tone was heard.
   - You should hear a clear 1 kHz tone **in the right ear only**; answer **Right ear** and it is ticked.
   - If you hear it in both ears, the headphones are mono or the device is downmixing: stop, this device is unusable for per-ear testing.
   - If you hear it in the left ear, the headphones are on backwards. Answer **Left ear**: Auris says so and clears both ticks until the headphones are swapped and checked again.
4. Press **Left ear** and confirm the same in reverse. A test cannot start until every ear being tested has been checked this way.
5. If you hear nothing at all:
   - Raise the system volume and try again.
   - If the device cannot play 32-bit audio, Auris falls back to 16-bit by itself and says so on the report, because the quietest levels lose resolution.
6. Run a full test on yourself. With normal hearing and the volume set sensibly, thresholds should land in a plausible range rather than pinned at the top (too quiet) or at -10 dB HL (too loud). Where the headphones cannot reach 90 dB HL at a frequency, Auris tests only up to what they can produce and the report lists those limits.

Adjust the system volume until step 6 behaves, then **leave the volume alone** and calibrate against it (see below).

---

## 5. Calibrate

Until this is done, the numbers on the audiogram are relative, not real dB HL. The app says so on screen and on the PDF.

Open **Settings → Calibrate this device**. The wizard walks through it in four steps and offers two methods:

**With a sound level meter** - the accurate route. Set the volume where the clinic will keep it, hold the meter against the right earcup (a coupler or artificial ear is better if you have one), play the tone, and type in what the meter reads. Auris solves for the rest.

**Without a meter - biological check.** Someone with known normal hearing takes a two-minute test at 1 kHz. If they appear to have a 30 dB loss, the setup is 30 dB too quiet and Auris shifts everything by that amount. Clinics use this as a daily verification. It is much better than nothing, and it is only as good as the assumption that your reference listener really hears normally - so reports say plainly that no meter was used.

Recheck after changing headphones, device or volume setting, and routinely every few months.

Every term used is explained in **Settings → Help & glossary**, searchable.

---

## 6. Optional: enable cloud sync

See [SUPABASE_SETUP.md](SUPABASE_SETUP.md). Without it the app runs entirely offline, which is a perfectly good configuration for a single-device clinic.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `No file or variants found for asset: .env` at build | You skipped `cp .env.example .env`. |
| Gradle hangs or fails downloading | First Android build needs internet. Check any proxy, then retry. |
| `Visual Studio is missing necessary components` | Only affects `flutter run -d windows`. Install the "Desktop development with C++" workload, or use Android. |
| `error C2338 ... STL1011 ... <experimental/coroutine>` in `audioplayers_windows_plugin.vcxproj` | `audioplayers` 5.x uses a coroutines header that MSVC 14.51 (Visual Studio 2026) rejects outright. Fixed by requiring `audioplayers: ^6.8.1`. If you see this, you are on a stale lockfile - run `flutter pub get`, then `rm -rf build/windows` and rebuild. |
| `Failed to load dynamic library 'sqlite3.dll' (error code: 126)` on startup | Windows has no system SQLite. Fixed by the `sqlite3_flutter_libs` dependency, which copies `sqlite3.dll` next to the executable. If you see it, run `flutter pub get` and rebuild; confirm `sqlite3.dll` exists in `build/windows/x64/runner/Debug/`. |
| `LINK : fatal error LNK1168: cannot open ... auris.exe for writing` | A previous run of the app is still open and holding the executable. Close the Auris window (or press `q` in the `flutter run` terminal) and build again. |
| Tone plays in both ears | Device is downmixing to mono, or the headphones are mono. Try different headphones. |
| No sound at all | System volume; try wired headphones; check logs for a playback error. |
| App opens on an error screen | Read the message - usually no writable storage, or Flutter web (unsupported: sqflite has no web implementation). |
| Cannot register a patient / run a test | Your account is a **Viewer** or still **Awaiting approval**. On a device without cloud sync, an administrator changes it in Settings → Team. In cloud mode, a clinic admin does in Settings → Clinic and team, or a super admin in the Admin console. |
| Forgot the password of a local account | An administrator on the device sets a new one in Settings → Team (the key button next to the name). Cloud accounts use **Forgot password?** on the login screen. |
| Android build fails with a Gradle or Android Gradle Plugin version message | The build files expect Gradle 8.11.1 and Android Gradle Plugin 8.9.1 with Java 17. Run `flutter doctor -v` to see which Java Gradle uses, then `flutter clean` and build again. If your Flutter asks for newer versions, raise them in `android/settings.gradle` and `android/gradle/wrapper/gradle-wrapper.properties`. |
| `flutter test` fails to compile after pulling | Run `flutter pub get`. |

### Harmless log noise on Windows

Two messages flood the console on Windows desktop in debug mode. Both come from Flutter and its plugins, not from Auris, and neither affects the app:

- `[ERROR:...accessibility_bridge.cc] Failed to update ui::AXTree, error: NN will not be in the tree...` - a known defect in the Flutter Windows accessibility bridge, emitted whenever the widget tree changes while assistive technology is enabled. Cosmetic.
- `The 'xyz.luan/audioplayers/events/...' channel sent a message from native to Flutter on a non-platform thread` - the `audioplayers_windows` plugin posting completion events off the platform thread. Must be fixed in that plugin; playback works regardless.

Neither appears in a release build's console. If they make debugging hard, filter them:

```bash
flutter run -d windows 2>&1 | grep -v "AXTree\|non-platform thread"
```
