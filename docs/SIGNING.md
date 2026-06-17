# SIGNING.md

Runbook for producing a Developer ID signed, notarized, and stapled
`USBImagerApp.app` bundle with an embedded SMAppService privileged helper.
Target: macOS 26 (Tahoe), Apple Silicon, non-sandboxed (raw disk access).

Lines marked `# TODO` require a value you supply once you have a Developer ID
certificate enrolled in the Apple Developer Program.

---

## 1. Prerequisites

### 1.1 Apple Developer Program enrollment

- Enroll at https://developer.apple.com/programs/.
- Create or locate a **Developer ID Application** certificate in Xcode
  Preferences > Accounts > Manage Certificates.
- Note your **Team ID** (10-character alphanumeric) from
  https://developer.apple.com/account.

### 1.2 Local tools

```bash
xcode-select --install          # ensures Command Line Tools
xcrun notarytool --version      # must succeed; bundled with Xcode 13+
xcrun stapler --version
```

### 1.3 App-specific password for notarytool

1. Sign in at https://appleid.apple.com.
2. Generate an App-Specific Password (Security > App-Specific Passwords).
3. Store it in your login keychain once so the scripts can retrieve it:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
    --apple-id "YOUR_APPLE_ID@example.com" \  # TODO: your Apple ID
    --team-id  "XXXXXXXXXX" \                  # TODO: your Team ID
    --password "xxxx-xxxx-xxxx-xxxx"           # TODO: app-specific password
```

The profile name `notarytool-profile` is referenced in `scripts/notarize.sh`.

---

## 2. Bundle ID and Mach service name decisions

Choose these once and commit them. They appear in Info.plist files, launchd
plists, entitlements, and source constants.

| Item | Recommended value | Where used |
| --- | --- | --- |
| App bundle ID | `com.nsh.usbimager` | app Info.plist, entitlements |
| Helper bundle ID | `com.nsh.usbimager.helper` | helper Info.plist, launchd plist |
| Mach service name | `com.nsh.usbimager.helper` | `USBImagerApp.swift`, XPC listener |
| launchd plist name | `com.nsh.usbimager.helper.plist` | embedded in app bundle |

The Mach service name must match the `Label` key in the launchd plist AND the
constant `helperMachServiceName` in `Sources/USBImagerApp/USBImagerApp.swift`.

---

## 3. Required plists and entitlements

### 3.1 App Info.plist

Create `Resources/Info.plist` at the repo root (or in the Xcode project):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>USBImagerApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.nsh.usbimager</string>           <!-- TODO: confirm bundle ID -->
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>USBImagerApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SMPrivilegedExecutables</key>           <!-- required for SMAppService -->
  <dict>
    <key>com.nsh.usbimager.helper</key>        <!-- TODO: helper bundle ID -->
    <!-- Designated requirement the app uses to pin the helper identity. -->
    <!-- Fill in the exact DR string AFTER you have signed the helper once -->
    <!-- and run: codesign -d -r - /path/to/helper                        -->
    <string>identifier "com.nsh.usbimager.helper" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "XXXXXXXXXX"</string>
    <!-- TODO: replace OU value with your Team ID -->
  </dict>
</dict>
</plist>
```

### 3.2 App entitlements

Create `Resources/USBImagerApp.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Non-sandboxed: raw disk access requires no sandbox. -->
  <key>com.apple.security.app-sandbox</key>
  <false/>

  <!-- Allows this app to communicate with its privileged LaunchDaemon helper. -->
  <key>com.apple.security.application-groups</key>
  <array/>

  <!-- Hardened runtime is required for notarization. -->
  <!-- The keys below relax only what raw disk I/O needs. -->

  <!-- Allow reading arbitrary files (source image path). -->
  <key>com.apple.security.files.user-selected.read-only</key>
  <true/>
</dict>
</plist>
```

Note: non-sandboxed apps still require hardened runtime (`--options runtime`)
for notarization. The sandbox key is explicitly false; do not omit it.

### 3.3 Helper Info.plist

Create `Resources/HelperInfo.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.nsh.usbimager.helper</string>    <!-- TODO: helper bundle ID -->
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleExecutable</key>
  <string>PrivilegedHelper</string>
  <key>SMAuthorizedClients</key>
  <array>
    <!-- Designated requirement the helper uses to pin the app's identity.    -->
    <!-- Fill in AFTER signing the app once and running:                       -->
    <!--   codesign -d -r - /path/to/USBImagerApp.app                         -->
    <string>identifier "com.nsh.usbimager" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "XXXXXXXXXX"</string>
    <!-- TODO: replace OU value with your Team ID -->
  </array>
</dict>
</plist>
```

