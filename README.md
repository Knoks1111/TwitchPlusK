# TwitchPlusK

Enhanced Twitch chat for iOS — 7TV emotes & badges, auto-claim channel points, and ad blocking. Sideloaded, no jailbreak required.

## Install

1. **[Download the latest IPA](https://github.com/Knoks1111/TwitchPlusK/releases/latest)** (scroll to Assets, grab the `.ipa` file)
2. Transfer it to your iPhone (AirDrop, iCloud Drive, Files app — whatever works for you)
3. Open **SideStore** on your iPhone
4. If you already have Twitch installed via SideStore, delete it first
5. In SideStore, tap **Import** (or the **+** button) and select the IPA you downloaded
6. Wait for the install to finish, then launch Twitch

That's it. New releases follow new Twitch app versions — check back on the releases page when Twitch updates.

## Build it yourself

If you want to build from source instead of using the prebuilt release:

1. **Fork this repository**
2. Go to the **Actions** tab of your fork
3. Run **Build Dylib TwitchPlusK** first — this compiles the tweak and produces a `.dylib` artifact
4. Once it finishes, open the run and copy the link to the `.dylib` artifact
5. Run **Build IPA (injection dylib)**, and when prompted, paste:
   - the `.dylib` artifact link from step 4
   - a direct download link to a Twitch IPA
6. Once it finishes, the patched IPA is published straight to your fork's **Releases** page

## Legal

Educational project. Using modified apps may violate Twitch's Terms of Service. Use at your own risk.
