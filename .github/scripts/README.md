# Shared update source

`update.json` serves both the tweak's update checker (`version` at the root)
and AltStore Classic / SideStore (`apps`). Do not replace it with a version-only file.

The source lists the latest published IPA only, keeping the manifest below the
existing tweak updater's 16 KiB limit. Older iOS releases have no historical IPA
fallback in this source.

`Build IPA (final)` stamps both `CFBundleShortVersionString` and `CFBundleVersion`
in the main app and its extensions with the TwitchPlusK release version.
The original values are preserved as `TPKOriginalTwitchVersion` and
`TPKOriginalTwitchBuild` for Twitch version labels, diagnostics and release naming.
The source uses the same release version in `versions` and legacy app-level fields,
so clients can display tweak updates even when the Twitch version is unchanged.
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
