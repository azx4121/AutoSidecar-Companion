# AutoSidecar Companion 0.2.0

[繁體中文](README.md) · English

Use your iPad as a Retina second display for your Mac over a single USB-C data cable. The Mac menu bar app manages the connection, display, audio, and input. The same iPad receiver plays Mac audio and can control your Mac with touch, a keyboard, or a trackpad once you grant input access.

## Downloads

- [Download the v0.2.0 source ZIP](https://github.com/azx4121/AutoSidecar-Companion/archive/8bdf8d1063cd8b1ec34bcd69a8e3753b06159ebf.zip)
- [Download the source ZIP with both READMEs](https://github.com/azx4121/AutoSidecar-Companion/archive/9aa789c5fe3392a032bfb4ec87184a4c8bd8ccd5.zip)

This developer preview is available as source. Follow the steps below to build the Mac installer and run the iPad receiver from Xcode. A notarized Mac installer, an App Store release, and TestFlight distribution are still pending.

## Requirements

- **Mac** with macOS 14 or later. HDR10 requires macOS 26 or later, compatible capture and encoding on the Mac, and an HDR10-capable iPad receiver.
- **iPad** with iPadOS 17 or later. Connect it using a USB-C cable that supports data transfer.
- **Build tools** include full Xcode, the Swift 6 toolchain, the macOS and iOS SDKs, and Python 3. This version was built with Xcode 27.2.

## Build

Run these commands from the repository root. If the active developer directory points to Command Line Tools, run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in the same terminal first. Adjust the path if Xcode is installed elsewhere.

```sh
python3 build-mac.py dist/AutoSidecar-Companion.pkg
bash build-receiver.sh dist
```

The Mac build includes both Apple silicon and Intel binaries by default. Pass `--arch arm64` to build for Apple silicon only. The Mac app uses ad hoc signing by default, and the package is unsigned for local development. The iPad script produces `dist/AutoSidecar-iPad-unsigned.ipa` for checking the device build. Use Xcode to sign and install the receiver on your own iPad.

## Install and pair your devices

1. **Mac.** Open the `dist/AutoSidecar-Companion.pkg` you built and follow the Installer prompts. It includes `/Applications/AutoSidecar Companion.app` and a Core Audio component. If the app does not appear in the menu bar, open it from Applications and start setup.
2. **iPad.** Open [WiredDisplayClient.xcodeproj](iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj) in Xcode and select the `WiredDisplayClient` scheme. In **Signing & Capabilities**, select your development team and a bundle identifier available to that team. Connect and unlock your iPad, then trust the Mac if prompted. Select the iPad as the run destination and click **Run**. Enable Developer Mode if iPadOS prompts you. [Running on a device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) · [Trust This Computer](https://support.apple.com/en-us/109054)
3. **First pairing.** Sign in to macOS and keep the iPad receiver in the foreground. Confirm the pairing on both devices once you have checked that their codes match.
4. **Permissions.** In **System Settings → Privacy & Security** on the Mac, allow screen recording. To hear Mac audio on the iPad, grant microphone access to the Mac app so it can read the virtual audio device. To control the Mac from the iPad, enable input in the Mac app and grant Accessibility access. Reopen the app if macOS asks. The iPad microphone starts disabled. [Screen recording access](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac) · [Microphone access](https://support.apple.com/guide/mac-help/mchla1b1e1fe/mac)
5. **Daily use.** While signed in to macOS, open the iPad receiver and plug in the cable. Paired devices will try to reconnect. Turn on **Mac audio on this iPad** in the receiver and adjust the **iPad Speaker** volume in the Mac’s Sound settings. Pairing and streaming start after a macOS user signs in.

## Display, audio, and connection

- The host negotiates resolution, scale, and refresh rate based on the iPad’s built-in display. It waits for the receiver to report display information and negotiates up to 120 FPS. The reported display limit, Low Power Mode, or the optional 60 Hz compatibility setting can lower the ceiling. If high refresh or HDR fails to start, the host retries in stages and can fall back to 60 Hz SDR at the same resolution.
- USB is the default. Audio uses 48 kHz stereo PCM. The iPad’s selected output determines the playback sample rate and channel count. On disconnect, Companion attempts to release the virtual display and restore any Mac audio output it changed.
- **Wi-Fi is experimental.** Pair over USB and put both devices on the same local network. Enable Wi-Fi in the iPad receiver and grant Local Network access if prompted. Quit the USB host on the Mac and start the LAN host with `open -a "AutoSidecar Companion" --args --lan-interface en0`. Replace `en0` with the interface connected to that network. The iPad can discover the host through Bonjour or use the network address remembered from a USB session, then verify the paired key. Automatic reconnection without USB, input, and sustained audio still need testing on physical devices.

## Verification

```sh
swift test
python3 CompanionTests/check_mac.py dist/AutoSidecar-Companion.pkg
python3 CompanionTests/check_receiver.py dist/AutoSidecar-iPad-unsigned.ipa
python3 CompanionTests/check_audio_routes.py .
mkdir -p dist
xcrun swiftc -swift-version 6 macOSHost/Host/MacBookLayout.swift CompanionTests/layout-tests.swift -o dist/layout-tests
./dist/layout-tests
```

**Verified** in this preview: the universal Mac package and the iPad device and simulator builds, packaging checks, 190 Swift unit tests, simulated MacBook and Mac mini/XREAL display layouts, and offline stereo and mono audio tests.

**Still to test on physical devices:** USB pairing across iPad models, MacBook input and iPad audio playback, headless Mac mini cold starts, and XREAL handover on disconnect. The negotiated 120 FPS ceiling and receiver counts are software metrics. Measuring the panel refresh rate, HDR brightness, and audio latency requires hardware tests. Metal presentation callbacks are available on physical iPads. The Mac virtual display uses the private `CGVirtualDisplay` API at runtime, and compatibility may vary across macOS versions.

## Signing and license

The Mac build accepts `APP_SIGN_IDENTITY` and `INSTALLER_SIGN_IDENTITY` for your signing identities. Public Mac distribution requires the appropriate Developer ID signing and notarization. Public iPad distribution depends on the signing, review, and license terms of the distribution channel. When you have an App Store product page or a public TestFlight invitation, set `AUTOSIDECAR_RECEIVER_URL` to show a download QR code during Mac setup. [Mac notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [TestFlight](https://developer.apple.com/testflight/)

AutoSidecar Companion 0.2.0 is a modified version of sibawono’s WiredDisplay, dated November 25, 2026. It uses the original Mac host, iPad receiver, protocol, audio implementation, icons, and icon generator from [upstream commit 64180c7](https://github.com/sibawono/WiredDisplay/tree/64180c7b9bed550bdd622e6c42c9d2e0773fc5ec). It is distributed under the [GNU General Public License, version 3](LICENSE). See the [changelog](docs/CHANGELOG.md) for Companion changes.
