# TwitchPlusK

Enhanced Twitch chat for iOS — 7TV emotes & badges, auto-claim channel points, and ad blocking. Sideloaded, no jailbreak required.

## Install

1. **[Download the latest IPA](https://github.com/Knoks1111/TwitchPlusK/releases/latest)**
2. Install it with **SideStore**
3. First launch: go to **Settings → General → VPN & Device Management** and trust the profile, or the app won't open

New releases follow new Twitch app versions — check back on the releases page when Twitch updates.

## Build it yourself

If you want to build from source instead of using the prebuilt release:

1. **Fork this repository**
2. Go to the **Actions** tab of your fork
3. Run **Build Dylib** first — this compiles the tweak and produces a `.dylib` artifact
4. Once it finishes, open the run and copy the link to the `.dylib` artifact
5. Run **Build IPA (final)**, and when prompted, paste:
   - the `.dylib` artifact link from step 4
   - a direct download link to a Twitch IPA
6. Once it finishes, the patched IPA is published straight to your fork's **Releases** page

## Legal

Educational project. Using modified apps may violate Twitch's Terms of Service. Use at your own risk.
