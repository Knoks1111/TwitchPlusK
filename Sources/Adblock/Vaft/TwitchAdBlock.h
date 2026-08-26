/*
 * TwitchAdBlock VAFT for iOS — native port of pixeltris/TwitchAdSolutions
 * VAFT v24. Upstream: BananaOnGitHub/TwitchAdBlock-VAFT-iOS (Apache-2.0),
 * port version 2.2.0. Hosted in TwitchPlusK — see UPSTREAM.md.
 *
 * Divergence D1: vaft_initialize() is invoked by the host tweak's runtime
 * setup when Local is the active AdBlock method (no upstream constructor).
 */

#ifndef TAS_TWITCHADBLOCK_H
#define TAS_TWITCHADBLOCK_H

/* Installs the full VAFT interception stack (NSURLProtocol, Foundation
 * swizzles, AVURLAsset/resource-loader path) and initializes diagnostics. */
void vaft_initialize(void);

#endif /* TAS_TWITCHADBLOCK_H */