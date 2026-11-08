# Shared update source

`update.json` serves both the tweak's update checker (`version` at the root)
and AltStore Classic / SideStore (`apps`). Do not replace it with a version-only file.

The source retains previous releases, replacing an entry when its IPA URL is rebuilt,
and sorts them by release date. The latest release also populates legacy app-level
fields. Generation refuses a manifest above the tweak updater's 16 KiB limit.

`Build IPA (final)` sets the actual `CFBundleShortVersionString` to
`<original Twitch major.minor>.<major * 10000 + minor * 100 + patch>` using
the TwitchPlusK release version, for example `31.9.20003` for Twitch 31.9 / TwitchPlusK 2.0.3.
The generator requires a two-component original Twitch version and reads this exact
stamped version into the source's `version` field. The IPA filename and release tag
still use the original Twitch version, allowing a rebuild to replace the same release asset.
It sets
`CFBundleVersion` to the original Twitch build plus `major * 10000 + minor * 100 + patch`
for the TwitchPlusK release (minor and patch must be at most 99). Non-numeric original
builds receive the offset as a dotted suffix. The same calculation is applied to extensions.
The original values are preserved as `TPKOriginalTwitchVersion` and
`TPKOriginalTwitchBuild` for Twitch version labels, diagnostics and release naming.
The source reads the exact version/build from the final IPA and includes the tweak
version in release descriptions and `marketingVersion`. The stamped app version also
changes for tweak-only updates. Only the `31.9.20003` probe has been confirmed to launch
on device; do not replace the entire Twitch version with the tweak version alone.
The generator reads the final IPA's versions, size,
minimum iOS version, privacy descriptions and signed entitlements, including
extensions. A failed metadata check stops source preparation.

After uploading the IPA, the workflow checks the release asset and attaches the
prepared JSON as the `shared-update-source` Actions artifact. To also commit it
to `main`, explicitly enable **publish_source** when running the workflow from
`main`. That option defaults to false, requires the input version to match the
Makefile, and refuses to lower the current root version. Branch protection can
prevent the commit; the JSON artifact remains available for review.

To prepare the file manually with Python 3.9+ and `ldid` installed:

```sh
python3 .github/scripts/update_source.py generate \
  tpK-2.0.1-Twitch-31.5.ipa 2.0.1 2026-10-11T18:17:11Z
```

Use the actual public release date. Generation does not upload or commit anything.

Format reference: [AltStore source documentation](https://faq.altstore.io/developers/make-a-source).
