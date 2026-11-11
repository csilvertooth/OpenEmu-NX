# Signed app updates

Starting with 0.1.4 (build 27), OpenEmu-NX checks:
https://raw.githubusercontent.com/csilvertooth/OpenEmu-NX/main/appcast.xml

Update installers are hosted in this repository's GitHub Releases. The app checks automatically and asks before installation by default. Users can also use Check for Updates. Versions through 0.1.3 had their updater disabled and need a one-time manual installation of 0.1.4 or newer.

The current feed is for testing builds. A GitHub prerelease label does not exclude an update from Sparkle: any version intentionally included in this feed can be offered to users.

## Signing

Apple Developer ID signing and notarization authenticate the app. Sparkle additionally verifies Ed25519 signatures on the installer and feed before presenting or extracting updates. Release notes are embedded in the signed feed. Invalid-feed failures do not expire into unsigned-feed acceptance.

Only the public verification key is committed. The private key is stored in the maintainer's macOS Keychain under Sparkle's `OpenEmu-NX` account. Never export it into the repository or put it in scripts, logs, release assets or workflow configuration. Keep a secure backup of the signing Keychain. A fork must generate its own key and change the feed, repository and bundle identity.

## Publishing an update

1. Finish and test the source change. Increment `CFBundleVersion` monotonically and set `CFBundleShortVersionString` in the app Info.plist.
2. Build, Developer ID sign, notarize and staple the app and installer. Finish all packaging before creating the Sparkle signature; any subsequent byte change invalidates it.
3. Use the matching Sparkle distribution's `generate_appcast --account OpenEmu-NX --maximum-deltas 0 --download-url-prefix https://github.com/csilvertooth/OpenEmu-NX/releases/download/TAG/ DIRECTORY` to prepare entries from the final installer. Review versions, minimum macOS and URLs. Retain appropriate previous entries. Embed release notes.
4. Sign the final XML using `sign_update --account OpenEmu-NX appcast.xml`, then verify with `sign_update --account OpenEmu-NX --verify appcast.xml`. Verify the installer with `sign_update --account OpenEmu-NX --verify INSTALLER SIGNATURE` too. No private-key file is needed.
5. Upload the final installer to the matching GitHub release. Confirm its public download matches the signed bytes before committing the new feed. Never edit a published installer in place; use a new build number and filename.
6. Fetch the public feed and installer anonymously and reverify their signatures, length and version. Test Sparkle discovery and installation on a disposable copy, preserving the real user's app and data.

Core updates are separate and continue using their upstream channels. Do not change core keys or feeds when rotating the app's signing key.

See [Sparkle publishing](https://sparkle-project.org/documentation/publishing/) and [security settings](https://sparkle-project.org/documentation/customization/).
