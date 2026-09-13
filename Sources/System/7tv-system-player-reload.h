#ifndef S7TV_SYSTEM_PLAYER_RELOAD_H
#define S7TV_SYSTEM_PLAYER_RELOAD_H

#import <UIKit/UIKit.h>

/// Whether the player tools are enabled.
BOOL s7tv_playerToolsEnabled(void);

/// Whether player statistics are enabled.
BOOL s7tv_playerStatsEnabled(void);

/// Enables or hides both player tools.
void s7tv_setPlayerToolsEnabled(BOOL enabled);

/// Enables or hides player statistics.
void s7tv_setPlayerStatsEnabled(BOOL enabled);

/// Installs the delay button on Twitch player controls.
void s7tv_handlePlayerReloadViewLifecycle(UIView *view);

/// Installs hooks used to capture the active IVS player.
void s7tv_setupPlayerReloadRuntimeHooks(void);

/// Associates the player theater with a live or VOD chat context.
void s7tv_setPlayerReloadVODState(UIView *view, BOOL isVOD);

#endif
