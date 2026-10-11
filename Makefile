# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TWITCHPLUSK_VERSION = 2.0.0
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
    Sources/Logs/tpK-logs-controller.m \
    Sources/Chat/tpK-chat-appearance-config.m \
    Sources/Chat/tpK-chat-custom-view.m \
    Sources/Chat/tpK-chat-integration.m \
    Sources/Chat/tpK-chat-custom-vod.m \
    Sources/Chat/tpK-chat-message.m \
    Sources/Chat/tpK-chat-reply-thread-panel.m \
    Sources/Chat/tpK-chat-tokenizer.m \
    Sources/Emote/tpK-emote-animation-engine.m \
    Sources/Emote/tpK-emote-catalog.m \
    Sources/Emote/tpK-emote-image-cache.m \
    Sources/Emote/tpK-emote-provider.m \
    Sources/Emote/tpK-provider-settings.m \
    Sources/Emote/tpK-badge-provider.m \
    Sources/Emote/tpK-network-emote-cache.m \
    Sources/Picker/tpK-picker-cell.m \
    Sources/Picker/tpK-picker-controller.m \
    Sources/Picker/tpK-picker-resolved-emote.m \
    Sources/Picker/tpK-picker-settings-panel.m \
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
TwitchPlusK_CFLAGS := \
    -DTPK_BUILD_VERSION='"$(TWITCHPLUSK_VERSION)"' \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    -I$(THEOS_PROJECT_DIR)/Sources \
    -Wno-unused-variable \
    -Wno-unused-function

# ── Options linker ──
TwitchPlusK_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchPlusK_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO AVFoundation MediaPlayer

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
