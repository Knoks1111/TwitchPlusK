<p align="center">
  <img src="Assets/twitchplusk-icon.webp" width="110" alt="TwitchPlusK icon">
</p>

<h1 align="center">TwitchPlusK</h1>

<p align="center">
  A better Twitch experience for iOS.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/Twitch-9146FF?style=for-the-badge&logo=twitch&logoColor=white" alt="Twitch">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/-GPLv3-000000?style=for-the-badge&logo=gnu&logoColor=white" alt="GPLv3 License">
  </a>
</p>

<p align="center">
  <a href="https://github.com/Knoks1111/TwitchPlusK/releases">Releases</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="LICENSE">License</a>
</p>

<p align="center">
  <img src="Assets/01-live-chat-and-subscriptions.png" width="19%" alt="Live chat and subscriptions">
  <img src="Assets/02-chat-and-emote-picker.png" width="19%" alt="Chat and emote picker">
  <img src="Assets/03-chat-and-picker-customization.png" width="19%" alt="Chat and picker customization">
  <img src="Assets/04-settings-overview.png" width="19%" alt="Settings overview">
  <img src="Assets/05-player-and-playback-settings.png" width="19%" alt="Player and playback settings">
</p>

TwitchPlusK is a tweak for the official Twitch iOS app. It keeps the native app and adds a fully customizable chat, 7TV/BTTV/FFZ emotes, adblock, Channel Points Auto Claim, OLED mode and more.

Prebuilt IPAs are available in [Releases](https://github.com/Knoks1111/TwitchPlusK/releases) and can be installed with SideStore or LiveContainer.

Available in <img src="https://flagcdn.com/gb.svg" width="20"> **ENGLISH** and <img src="https://flagcdn.com/fr.svg" width="20"> **FRENCH** from the Settings menu.

Full CHANGELOG : [CHANGELOG.md](https://github.com/Knoks1111/TwitchPlusK/blob/main/CHANGELOG.md)

## What it does

### Chat and emotes

- Provides a fully customizable chat renderer that supports Twitch's native chat features while adding extras such as first-time chatter highlighting and more.
- Adds **7TV, BTTV, and FFZ emotes** to Twitch chat with a custom emote picker.
- Supports favorites, animated emotes, Zero-Width emotes, replies, and threads.

### Ad blocking

- Includes two different AdBlock methods:
  - **Proxy** — uses a default or custom video proxy.
  - **Local (VAFT)** — uses a local ad-blocking engine without a video proxy.

### App customization

- Adds **OLED Mode**, launch screen controls, Stories hiding, Live Feed continuity, Orientation Lock, and more.
- Includes settings export/import, automatic **Channel Points Auto Claim**, and more.

## Install

1. [Download the latest IPA](https://github.com/Knoks1111/TwitchPlusK/releases/latest)
2. Install it with SideStore or LiveContainer 

New releases follow new Twitch app versions — check the Releases page when Twitch updates.

## Build it yourself

If you want to build from source instead of using the prebuilt release:

1. Fork this repository.
2. Go to the **Actions** tab of your fork.
3. Run **Build Dylib** first — this compiles the tweak and produces a `.dylib` artifact.
4. Once it finishes, open the run and copy the link to the `.dylib` artifact.
5. Run **Build IPA (final)** and, when prompted, paste:
   - the `.dylib` artifact link from step 4
   - a direct download link to a Twitch IPA
6. Once it finishes, the patched IPA is published directly to your fork's Releases page.
7. Install it with SideStore or LiveContainer
## Legal

Educational project. Using modified apps may violate Twitch's Terms of Service. Use at your own risk.
