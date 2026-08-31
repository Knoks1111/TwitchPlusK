# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchPlusK

# ── Fichiers source regroupés par domaine ──
TwitchPlusK_FILES = \
    Sources/Adblock/7tv-adblock-settings.m \
    Sources/Adblock/Proxy/7tv-adblock-proxy-status.m \
    Sources/Adblock/Proxy/7tv-adblock-data.m \
    Sources/Adblock/Proxy/7tv-adblock-proxy.m \
    Sources/Adblock/Proxy/7tv-adblock-resource-loader.m \
    Sources/Adblock/7tv-adblock-runtime.m \
    Sources/Diagnostics/7tv-hook-diagnostics.m \
    Sources/Adblock/Proxy/Fishhook/fishhook.c \
    Sources/Adblock/Vaft/TwitchAdBlock.c \
    Sources/Adblock/Vaft/TASDiagnostics.c \
    Sources/Core/7tv-core-runtime-hooks.m \
    Sources/Core/7tv-core-manager.m \
    Sources/Network/7tv-network-emote-cache.m \
    Sources/Settings/7tv-settings-controller.m \
    Sources/Settings/7tv-settings-transfer.m \
    Sources/Logs/7tv-logs-controller.m \
    Sources/Chat/7tv-chat-appearance-config.m \
    Sources/Chat/7tv-chat-custom-view.m \
    Sources/Chat/7tv-chat-message.m \
    Sources/Chat/7tv-chat-reply-thread-panel.m \
    Sources/Chat/7tv-chat-tokenizer.m \
    Sources/Emote/7tv-emote-animation-engine.m \
    Sources/Emote/7tv-emote-catalog.m \
    Sources/Emote/7tv-emote-image-cache.m \
    Sources/Emote/7tv-emote-provider.m \
    Sources/Emote/7tv-provider-settings.m \
    Sources/Badge/7tv-badge-provider.m \
    Sources/Picker/7tv-picker-cell.m \
    Sources/Picker/7tv-picker-controller.m \
    Sources/Picker/7tv-picker-resolved-emote.m \
    Sources/Picker/7tv-picker-settings-panel.m \
    Sources/Localization/7tv-localization-manager.m \
    Sources/System/7tv-system-home-features.m \
    Sources/System/7tv-system-native-behavior-hooks.m \
    Sources/System/7tv-system-autoclaim.m \
    Sources/UI/7tv-info-tooltip.m \
    Sources/UI/7tv-oled-mode.m

# ── Options de compilation ──
TwitchPlusK_CFLAGS := \
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
TwitchPlusK_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO AVFoundation

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
