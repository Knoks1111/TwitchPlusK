# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchPlusK

# ── Fichiers source (auto-détectés dans tout le projet) ──
# ⚠️ TEMPORAIRE — le projet est en cours de rangement (racine plate
# avec ~40 fichiers .m/.h → arborescence par domaine, ex: Sources/Chat,
# Sources/Emotes, Sources/Moderation, Sources/Network, Sources/UI...).
# Tant que le rangement n'est pas terminé, ce Makefile cherche PARTOUT
# dans le repo pour ne rien casser pendant la transition.
#
# UNE FOIS le rangement terminé et TOUS les fichiers déplacés dans
# Sources/ (plus aucun .m/.h à la racine 
# il faut resserrer le scope pour ne chercher que
# dans Sources/ — ça évite de compiler par erreur un fichier oublié
# ailleurs (backup, brouillon, dossier de test) et ça documente
# clairement où vit le code source du projet :
#
#   TwitchPlusK_FILES = $(shell find Sources -name '*.m')
#   TwitchPlusK_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR) \
#       -I$(THEOS_PROJECT_DIR)/Sources \
#       $(shell find Sources -type d -exec echo -I{} \;) \
#       -Wno-unused-variable -Wno-unused-function
#
# Cherche tous les .m où qu'ils soient, en excluant les dossiers
# techniques qui ne doivent jamais être compilés.
TwitchPlusK_FILES = $(shell find . \
    -name '*.m' \
    -not -path './.theos/*' \
    -not -path './.git/*' \
    -not -path './packages/*')

# ── Options de compilation ──
# Ajoute automatiquement TOUS les dossiers du projet aux chemins
# d'include, donc #import "Fichier.h" marche peu importe où se
# trouve Fichier.h par rapport au fichier qui l'importe.
TwitchPlusK_CFLAGS = \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    $(shell find . -type d \
        -not -path './.theos*' \
        -not -path './.git*' \
        -not -path './packages*' \
        -exec echo -I{} \;) \
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