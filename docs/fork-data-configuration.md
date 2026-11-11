# Data folders and fork configuration

The host app declares `OEApplicationSupportFolder` in
`OpenEmu/OpenEmu-Info.plist`. It is `OpenEmu-NX` in this fork. A downstream fork
changes that single folder value and the main app's Debug/Release
`PRODUCT_BUNDLE_IDENTIFIER` values in the Xcode project. The current bundle IDs
are `net.azimuthsystems.OpenEmuNX.debug` and `net.azimuthsystems.OpenEmuNX`.

OpenEmuBase's `OEHostApplicationBundle`, `OEApplicationSupportFolderName`,
`OEApplicationSupportDirectoryURL`, and `OEApplicationPreferencesDomain`
accessors are shared by the app, plugin loader, core support directories,
controller bindings, and nested helpers. Helpers locate the containing host
app's configuration rather than using a helper-specific folder or preference
domain. Standalone SDK clients without this configuration retain upstream's
OpenEmu fallback. Shader caches use the configured name under the macOS cache
folder; temporary downloads and system logs remain OS-managed.

`OELegacyApplicationSupportFolder` and `OELegacyPreferencesDomain` configure
optional first-launch import. Remove these keys when a fork should start clean.
They currently import from `OpenEmu` and `org.openemu.OpenEmu`. Migration:

- Refuses to copy while a legacy host app is running.
- Copies missing top-level data entries using a temporary copy followed by a
  rename. Never deletes the original folder or overwrites populated NX entries.
  Empty pre-created destination folders can be replaced only while still empty;
  missing multiplayer-session files merge without replacing existing saves.
- Preserves custom external game-library paths. Paths into the copied default
  data folder are retargeted to the new folder.
- Marks completed data copying separately from each build's preferences import,
  so a retry does not overwrite data already copied.
- Leaves hidden, bundle-bound credential stores in the original folder. Some
  third-party services may require sign-in again under the new app identity.
- Leaves migrated old data in place for recovery. The user may remove that old
  copy after checking the new installation.

macOS keeps the live preference domain in its normal Preferences location.
The app also maintains a mode-0600 `Preferences.plist` (or
`Preferences-Debug.plist`) backup in its data folder. This snapshot omits
credential-like keys, is not read as an authoritative settings file, and cannot
silently restore settings a user deliberately reset. Credentials remain in
separate protected storage. Changing the app identity can require granting
macOS Input Monitoring or other permissions again.

To check migration without touching real user data, run
`Scripts/check-nx-data-migration.sh`. It extracts the actual filesystem helper
from the application source and runs temporary-directory fixtures. A build and
nested-helper configuration check are separate validations.
