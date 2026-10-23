# NLVC VPN engineering notes

These rules apply to the whole repository. Read them before changing, building,
installing, or diagnosing the macOS client.

## Product architecture

- All Xcode builds use a Packet Tunnel System Extension at
  `Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension`.
- Never restore or embed the retired `Contents/PlugIns/*.appex` layout. A bundle
  containing either that old layout or both layouts is invalid for direct
  Developer ID distribution.
- The System Extension Info.plist uses `NetworkExtension/NEProviderClasses`,
  has a `main.swift` entry point that calls `NEProvider.startSystemExtensionMode()`,
  and is activated by `OSSystemExtensionRequest` before the VPN manager starts.
- Both development and Developer ID signing use
  `packet-tunnel-provider-systemextension`. The container also requires
  `com.apple.developer.system-extension.install`.
- Both signed programs claim the macOS-style App Group
  `T84BKD53ZD.com.linlu.hillstoneconnect`. The System Extension
  `NEMachServiceName` must be a child of that exact group. A missing group makes
  `nesessionmanager` reject the extension with `NetworkExtensionErrorDomain`
  code 6 even when signatures, notarization, and Gatekeeper all pass.
- `scripts/build_app.sh` and `scripts/build_local_installer.sh` are the supported
  local build paths. They must require the System Extension and reject stale
  App Extension content.
- `scripts/build_developer_id_pkg.command` is the supported direct-distribution
  build. `scripts/notarize_pkg.command` submits it, staples the ticket, and runs
  Gatekeeper assessment. Do not call a package publishable until both succeed.
- `scripts/build_and_notarize_dmg.command` wraps only a ready, hash-verified PKG
  in a signed DMG, submits the DMG to Apple, staples it, and writes
  `DMG-STATUS.txt`. Keep the PKG inside the DMG: copying the app directly would
  bypass the installer lifecycle required for safe System Extension upgrades.
- A release directory is deployable only when its `RELEASE-STATUS.txt` says
  `STATUS=READY`. A failed rebuild can leave an older same-version PKG behind;
  never infer success merely from the file's presence.
- Notarization does not fix an incorrect extension layout, missing entitlement,
  stale VPN configuration, or runtime protocol bug.
- A package is not release-ready until the installed extension advances past
  validation. Run `systemextensionsctl list` outside the app sandbox and inspect
  `sysextd` plus `nesessionmanager` logs after first activation. Signing and
  notarization alone are insufficient.

## Credentials and Keychain

- VPN usernames and passwords must never use Keychain APIs or Keychain access
  groups. Do not add `SecItem*`, `KeychainCredentialStore`, or the legacy service
  `com.local.hillstone-connect.credentials` back to the client.
- Credentials are stored by `LocalCredentialStore` as AES-GCM data in the app
  sandbox. The directory must be mode `0700`; the key and encrypted record must
  be mode `0600`.
- UserDefaults and `NETunnelProviderProtocol.providerConfiguration` must not
  contain the username or password. Credentials may be passed to
  `startVPNTunnel(options:)` for the current connection only.
- The code-signing/notarization Keychain used on the developer machine is
  separate from VPN credential storage. It is acceptable and required for
  Apple signing, but must never be exposed to the runtime client.

## Apple signing configuration

- Team ID: `T84BKD53ZD`.
- Machine-local release configuration:
  `~/.apple-signing/nlvc-vpn/config.plist`.
- Machine-local profiles:
  `~/.apple-signing/nlvc-vpn/NLVC-App.provisionprofile` and
  `~/.apple-signing/nlvc-vpn/NLVC-PacketTunnel.provisionprofile`.
- Developer ID identities recorded by the setup:
  `Developer ID Application: lu lin (T84BKD53ZD)` and
  `Developer ID Installer: lu lin (T84BKD53ZD)`.
- Multiple certificates can share those display names. Release signing must use
  the SHA-1 identity authorized by both embedded provisioning profiles; passing
  the display name to `codesign` is ambiguous and may select the wrong key.
- Notary profile name: `NLVC-VPN-Notary`.
- Never commit the Apple ID, app-specific password, private key, exported `.p12`,
  or the contents of the machine-local signing directory.
- Local System Extension builds require a valid `Apple Development` identity with
  its private key and active Xcode account. Check before building:

  ```sh
  security find-identity -v -p codesigning
  ```

- If Xcode reports `No Accounts`, `missing Xcode-Username`, or no Mac
  Development certificate, repair Xcode Settings > Accounts first. Do not ship
  an ad-hoc or unsigned Packet Tunnel build.
- After signing, verify both the container and embedded extension:

  ```sh
  codesign --verify --deep --strict --verbose=2 "dist/NLVC VPN.app"
  codesign -d --entitlements :- "dist/NLVC VPN.app"
  codesign -d --entitlements :- \
    "dist/NLVC VPN.app/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"
  ```

## Internal deployment

