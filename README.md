# TwitchPlusK

Enhanced Twitch app for iOS — 7TV emotes, auto-claim channel points, and ad blocking. Sideloaded, no jailbreak required.

## What it does

TwitchPlusK adds 7TV, ad blocking, and quality-of-life features directly to the native Twitch iOS app.

### Enhanced chat

- **7TV emotes** with animated emotes and their original aspect ratios.
- Fully **custom chat renderer** with configurable emote size, text size, spacing, and appearance.
- Built-in **7TV emote picker**.
- Support for Twitch badges, replies, deleted messages, Channel Point messages, and other Twitch chat events.

### Ad blocking

- Blocks ads on **live streams and VODs** using an ad-free-country proxy.
- Built-in proxy with support for your own custom proxy.
- Removes additional Twitch ad and promotional elements from the app.

### Channel Points

- **Automatically claims Channel Point bonuses** while watching streams.

### Player

- **Orientation Lock** directly from the Twitch player.
- Optional automatic landscape lock.

### App customization

- **Choose your launch screen** — Following, Live, Clips, Browse, Activity, Profile, and more.
- **Hide Twitch Stories** from Home.
- **Keep Live Feed Playing** without Twitch forcing you to Watch or Follow.

## Install

1. [Download the latest IPA](https://github.com/Knoks1111/TwitchPlusK/releases/latest)
2. Install it with SideStore
3. First launch: go to Settings → General → VPN & Device Management and trust the profile, or the app won't open

New releases follow new Twitch app versions — check back on the releases page when Twitch updates.

## Build it yourself

If you want to build from source instead of using the prebuilt release:

1. Fork this repository
2. Go to the Actions tab of your fork
3. Run **Build Dylib** first — this compiles the tweak and produces a `.dylib` artifact
4. Once it finishes, open the run and copy the link to the `.dylib` artifact
5. Run **Build IPA (final)**, and when prompted, paste:
   - the `.dylib` artifact link from step 4
   - a direct download link to a Twitch IPA
6. Once it finishes, the patched IPA is published straight to your fork's Releases page

## Legal

Educational project. Using modified apps may violate Twitch's Terms of Service. Use at your own risk.