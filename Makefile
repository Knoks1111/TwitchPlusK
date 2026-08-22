# ============================================================
# Makefile — TwitchPlusK (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchPlusK

# ── Fichiers source (auto-détectés dans le projet) ──
# ⚠️ TEMPORAIRE — le projet est en cours de rangement (racine plate
# avec ~40 fichiers .m/.h → arborescence par domaine, ex: Sources/Chat,
# Sources/Emotes, Sources/Moderation, Sources/Network, Sources/UI...).
# Tant que le rangement n'est pas terminé, ce Makefile cherche PARTOUT
# dans le repo (hors toolchain/build) pour ne rien casser en transition.
#
# UNE FOIS le rangement terminé et TOUS les fichiers déplacés dans
# Sources/ (plus aucun .m/.h à la racine sauf TweakSevenTV.m si tu le
# gardes à la racine), il faut resserrer le scope pour ne chercher que
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
# Cherche tous les .m du projet, en excluant explicitement:
#   - .theos/    (cache de build généré par Theos)
#   - .git/      (métadonnées git)
#   - theos/     (le TOOLCHAIN Theos lui-même, checké dans le repo —
#                 contient des SDKs et templates qui ne doivent JAMAIS
#                 être traités comme du code source du projet)
#   - packages/  (paquets .deb générés)
# Trié par taille décroissante (gros fichiers en premier) plutôt que
# par ordre alphabétique : avec la compilation parallèle (-j), ça évite
# qu'un seul gros fichier programmé en dernier fasse attendre tous les
# autres cœurs qui ont déjà fini leurs petits fichiers.
TwitchPlusK_FILES := $(shell find . \
    -name '*.m' \
    -not -path './.theos/*' \
    -not -path './.git/*' \
    -not -path './theos/*' \
    -not -path './packages/*' \
    -exec ls -S {} + 2>/dev/null)

# ── Options de compilation ──
# Ajoute comme chemin d'include chaque dossier du projet QUI CONTIENT
# AU MOINS UN HEADER (.h), en excluant les mêmes dossiers techniques
# que ci-dessus. On ne prend que les dossiers avec un .h dedans (et
# pas tous les dossiers du repo) pour éviter d'aspirer par erreur des
# répertoires contenant leurs propres module.modulemap (comme dans
# theos/) qui cassent la résolution des modules système de Clang.
TwitchPlusK_CFLAGS := \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    $(shell find . -name '*.h' \
        -not -path './.theos/*' \
        -not -path './.git/*' \
        -not -path './theos/*' \
        -not -path './packages/*' \
        -exec dirname {} \; | sort -u | sed 's/^/-I/') \
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