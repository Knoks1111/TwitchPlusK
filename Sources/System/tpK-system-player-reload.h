#ifndef TPK_SYSTEM_PLAYER_RELOAD_H
#define TPK_SYSTEM_PLAYER_RELOAD_H

#import <UIKit/UIKit.h>

/// Recognizes the legacy UIKit controls and the current React Native player overlay.
BOOL tpk_isPlayerControlsContainer(UIView *view);
BOOL tpk_isReactPlayerControlsContainer(UIView *view);

/// Finds the stable view hosting Twitch's current player.
UIView *tpk_playerTheaterHostForView(UIView *view);

/// Shared native button row attached to a React Native player controls overlay.
UIStackView *tpk_playerReactControlsButtonStack(UIView *view);

/// Whether the player tools are enabled.
BOOL tpk_playerToolsEnabled(void);

/// Whether player statistics are enabled.
BOOL tpk_playerStatsEnabled(void);

/// Enables or hides both player tools.
void tpk_setPlayerToolsEnabled(BOOL enabled);

/// Enables or hides player statistics.
void tpk_setPlayerStatsEnabled(BOOL enabled);

/// Installs the delay button on Twitch player controls.
void tpk_handlePlayerReloadViewLifecycle(UIView *view);

/// Installs hooks used by the player controls.
void tpk_setupPlayerReloadRuntimeHooks(void);

/// Associates the player theater with a live or VOD chat context.
void tpk_setPlayerReloadVODState(UIView *view, BOOL isVOD);

#endif
