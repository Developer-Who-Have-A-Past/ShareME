# ShareLAN

Share files, folders, text and clipboard between a Windows laptop and an Android phone over the same WiFi. One Flutter codebase, installed on both.

## One-time setup

1. Install Flutter (https://docs.flutter.dev/get-started/install/windows) and, for Windows desktop builds, Visual Studio with the "Desktop development with C++" workload. For Android, install Android Studio.
2. Put this folder somewhere, open a terminal inside it, and generate the platform folders (this keeps the `lib/` and `pubspec.yaml` already here):

   ```
   flutter create --platforms=windows,android --project-name sharelan .
   flutter pub get
   ```

3. **Android permissions.** Open `android/app/src/main/AndroidManifest.xml` and add these lines inside `<manifest>`, above `<application>`:

   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
   <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
   ```

## Run / build

```
flutter run -d windows            # test on laptop
flutter run -d <android-device>   # test on phone (USB debugging on)

flutter build windows --release   # -> build\windows\x64\runner\Release\
flutter build apk --release       # -> build\app\outputs\flutter-apk\app-release.apk
```

Copy the APK to your phone and install it. For the laptop, zip the whole `Release` folder (the .exe needs the DLLs beside it) or wrap it with an installer tool such as Inno Setup.

## Using it

1. Connect both devices to the **same WiFi**.
2. Open ShareLAN on both. Each shows a 6-digit **PIN**.
3. The other device appears under "Nearby devices". Tap Files / Folder / Text / Clipboard.
4. Enter the **receiver's PIN** when asked (remembered until the app closes).
5. Received files go to the `ShareLAN` folder shown on the home card (Downloads\ShareLAN on Windows; the app's own folder on Android).

First launch on Windows triggers a firewall prompt: allow **Private networks**.

## Features (v1.1)

- Accept / decline prompt before files are received, with "Always accept from this device"
- PINs are remembered per device, so you type them once
- Cancel a running transfer, and Retry a failed one
- Speed and time remaining on every transfer
- Received history that survives restarts, with Open / Show in folder / Copy
- Option to copy received text to the clipboard automatically
- Light / dark / system theme (Settings)
- Windows: drag files or folders onto the window to send them
- Android: "Save received files to Downloads" (Settings, needs "all files access")
- Optional Windows installer (`ShareLAN-Setup.exe`) built by the GitHub workflow

## How it works

- **Discovery:** each app broadcasts a small UDP beacon (port 45454) every 3 s and lists the beacons it hears. "Add by IP" (top right) is the fallback.
- **Transfer:** direct TCP (port 45455) between the devices, no server or internet.
- **Security:** AES-256-GCM, key derived from the receiver's PIN (PBKDF2-SHA256) plus a random per-connection salt. Every frame is authenticated and sequence-numbered. A wrong PIN fails immediately, and 5 failures per minute from one IP blocks it.
- **Folders** are zipped on the sender and arrive as a `.zip`.

## Known limits (v1)

- A 6-digit PIN protects against casual access but not a determined attacker who records your WiFi traffic and brute-forces the PIN offline. Upgrade path: a PAKE (SPAKE2) or certificate pinning.
- On Android, received files land in the app-specific folder until you choose Settings > Save received files to Downloads.
- Not built yet: sharing from other Android apps (Share menu), background transfers while the app is closed, resuming interrupted transfers, and a stronger key exchange than the PIN.
- PINs and trusted-device ids are stored unencrypted in the app's settings file.
- Some routers use "AP/client isolation" (common on guest WiFi), which blocks device-to-device traffic. Use the main WiFi or your phone's hotspot.
- Large transfers on Android stop if the app is backgrounded for long; keep the screen on.
- Written without a Flutter SDK available, so it hasn't been compiled yet. If `flutter pub get` or `flutter run` reports an error, send it to me and I'll fix it.

## Publishing on GitHub

```
git init
git add .
git commit -m "Initial commit: ShareLAN"
git branch -M main
git remote add origin https://github.com/<your-username>/sharelan.git
git push -u origin main

git tag v1.0.0
git push origin v1.0.0     # triggers .github/workflows/build.yml
```

GitHub Actions builds the Android APK and the Windows zip and attaches both to a
release under the repo's **Releases** page. You can also run the workflow manually
from the **Actions** tab.

Note: if you haven't committed the generated `android/` and `windows/` folders, the
workflow generates them itself and adds the Android network permissions automatically.
