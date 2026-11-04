#ifndef TAS_DIAGNOSTICS_H
#define TAS_DIAGNOSTICS_H

#include <objc/objc.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    TAS_DIAG_HLS_INTERCEPTED = 0,
    TAS_DIAG_MASTER_MANIFEST,
    TAS_DIAG_VARIANT_MANIFEST,
    TAS_DIAG_AD_MANIFEST,
    TAS_DIAG_CLEAN_ALTERNATE,
    TAS_DIAG_STRIPPED_SEGMENT,
    TAS_DIAG_TOKEN_FAILURE,
    TAS_DIAG_UNMAPPED_VARIANT,
    TAS_DIAG_SYNTHETIC_SEGMENT,
    TAS_DIAG_GRAPHQL_REWRITE,
    TAS_DIAG_HLS_FAILURE,
    TAS_DIAG_PLAYBACK_SWITCH,
    TAS_DIAG_PLAYER_SNAPSHOT,
    TAS_DIAG_SEGMENT_TASK,
    TAS_DIAG_SEGMENT_BODY,
    TAS_DIAG_METRIC_COUNT
} TASDiagnosticMetric;

void tas_diagnostics_initialize(void);
void tas_diag_metric(TASDiagnosticMetric metric, uint64_t amount);
void tas_diag_log(const char *event, const char *detail);
void tas_diag_log_url(const char *event, const char *url, const char *detail);


bool tas_diagnostics_logging_enabled(void);
void tas_diagnostics_set_logging_enabled(bool enabled);
id tas_create_diagnostic_log_viewer(void);
void tas_copy_diagnostic_report_to_clipboard(void);
void tas_perform_clear_diagnostic_log(void);

typedef struct {
    uint64_t media_sequence;
    uint64_t discontinuity_sequence;
    uint64_t first_segment;
    uint64_t last_segment;
    uint64_t payload;
    size_t segments;
    size_t discontinuities;
    double duration;
    double target_duration;
    bool media_sequence_present;
    bool discontinuity_sequence_present;
    bool initialization_map;
    char first_date[64];
    char last_date[64];
} TASPlaybackManifest;

uint64_t tas_playback_url_id(const char *url);
TASPlaybackManifest tas_playback_parse(const char *manifest);
void tas_playback_format(char *output, size_t capacity, const TASPlaybackManifest *manifest);
void tas_diag_player_snapshots(uint64_t generation, uint64_t route, uint64_t master,
                               const char *phase);
void tas_diag_trace_resources(uint64_t generation, uint64_t route, uint64_t source,
                              const char *playlist);
void tas_diag_observe_task(id task);
void tas_diag_observe_delegate(id delegate);
id tas_diag_segment_completion(id request, id completion);

#endif /* TAS_DIAGNOSTICS_H */
