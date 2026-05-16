# Sparkle + Notarized Updates — integration roadmap

This document captures the integration path for migrating AutoRipper's
update mechanism from the current custom `UpdateService.swift`
implementation to [Sparkle 2](https://sparkle-project.org/) with
EdDSA-signed appcast feeds, plus the separate concern of Apple
notarization for Gatekeeper-clean installs.

It was written during the v4.0 sprint after attempting an in-session
Sparkle SPM integration that proved too slow to build (multi-minute
Sparkle XPC + Objective-C compilation hangs under `swift build`).
Sparkle's own guidance is to integrate via Xcode rather than pure
SPM, which is incompatible with the current `build-swift.sh`
pipeline. Resolving that is the gating prerequisite for the actual
code work below.

## Why Sparkle?

The current `UpdateService.swift`:
- Polls GitHub Releases API on launch + every 6h
- Downloads the DMG asset directly
- Uses `hdiutil attach -plist` + a bash helper to swap the bundle
- Works, but lacks: progress UI, signature verification, delta updates, and Gatekeeper-clean update path

Sparkle gives all of the above:
- `SPUStandardUpdaterController` provides a built-in update dialog
  with cancel, progress, error display, and post-install relaunch
- EdDSA appcast signing — the user can't be tricked into installing
  a swapped DMG by a MITM
- Delta updates between successive versions cut download size
- Smooth integration with Apple's notarization (if + when DevID is
  available)

## Prerequisites the user controls

1. **Apple Developer ID Application certificate** — needed for
   notarization. The current builds use Apple Development cert which
   triggers Gatekeeper warnings. Cost: $99/yr Apple Developer Program.
2. **App-specific password + Apple ID** for `notarytool` submissions.
3. **EdDSA keypair** for signing appcast entries. Sparkle ships a
   `generate_keys` tool for this. The private key stays on the
   release machine; the public key embeds in the app's Info.plist.

## Integration steps (in order, when ready)

### Step 1: Switch to Xcode-based build

Sparkle's XPC components (`Sparkle.app/Contents/XPCServices/`,
`Autoupdate`, `Downloader.xpc`) need to be embedded in the .app
bundle. Xcode handles this automatically via the SwiftPM
`process(...)` resource handling; `swift build` does not.

Options:
- (a) Move the project to an `.xcodeproj` with SPM packages, keep
      `build-swift.sh` calling `xcodebuild`
- (b) Stay on `swift build` and manually copy Sparkle's XPC
      services into the bundle in `build-swift.sh` after build

(a) is the supported path. (b) is hackier but doesn't require
restructuring.

### Step 2: Add SPM dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],
targets: [
    .executableTarget(
        name: "AutoRipper",
        dependencies: [.product(name: "Sparkle", package: "Sparkle")],
        path: "AutoRipper"
    ),
    ...
]
```

### Step 3: Wire SPUStandardUpdaterController into the app

```swift
// In AutoRipperApp or main scene
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc var updater: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
```

Add a menu item bound to `updater.checkForUpdates(_:)`.

### Step 4: Add Info.plist entries

```xml
<key>SUFeedURL</key>
<string>https://stevenob.github.io/AutoRipper/appcast.xml</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUPublicEDKey</key>
<string>BASE64-ENCODED-ED25519-PUBLIC-KEY</string>
```

The feed URL needs to be HTTPS and stable. Options:
- GitHub Pages on the repo (free, simple)
- Custom domain
- Update GitHub Releases to host appcast.xml at a stable URL

### Step 5: Generate the EdDSA keypair

```bash
# Sparkle's tool — run once per release machine
./Sparkle/bin/generate_keys
# Private key stored in macOS Keychain
# Public key printed to terminal — paste into Info.plist
```

### Step 6: Update build-swift.sh to sign + publish appcast

After the DMG is built, sign it with Sparkle's `sign_update`:

```bash
SPARKLE_SIG=$(./Sparkle/bin/sign_update AutoRipper-Installer.dmg)
```

Then add an entry to `appcast.xml` (commit + push to repo).

### Step 7: Notarization (separate concern)

With a Developer ID Application cert + app-specific password:

```bash
# After build, before DMG packaging
codesign --deep --force --options runtime \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    AutoRipper.app

# Submit for notarization
xcrun notarytool submit AutoRipper.app.zip \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "app-specific-password" \
    --wait

# Staple the ticket
xcrun stapler staple AutoRipper.app
```

Add these steps to `build-swift.sh` after the existing codesign
step. The notarization service is async — `--wait` blocks until
done (usually 30s to 5min).

### Step 8: Remove the custom updater (optional)

Once Sparkle is shipping and proven stable, `UpdateService.swift`
can be deleted. Or keep it as a fallback path behind an
`AppConfig.useSparkleUpdater` flag for a release or two while
users migrate.

## Estimated effort

- **Steps 1-6 (Sparkle + appcast):** 1 day, mostly build-script
  fiddling and getting the XPC bundle layout right.
- **Step 7 (notarization):** 2-4 hours assuming Developer ID cert
  already in keychain. Setup of the cert + app-specific password
  is a separate 30-minute Apple Developer Portal exercise.
- **Step 8 (cleanup):** small, once everything is stable.

## What v4.0 shipped

This document, plus the rest of the v4.0 batch (UX refresh, custom
preset import, per-disc rules). The actual Sparkle integration is
deferred until the build pipeline can absorb the Xcode-based path.

The current `UpdateService.swift` continues to be the shipping
update mechanism. v3.11.13 fixed its known `hdiutil -plist` parsing
bug — it's working reliably.