### 3.4 Helper entitlements

Create `Resources/PrivilegedHelper.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Helpers run as root; no sandbox. -->
  <key>com.apple.security.app-sandbox</key>
  <false/>

  <!-- Required for hardened runtime on a root daemon. -->
  <!-- disable-library-validation: needed when the helper links frameworks  -->
  <!-- not in the standard hardened-runtime allow list.                     -->
  <key>com.apple.security.cs.disable-library-validation</key>
  <false/>
</dict>
</plist>
```

### 3.5 LaunchDaemon plist

Create `Resources/com.nsh.usbimager.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nsh.usbimager.helper</string>      <!-- TODO: must match Mach service name -->
  <key>MachServices</key>
  <dict>
    <key>com.nsh.usbimager.helper</key>
    <true/>
  </dict>
  <key>BundleProgram</key>
  <string>Contents/Library/LaunchDaemons/com.nsh.usbimager.helper</string>
</dict>
</plist>
```

The `BundleProgram` path is relative to the app bundle root. SMAppService
resolves it there; do not use an absolute path.

---

## 4. App bundle layout

The final `.app` bundle must match this layout for SMAppService to find the
embedded daemon:

```
USBImagerApp.app/
  Contents/
    Info.plist
    MacOS/
      USBImagerApp               (signed main executable)
    Library/
      LaunchDaemons/
        com.nsh.usbimager.helper (signed helper executable)
        com.nsh.usbimager.helper.plist
    Resources/
      (icons, etc.)
    _CodeSignature/
      CodeResources
```

The helper executable lives at
`Contents/Library/LaunchDaemons/<label>` alongside its launchd plist.
Both are signed before the outer bundle is sealed.

---

## 5. Building the binaries

### 5.1 SwiftPM vs Xcode app target

SwiftPM builds a CLI executable, not an `.app` bundle. For a distributable
signed app you have two options:

**Option A -- manual bundle assembly from SwiftPM output (this runbook)**

Build both targets with SwiftPM, then assemble the bundle directory by hand
before signing. The script `scripts/build_bundle.sh` automates this.

**Option B -- Xcode app target**

Add an Xcode project with an App target for `USBImagerApp` and a
Command Line Tool target for `PrivilegedHelper`, using the same Swift
sources via folder references. Xcode handles bundle assembly, Info.plist
embedding, and entitlement injection automatically. This is the recommended
long-term approach for Xcode-managed signing workflows.

For now, Option A keeps everything in git without an Xcode project.

### 5.2 Build commands

```bash
swift build -c release --arch arm64 \
    --product USBImagerApp \
    --product PrivilegedHelper   # TODO: verify product names match Package.swift
```

The release binaries land at `.build/release/USBImagerApp` and
`.build/release/PrivilegedHelper`.

---

## 6. Designated requirement strings

A designated requirement (DR) is a code-signing predicate that uniquely
identifies a signed binary to the Security framework. Both the app and the
helper must embed each other's DR so they can mutually authenticate the XPC
peer.

The canonical DR for a Developer ID binary is:

```
anchor apple generic
and identifier "com.nsh.usbimager.helper"
and certificate 1[field.1.2.840.113635.100.6.2.6]
and certificate leaf[field.1.2.840.113635.100.6.1.13]
and certificate leaf[subject.OU] = "XXXXXXXXXX"
```

Replace `XXXXXXXXXX` with your Team ID. The two certificate OID fields
select the Developer ID intermediate and leaf certificates respectively;
they are the same for all Developer ID signed software.

To extract the actual DR from a signed binary:

```bash
codesign -d -r - /path/to/binary
```

Use that output verbatim in `SMPrivilegedExecutables` (app Info.plist) and
`SMAuthorizedClients` (helper Info.plist), and in the Swift constant
`helperRequirementString` in `Sources/USBImagerApp/USBImagerApp.swift`.

---

## 7. Signing order

Sign inner binaries before sealing the outer bundle. Signing the app last
is mandatory; reversing the order invalidates the bundle signature.

```
1. Sign the helper executable
2. Sign the app executable (inside Contents/MacOS/)
3. Sign the outer .app bundle (seals Contents/_CodeSignature/CodeResources)
```

See `scripts/sign_app.sh` for the exact `codesign` invocations.

---

## 8. Script: scripts/build_bundle.sh

Assemble the `.app` directory from SwiftPM release output.
Run this before signing.

See `scripts/build_bundle.sh` in the repo.

---

## 9. Script: scripts/sign_app.sh

Signs the helper, the app executable, and the outer bundle.

