/*
 * TwitchPlusK — interface publique du moteur Local (VAFT).
 *
 * Séparation physique validée : tout l'algorithme VAFT vit dans ce dossier
 * (quasi verbatim upstream) ; les fichiers Proxy n'y touchent pas. Le seul
 * point de jonction est l'appel vaft_initialize() depuis
 * 7tv-adblock-runtime.m lorsque la méthode active est Local.
 *
 * Provenance et adaptations : voir UPSTREAM.md et les en-têtes des fichiers.
 */

#ifndef S7TV_ADBLOCK_VAFT_H
#define S7TV_ADBLOCK_VAFT_H

#include "TwitchAdBlock.h"
#include "TASDiagnostics.h"

#endif /* S7TV_ADBLOCK_VAFT_H */