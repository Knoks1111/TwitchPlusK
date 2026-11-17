# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TWITCHPLUSK_VERSION = 2.0.4
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchPlusK

# ── Fichiers source regroupés par domaine ──
TwitchPlusK_FILES = \
    Sources/Adblock/tpK-adblock-settings.m \
    Sources/Adblock/Proxy/tpK-adblock-proxy-status.m \
    Sources/Adblock/Proxy/tpK-adblock-data.m \
    Sources/Adblock/Proxy/tpK-adblock-proxy.m \
    Sources/Adblock/Proxy/tpK-adblock-resource-loader.m \
    Sources/Adblock/tpK-adblock-runtime.m \
    Sources/Adblock/Emote/tpK-adblock-emote-proxy.m \
    Sources/Adblock/Combo/tpK-adblock-combo.m \
    Sources/Settings/tpK-hook-diagnostics.m \
    Sources/Settings/tpK-tap-logger.m \
    Sources/Adblock/Proxy/Fishhook/fishhook.c \
    Sources/Adblock/Vaft/TwitchAdBlock.c \
    Sources/Adblock/Vaft/TASDiagnostics.c \
    Sources/Core/tpK-core-runtime-hooks.m \
    Sources/Core/tpK-core-manager.m \
    Sources/Core/tpK-channel-resolver.m \
    Sources/Settings/tpK-settings-controller.m \
    Sources/Settings/tpK-settings-transfer.m \
    Sources/Settings/tpK-logs-controller.m \
    Sources/Settings/tpK-chat-appearance-config.m \
    Sources/Chat/tpK-chat-runtime.mm \
    Sources/Chat/Emote/RNLive/tpK-chat-emotes.mm \
    Sources/Chat/Emote/tpK-chat-emote-images.m \
    Sources/Chat/Emote/UIKit/VOD/tpK-chat-vod-emotes.m \
    Sources/Chat/Emote/UIKit/LegacyLive/tpK-chat-legacy-emotes.m \
    Sources/Chat/Emote/UIKit/tpK-chat-uikit-emote-size.m \
    Sources/Chat/Emote/RNLive/tpK-chat-emote-size.mm \
    Sources/Chat/Emote/RNLive/tpK-chat-emote-animation.m \
    Sources/Chat/FirstChatter/tpK-native-first-chatter.mm \
    Sources/Chat/Appearance/tpK-chat-event-appearance.m \
    Sources/Chat/DeletedMessages/tpK-native-deleted-messages.mm \
    Sources/Emote/tpK-emote-animation-engine.m \
    Sources/Emote/tpK-emote-catalog.m \
    Sources/Emote/tpK-emote-image-cache.m \
    Sources/Emote/tpK-emote-image-transport.m \
    Sources/Picker/tpK-picker-settings.m \
    Sources/Picker/tpK-picker-channel-avatar.m \
    Sources/Picker/tpK-picker-cell.m \
    Sources/Picker/tpK-picker-controller.m \
    Sources/Picker/tpK-picker-resolved-emote.m \
    Sources/Localization/tpK-localization-manager.m \
    Sources/System/tpK-system-home-features.m \
    Sources/System/tpK-system-native-behavior-hooks.m \
    Sources/System/tpK-system-player-gestures.m \
    Sources/System/tpK-system-player-reload.m \
    Sources/System/tpK-system-tab-visibility.m \
    Sources/System/tpK-system-autoclaim.m \
    Sources/System/tpK-system-update-checker.m \
    Sources/UI/tpK-info-tooltip.m \
    Sources/UI/tpK-oled-mode.m

# ── Options de compilation ──
TPK_LOCALIZATION_DIR = $(THEOS_PROJECT_DIR)/Sources/Localization/Languages
TPK_LOCALIZATION_HEADER = $(THEOS_PROJECT_DIR)/.theos/localization/tpk-localization-data.h

Sources/Adblock/Vaft/TwitchAdBlock.c_CFLAGS = -fblocks
Sources/Adblock/Vaft/TASDiagnostics.c_CFLAGS = -x objective-c -fno-objc-arc -fblocks
Sources/Chat/tpK-chat-runtime.mm_CFLAGS = -std=c++17 -I$(THEOS_PROJECT_DIR)/Sources/Chat/JSI
Sources/Chat/Emote/RNLive/tpK-chat-emote-size.mm_CFLAGS = -std=c++17 -I$(THEOS_PROJECT_DIR)/Sources/Chat/JSI
Sources/Chat/FirstChatter/tpK-native-first-chatter.mm_CFLAGS = -std=c++17 -I$(THEOS_PROJECT_DIR)/Sources/Chat/JSI
Sources/Chat/DeletedMessages/tpK-native-deleted-messages.mm_CFLAGS = -std=c++17 -I$(THEOS_PROJECT_DIR)/Sources/Chat/JSI

TwitchPlusK_CFLAGS := \
    -DTPK_BUILD_VERSION='"$(TWITCHPLUSK_VERSION)"' \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    -I$(THEOS_PROJECT_DIR)/Sources \
    -I$(THEOS_PROJECT_DIR)/.theos/localization \
    -Wno-unused-variable \
    -Wno-unused-function

# ── Options linker ──
TwitchPlusK_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchPlusK_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO AVFoundation MediaPlayer
TwitchPlusK_LIBRARIES = c++

include $(THEOS_MAKE_PATH)/library.mk

$(TPK_LOCALIZATION_HEADER): $(wildcard $(TPK_LOCALIZATION_DIR)/*.strings) $(TPK_LOCALIZATION_DIR) $(THEOS_PROJECT_DIR)/Sources/Localization/compile_localizations.py
	@python3 "$(THEOS_PROJECT_DIR)/Sources/Localization/compile_localizations.py" --input "$(TPK_LOCALIZATION_DIR)" --output "$@"

Sources/Localization/tpK-localization-manager.m $(THEOS_PROJECT_DIR)/Sources/Localization/tpK-localization-manager.m: $(TPK_LOCALIZATION_HEADER)

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