See `scripts/sign_app.sh` in the repo.

---

## 10. Script: scripts/notarize.sh

Submits the signed app for notarization, polls for the result, and staples
the notarization ticket.

See `scripts/notarize.sh` in the repo.

---

## 11. XPC peer pinning -- wiring the real SecCode check

`HelperAuthorization.pinning(requirement:)` in
`Sources/PrivilegedHelper/HelperAuthorization.swift` currently stubs the
`SecCode` check (see inline STUB comments). When you have a signed helper,
replace the stub body with:

```swift
// 1. Obtain the peer SecCode from the NSXPCConnection:
//    var peer: SecCode? = nil
//    let err = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid], [], &peer)
//    guard err == errSecSuccess, let code = peer else { throw HelperError.notAuthorized(...) }
//
// 2. Create a SecRequirement from the pinned string:
//    var req: SecRequirement? = nil
//    SecRequirementCreateWithString(pinned as CFString, [], &req)
//    guard let requirement = req else { throw HelperError.notAuthorized(...) }
//
// 3. Validate:
//    let status = SecCodeCheckValidity(code, [], requirement)
//    guard status == errSecSuccess else { throw HelperError.notAuthorized(...) }
```

On the app side, `XPCHelperConnection` in
`Sources/FlashEngine/HelperConnection.swift` stores `peerRequirement` for this
wiring. Add the `auditTokenBlock` hook to the `NSXPCConnection` there to
validate the helper before trusting any reply.

---

## 12. SMAppService registration

After installing the app into `/Applications`, the app registers the helper
at first launch with:

```swift
import ServiceManagement

let service = SMAppService.daemon(plistName: "com.nsh.usbimager.helper.plist")
do {
    try service.register()
} catch {
    // Handle SMAppService registration failure.
}
```

The call prompts the user for authorization (shows the system Privacy and
Security pane on first run). The helper is then managed by launchd; the app
does not start it manually.

To check status during development:

```bash
sfltool dumpbtm            # view Background Task Manager registrations
launchctl list | grep nsh  # confirm the daemon label is live
```

To unregister during development:

```bash
# In Swift: try SMAppService.daemon(plistName: "...").unregister()
```

---

## 13. Full signing and notarization flow

Step-by-step after building. All `<PLACEHOLDER>` values are user TODOs.

```
Step 1  Build binaries
        bash scripts/build_bundle.sh

Step 2  Sign
        bash scripts/sign_app.sh

Step 3  Verify signatures before submitting
        codesign --verify --deep --strict --verbose=2 dist/USBImagerApp.app
        spctl --assess --type exec --verbose dist/USBImagerApp.app
        # spctl will say "rejected" until notarization; that is expected here.

Step 4  Notarize and staple
        bash scripts/notarize.sh

Step 5  Verify notarization
        spctl --assess --type exec --verbose dist/USBImagerApp.app
        # Expected: "accepted" source=Notarized Developer ID
        xcrun stapler validate dist/USBImagerApp.app

Step 6  Distribute
        # Zip for direct download:
        ditto -c -k --keepParent dist/USBImagerApp.app dist/USBImagerApp.zip
        # Or create a signed DMG (see Apple documentation for hdiutil workflow).
```

---

## 14. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `codesign: no identity found` | Certificate not in keychain | Install Developer ID cert in Keychain Access |
| `SMAppService.register()` fails with permission error | Helper DR in `SMPrivilegedExecutables` does not match actual signed helper | Re-derive DR with `codesign -d -r -` and update Info.plist |
| XPC connection refused | `helperRequirementString` in source does not match actual helper DR | Update constant and rebuild app |
| Notarization rejected: hardened runtime not enabled | Forgot `--options runtime` flag on codesign | Add flag; re-sign and re-submit |
| Notarization rejected: entitlement not allowed | Used a sandbox-only entitlement on a non-sandboxed binary | Remove the disallowed key from the entitlements file |
| `spctl` says "rejected" after stapling | Ticket not stapled | Run `xcrun stapler staple` again; check notarization status |
| Helper not launching | Launchd plist `BundleProgram` path wrong | Confirm path is relative to bundle root, not absolute |

---

## 15. Reference

- Apple: Notarizing macOS software before distribution
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple: Signing a daemon with a restricted entitlement
  https://developer.apple.com/documentation/xpc/signing-a-daemon-with-a-restricted-entitlement
- Apple: SMAppService class reference
  https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple: Updating helper executables from earlier versions of macOS
  https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api
- Apple: Hardened runtime entitlements
  https://developer.apple.com/documentation/security/hardened-runtime
- Apple: Code signing requirement language
  https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html
