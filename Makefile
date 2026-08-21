# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchPlusK

# ── Headers ──
# ── Fichiers source ──
TwitchPlusK_FILES = \
    TweakSevenTV.m \
    SevenTVManager.m \
    7tv-picker-controler.m \
    7tv-picker-sizes.m \
    7tv-picker-cell.m \
    7tv-picker-resolved-emote.m \
    7tv-localization.m \
    SevenTVURLProtocol.m \
    SevenTVSettingsController.m \
    SevenTVLogsController.m \
    SevenTVChatMessage.m \
    SevenTVChatAppearanceConfig.m \
    SevenTVChatCustomView.m \
    7tv-chat-ReplyThreadPanel.m \
    7tv-system-NativeBehaviorHooks.m \
    SevenTVEmoteProvider.m \
    SevenTVChatTokenizer.m \
    SevenTVEmoteImageCache.m \
    SevenTVEmoteAnimationEngine.m \
    SevenTVBadgeProvider.m

# ── Options de compilation ──
TwitchPlusK_CFLAGS = \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    -Wno-unused-variable \
    -Wno-unused-function

# ── Options linker ──
TwitchPlusK_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchPlusK_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
