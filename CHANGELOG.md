# TwitchPlusK Changelog

This file keeps the cumulative release history of TwitchPlusK, with the newest release listed first.

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
