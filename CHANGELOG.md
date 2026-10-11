# TwitchPlusK Changelog

This file keeps the cumulative release history of TwitchPlusK, with the newest release listed first.

## [2.0.0] (Twitch 31.5) - 2026-10-11

> Back up your settings from the transfer screen BEFORE updating: settings were reset for 2.0.0, and your old backup can be re-imported afterwards if needed.

Twitch 31.5 rebuilds large parts of the app in React Native, which broke a lot of TwitchPlusK features. This release brings everything back: chat, player, gestures, OLED mode, channel detection, auto-claim and more were reworked for the new architecture, alongside the usual round of fixes and polish. If you run into any issue, even a small one, please report it with as much detail as possible — it really helps.

### New Features

- Added a new Proxy + Local (VAFT) combo mode for networks blocking live or 1440p: relay proxy for access and quality, VAFT for local ad decisions, with its own separate proxy list.
- Chat announcements now render with colored side bars, a megaphone header and the full message body.

### Changed

- Settings: mixed-providers row and "All" tab now show the TwitchPlusK logo, player controls icons have their own colors with a tap icon for gestures, Chat custom labeled as debug with its info bubble removed, all popups now use the accent color, and the floating button is now black with a white outline and the TwitchPlusK logo.
- First message and mention highlights now sit flush against the accent bar, with no empty icon gap.
- Cleaned up the diagnostics screen so it accurately reports hook status on current Twitch versions.
- Removed the legacy _TtC6Twitch27AssetResourceLoaderDelegate hook (Twitch's old stream resource-loader class, long gone from the app) and its diagnostics entry — proxy adblocking now runs entirely through our own loader.
- Renamed all internal symbols, files and settings keys from 7TV/S7TV to TPK for the 2.0.0 codebase.
- Settings start fresh on this version (no automatic migration), but backups from older versions can still be imported from the settings transfer screen, with old keys translated automatically.
- Default video and emote proxy lists trimmed to the reliable endpoints, with the extra relays moved to the opt-in Proxy + Local combo list.
- Built IPAs are now named with both versions (`twitchplusk-vX-twitch-Y.ipa`) so the TwitchPlusK version is visible directly from the file name.

### Fixes

- Fixed player controls and overlays for Twitch 31.5: custom buttons appear in the video, the Lock bubble follows rotation while preserving its VOD placement, the stats panel stays draggable when controls hide, and Refresh reloads the active IVS stream URL.
- OLED mode stopped applying across most React Native surfaces after Twitch’s rendering changes; the targeted hooks were updated to restore the dark backgrounds.
- Twitch’s Bits button became a React Native component, breaking the old replacement; the new component is now replaced with the TwitchPlusK picker button.
- Twitch’s player rework broke gesture detection and re-enabled the swipe-down that opens the dock; detection was retargeted so brightness and volume respond again on the stream page, the dock swipe is blocked all the way down, and the value HUD now stays glued to the video through rotations.
- Fixed the TwitchPlusK entry not appearing in the native Twitch settings and causing crash.
- Fixed live channel detection on recent Twitch versions, restoring channel emotes, badges, and channel-dependent features.
- Restored live chat on recent Twitch versions with support for the React Native chat socket.
- Restored Channel Points auto-claim on recent Twitch versions by detecting the React Native claim chest and tapping it, with balance-change logging. If anything misbehaves, please send the Channel Points logs from TwitchPlusK Advanced settings.
- Fixed launch destinations for the Home section, currently the only part rebuilt in React Native.
- Chat stays pinned to the bottom when rotating the phone.
- Fixed the size-panel live chat preview not showing with the new chat, and touches on it no longer trigger the stream gestures behind it.
- Fixed the reply thread panel and the standalone reply preview not following the keyboard and rotation: both are now hosted inside the custom chat itself, so they track it automatically with no manual repositioning.
- Fixed the "new messages" pill rendering tiny with clipped text: it is now sized from the custom chat instead of the narrow text input.
- Fixed the size-panel live chat preview misplacing itself above the chat input: it now measures the settled input bar position before placing, so it no longer lands on the old position when the keyboard opens or the phone rotates.

## [1.0.8] (Twitch 31.0.2) - 2026-10-07

### New Features

- Added support for prefix-style video proxies (e.g. rte.net.ru) alongside Luminous, enabling 1440p playback with automatic auth token.
- Added an independent emote proxy for countries where 7TV, BTTV, or FFZ are blocked, with its own proxy selection.
- Added 4 new default video proxies.

## [1.0.7] (Twitch 31.0.2) - 2026-10-03

### New Features

- Emote picker height can now be set independently for portrait and landscape, each with its own adjustable range — so the picker stays compact in landscape and keeps a comfortable size in portrait.
- The size of the emotes in the picker can now be adjusted, with independent settings for portrait and landscape.
- Chat elements to hide now also removes the bar with the Subscribe and Gift Sub buttons, clearing up the top of the chat entirely.

### Fixes

- Fixed chat elements not being fully removed: hidden banners now detach from the interface instead of staying visible, subclasses are matched correctly.

## [1.0.6] (Twitch 31.0.2) - 2026-09-24

### New Features

- Added tab bar customization (Appearance → Interface → Tab Bar & Launch) to hide any tab (Home, Browse, Create, Activity or Profile) from Twitch's main bar, with the remaining tabs redistributing natively without flicker.
- Added grouped settings (Appearance → Interface → Chat elements to hide) to hide pinned messages and announcements, or creator goals and leaderboard banners.
- reduced the message display delay from 150 ms to 50 ms for faster updates.

### Changed

- Improved the custom launch screen and tab bar settings page: merged into a single page with a permanent description, Launch/Visible column headers, per-tab colored icons, and automatic remapping of the launch destination when its tab gets hidden.
- Removed unnecessary logs and cleaned up the Advanced settings category.
- Cleaned up the Diagnostics screen by removing duplicate entries and adding missing hook checks for channel resolution and player tools.

### Fixes

- Fixed various UI issues in the tab bar settings page (duplicate icons, wrong chevron color, alignment and text overflow).
- Fixed auto-lock crashes when leaving the app or entering Picture in Picture.

## [1.0.5] (Twitch 31.0.2) - 2026-09-15

### New Features

- Added a GitHub repository link to the settings.
- Added a dedicated TwitchPlusK logo, replacing the 7TV logo in the tweak’s own UI.
- Added in-app update notifications with a direct link to the latest release.

### Fixes

- Fixed orientation lock visual rotation visual bug and corrected the lock/unlock overlay position during rotation.
- Fixed the keyboard and word suggestions being invisible in OLED mode on iOS 27.

## [1.0.4] (Twitch 31.0.2) - 2026-09-13

### New Features

- Added a delay button to show latency and reload the stream.
- Added a movable Video Player Stats panel with key stream stats.
- Added volume and brightness gestures to the video player, with configurable sides, sensitivity and dead zone.
- Added fake brightness, allowing the screen to go below iOS minimum brightness down to -70%.
- Added custom chat support for VODs.
- Targeted subscription gifts are now supported in chat.
- Improved the visual design of subscription messages.

### Fixes

- Reworked channel detection for reliable rapid channel switching.
- Fixed player delay and stats buttons appearing on VODs.
- Fix Chat preview now shows all messages.
- Deleted messages keep their badges and visual effects.
- Fixed various bugs and stability issues across the app.

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
