# MacSeal updates

MacSeal uses Sparkle 2. The download icon in the window toolbar starts a Sparkle update check; automatic checks and background downloading are enabled.

Automatic installation becomes active once a signed Sparkle release is published. The configured feed is `appcast.xml` on the repository's `main` branch.

## Publishing an update

1. Keep the app's bundle identifier stable and increment `CFBundleVersion` for each release.
2. Sign and notarize the app for distribution with the same Developer ID identity used for previous releases.
3. Package the `.app` in a Sparkle-compatible `.dmg` or `.zip`, and upload that archive to a GitHub release.
4. Generate the Sparkle EdDSA keys with Sparkle's `generate_keys` tool. Store the private key securely outside the repository; add only its public key to the app's `Info.plist` as `SUPublicEDKey`.
5. Use Sparkle's `generate_appcast` tool with the published archives and the private signing key, then publish its generated `appcast.xml` to the repository's `main` branch.

The feed intentionally has no update entries until signed archives and the public key are configured. Do not publish unsigned updates or commit the EdDSA private key.
