# Upstream provenance (moteur Local / VAFT)

- Projet upstream natif : `BananaOnGitHub/TwitchAdBlock-VAFT-iOS` (Apache-2.0)
  - Port version : **2.2.0**
  - Stratégie : VAFT solution 24 (`pixeltris/TwitchAdSolutions`)
  - Commit upstream stratégie : `c51ef2fe8f667f9dc9216eb550924cf0d732ce27`
  - SHA-256 du script upstream copié : `8ba15a99627c3d2a8fab3c3011b43d68ecb89eb40af549b0052d98449f02f591`
- Fichiers importés ici :
  - `TwitchAdBlock.c/.h` — moteur d'interception/VAFT (quasi verbatim)
  - `TASDiagnostics.c/.h` — diagnostics assainis (quasi verbatim)

## Adaptations TwitchPlusK (algorithmiquement neutres)

| Div | Upstream | TwitchPlusK | Raison |
|-----|----------|-------------|--------|
| D1 | `__attribute__((constructor)) tas_initialize` | `vaft_initialize()` appelé par `S7TVAdblockInstallRuntimeHooks` si méthode active = Local | Un seul constructeur possible ; exclusivité Proxy/Local |
| D2 | Pas de toggle maître | Gates O(1) sur snapshot (`S7TVAdblockEnabledFast`) aux 3 points d'entrée (`protocol_can_init`, `asset_init`, `normalized_graphql_request_copy`) | Toggle maître TwitchPlusK ; zéro lecture prefs en hot path |
| D3 | Hooks Foundation installés inconditionnellement | Installés seulement si actif = Local | Exclusivité Proxy/Local |
| D5 | `tas_diagnostics_initialize` complet (injection App Settings + fallback + notice) | Réduit à `register_log_class()` + log PORT_LOADED ; contrôles vivant dans la page Logs TwitchPlusK | Page Ad Block VAFT non importée |

Le reste du code est conservé tel quel (fonctions, structures, constantes,
ordre des opérations, retries, TTLs, rings, locking, snapshots).