# SNES ROM hacks

Choose **File → Add ROM Hack…**, or drop one `.ips`, `.bps` or `.ups` patch into the library. Select a system, then an uncompressed base from the searchable library list, or use **Locate Uncompressed Base ROM…** for a supported file that is not imported. Name the new game and choose **Add ROM Hack**.

BPS searches for an unambiguous checksum-verified base in the library. It checks the patch, source and output CRC32 values. A 512-byte SNES copier header is removed from a working copy only when the headerless source matches the patch checksum. A mismatch stops import; no forced-checksum option is provided.

IPS has no source or output checksum. The window explicitly marks its base as unverified. Follow the patch author's region/revision and copier-header instructions. Header removal is an explicit option and applies only to the copy. Check that the resulting game plays correctly before investing time in it.

## Original files and saves

The source ROM and patch are opened read-only. Each import gets a new UUID-named ROM and its own library game, displayed with a `[ROM Hack]` suffix. Both the core battery-save filename and the library's save-state folder derive from that unique ROM filename; no original saves are copied, renamed or overwritten.

Files live under the configured ROM library's selected-system folder, in `ROM Hacks/<UUID>/`. Each folder contains the generated ROM (with the selected system’s extension), a retained patch and `manifest.json`, recording base/patch/output SHA-256, patch format, header transformation and engine version. Custom library locations are respected. No application-data root is hardcoded.

Patching runs away from the main UI thread, supports cancellation, and limits each input/output to 32 MB. Failed/canceled patching removes its own partial output. Metadata lookup is not queued for generated entries, so it does not replace the hack title with the base title. Importing the same patch again deliberately creates another independent variant; use the existing library entry to keep its progress.

## Current boundaries

SNES supports IPS/BPS/UPS. NES, Game Boy/Color, GBA, Genesis/Mega Drive, Master System and Game Gear are marked **Experimental** and support the same patch formats. Genesis requires raw `.md`, `.bin` or `.gen` files; interleaved `.smd` files are excluded. NES headers and non-SNES copier headers are preserved byte-for-byte; no automatic conversion is attempted. UPS validates patch/source/output CRC32 and applies forward only. BPS and UPS search the selected system’s library for a verified base. Archive extraction, other patch formats, a dedicated variant-detail editor, metadata catalogs and explicit save transfer are future work. Applying a patch does not qualify that hack for network play; existing netplay compatibility restrictions still apply.

The decoder is implemented in Swift without a new patch-library dependency. BPS format reference: [byuu's public-domain BPS specification](https://github.com/Sir-Walrus/Flips/blob/master/bps_spec.md). IPS includes literal/RLE records and the optional final-size footer.

## Validation

Run `bash Scripts/check-rom-patches.sh` for synthetic known-answer fixtures, BPS copy modes, malformed input, checksum failure, cancellation, SNES header handling, and original ROM/save preservation. Native UI validation used a separate bundle identity and data folder, imported IPS and BPS fixtures, verified automatic BPS matching, persisted library records, output hashes and distinct filenames. Real community-game playback and netplay remain separate validation steps; synthetic fixtures are not playable games.

The importer warns about plausible SNES headers displaced by 512 bytes without rejecting or rewriting the ROM. Missing or stale ROM checksums alone do not trigger the warning. Experimental means patching is available but community-game compatibility has not been broadly validated.

## Already-patched games and artwork

Right-click a single game in grid or list view and choose **Use Base Game Artwork…**. Search games with local artwork, choose a base cover, and enter a mod name. The preview updates before applying. Same-system games appear first. Apply creates a separate cover image with a MOD badge and name strip; Cancel makes no changes. The selected game’s ROM, title, system, and saves are not changed, and the base cover is not modified. This is an explicit visual association, not a checksum or compatibility claim.