- NLVC VPN is internal software. Do not design an App Store, public-download,
  or MDM deployment path unless the product scope explicitly changes.
- The supported simple deployment is a Developer ID signed and notarized PKG.
  On first connection, the user approves `NLVC VPN 数据通道` once in System
  Settings > General > Login Items & Extensions > Network Extensions. Updates
  retaining the Team ID and extension bundle ID must not require reapproval.
- An unsigned app bundle may launch, but its restricted Network Extension and
  System Extension entitlements are not usable. Never present an unsigned build
  as a working VPN package.

## Versions, installation, and duplicate apps

- Keep the marketing version and build number synchronized in the Xcode project,
  all three Packaging Info plists, and the AppModel fallback string.
- Never test an installer without first verifying its embedded version and
  extension layout. Old local packages can downgrade the app because local
  component installation is not version-gated.
- Xcode automatically registers build products with LaunchServices, including
  unsigned products under `.build`. After build-only verification, unregister
  those copies and explicitly register `/Applications/NLVC VPN.app`.
- Runtime verification must log
  `bundle=/Applications/NLVC VPN.app`; logs from `swiftpm-testing-helper`,
  `.build`, `dist`, backups, or an Xcode product are not installed-app evidence.
- Installer upgrades must stop the active VPN and terminate the previous
  `NLVC VPN` process before replacing `/Applications/NLVC VPN.app`; otherwise
  the old executable can stay alive while the postinstall script launches a
  second process from the new bundle.
- Installer scripts must resolve VPN services by provider bundle ID and service
  UUID, never by the localized profile name. Preserve whether the tunnel was
  connected before installation and pass `--reconnect-after-update` only in
  that case so the freshly installed System Extension is activated immediately.
- Do not leave runnable old `.app` bundles or old `.pkg` files in build,
  release, backup, chat-download, or DerivedData locations during end-to-end
  testing. Unregister and quarantine exact resolved paths before removal.
- Preserve the current encrypted credential files and the current VPN manager
  unless a test explicitly requires resetting them.

## Connection state and diagnostics

- The app log is sandboxed at:
  `~/Library/Containers/com.linlu.hillstoneconnect/Data/Library/Logs/NLVC VPN/connection.log`.
  The similarly named file under `~/Library/Logs` can contain SwiftPM test logs.
- Validate a connection with both the app event log and the system VPN status.
  A UI label alone is not proof that the tunnel is active.
- Every asynchronous `saveToPreferences`/`loadFromPreferences`/start sequence
  must carry the current connection operation ID. Manual disconnect, loss of
  network, power-off, and liveness recovery must invalidate old callbacks.
- If a late `.connecting` or `.connected` status arrives after the user has
  cancelled, stop the tunnel and remain idle. Never allow an old callback to
  restart a manually disconnected VPN.
- Avoid concurrent reconnect attempts. A single reconnect task owns each retry;
  System Extension activation is part of that owned attempt and must set the
  connection-starting guard before submission. Stale callbacks must only log
  and return.
- Reset exponential backoff when the physical network becomes unavailable.
  A newly restored path gets a short stabilization delay rather than inheriting
  a prior 30-second retry delay.
- Every automatic reconnect must run System Extension activation before saving
  and starting the VPN manager. This is a fast no-op for the current provider
  and ensures an installed update replaces the previously registered extension.
- Reconnection is fail-open. A runtime tunnel failure must clear `reasserting`,
  remove tunnel settings, and cancel packet I/O before the app retries so local
  Wi-Fi or Ethernet remains usable while the VPN is unavailable.

## UDP Pacing

- The setting is named `UDP Pacing`, not BBR. Do not claim Linux kernel BBR is
  active on macOS.
- Enabling UDP Pacing forces the UDP ESP data channel. It smooths outgoing ESP
  datagram bursts with a small burst allowance and a network-specific starting
  rate, then ramps toward a higher ceiling when a sustained pacing backlog shows
  a bulk transfer. It must not impose the old fixed 160 Mbps Wi-Fi ceiling and
  does not alter inner TCP congestion control.
- The provider must expose whether pacing is actually active and its target rate
  through runtime statistics so the diagnostics UI can verify the switch.
- Keep the pacing scheduler deterministic and unit tested. The disabled schedule
  must add zero delay.

## Required verification

- Run the complete suite after source changes:

  ```sh
  mkdir -p .cache/clang .cache/swiftpm
  CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swiftpm" \
  swift test --disable-sandbox
  ```

- Before handing off a VPN fix, verify: launch without crash, no runtime Keychain
  credential symbols, correct System Extension layout, connect, manual disconnect,
  immediate reconnect, stable status, and no stale callback starting a tunnel.
- For a new package, install it over the previous public build and verify the
  replacement path too. The registered extension must show the new version, not
  an old `activated waiting for user` entry. If approval is required, approve it
  under System Settings > General > Login Items & Extensions > Network Extensions,
  then repeat the connection test.
