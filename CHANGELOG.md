# TwitchPlusK Changelog

This file keeps the cumulative release history of TwitchPlusK, with the newest release listed first.

## [1.0.3] (Twitch 31.0.2) - 2026-09-05

### New Features

- Added native viewer cards to the custom chat: tap any username to open their Twitch profile card directly.
- Added native Twitch GIF support in the custom chat.
- Added a configurable GIF size option.
- Added custom Twitch chat support for the other native chat overlay.
- Reworked emote caching: emotes are now cached on demand instead of pre-caching every channel emote when joining a channel, reducing startup delays, network traffic, and unnecessary memory/disk usage.

### Fixes

- Fixed the fake chat preview opening unexpectedly or remaining visible after closing the picker.
- Fixed chat messages sometimes appearing partially cut off.
- Improved OLED support for SwiftUI-hosted screens and viewer cards, with instant black backgrounds.
- Fixed thread layout so the main message stays fully visible and replies remain accessible in portrait and landscape mode.
- Fixed 7TV PC favorites import compatibility with nested export formats and future format variations.
- Improved moderation messages in the custom chat with French and English support.

## [1.0.2] (Twitch 30.9) - 2026-08-31

### New Features

- Rebuilt the emote system around a unified 7TV, BTTV, and FFZ architecture.
- Added BTTV and FrankerFaceZ emote support.
- Added provider tabs with Channel and Global sections.
- Added an optional mixed mode displaying all providers together.
- Added 7TV Zero-Width emote compositions with multiple overlay layers.
- Added provider-aware favorites for 7TV, BTTV, and FFZ.
- Added configurable provider priority for duplicate emote names.
- Added a shared emote resolution setting from 1X to 4X.
- Added provider logos to the picker and emote previews.
- Added independent 7TV, BTTV, and FFZ API diagnostics.
- Added selectable default video proxies.
- Added two additional default video proxies.
- Added manual and automatic proxy status checks.
- Completely rebuilt Channel Points Auto Claim from scratch.
- Added Auto Claim status and checks to Diagnostics.
- Added a restart notice when enabling or disabling OLED mode.

### Changed

- Native Twitch emotes remain prioritized over external providers.
- Mixed mode now interleaves providers instead of grouping them separately.
- Emotes are sorted consistently by size in every picker category.
- Added picker opening options:
  - Favorites
  - 7TV Channel
  - BTTV Channel
  - FFZ Channel
  - Last Used
- Replaced animation toggles with a three-option selector:
  - Disabled
  - Enabled
  - Favorites only
- Auto Claim Channel Points now works with both Proxy and Local (VAFT) AdBlock modes. [@appletrapz](https://github.com/appletrapz).
- Removed the previous behavior that disabled Auto Claim when AdBlock was enabled.
- Improved provider-aware cache handling and legacy data migration.
- Improved custom chat compatibility with emote sizing and rendering options.
- Improved OLED mode support for chat, emote previews, threads, and replies.
- Extended OLED Mode to the iOS keyboard for a true-black keyboard experience.

### Fixes

- Fixed emotes missing from the picker because they were shared between providers.
- Fixed emotes failing to load on the first picker opening.
- Fixed picker freezes during provider loading.
- Fixed Zero-Width favorites saving only the first emote.
- Fixed Zero-Width compositions not being reinserted correctly from favorites.
- Fixed provider information missing from emote previews.
- Fixed cache counts showing fewer cached emotes than actually stored.
- Fixed stale proxy checks incorrectly reporting proxies as online.
- Fixed custom proxy entries not being removable.
- Fixed settings text and category headers jumping when changing options.
- Improved rendering consistency across normal chat, replies, threads, and previews.
- Added various fixes and improvements across the app.

## [1.0.1] (Twitch 30.9) - 2026-08-27

### New Features

- Added OLED Mode with a true-black interface for OLED displays.
- Added Custom Home Screen controls for tailoring the Twitch landing experience.
- Added options to hide Twitch Stories and Twitch Turbo.
- Added an option to keep live playback running while using Watch or Follow actions.
- Added Proxy and Local (VAFT) AdBlock engines.
- Added a tool for clearing cached emote data.
- Added TwitchPlusK settings export and import.
- Added runtime hook diagnostics to help identify compatibility issues after Twitch updates.

### Changed

- Expanded custom chat support for newer Twitch chat events.
- Reworked thread handling in custom chat.
- Redesigned the TwitchPlusK settings interface and improved its organization.
- Improved AdBlock integration and compatibility with runtime hooks.

### Fixed

- Fixed landscape-mode chat scrolling and layout issues.
- Fixed several custom chat and emote picker issues.
- Fixed choppy scrolling caused by AdBlock Swift runtime hooks, with thanks to [@appletrapz](https://github.com/appletrapz).

### Performance

- Improved emote picker responsiveness.
- Reduced chat lag and made scrolling smoother.
- Improved overall TwitchPlusK compatibility and safeguards for future Twitch updates.
