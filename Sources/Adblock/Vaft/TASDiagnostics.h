/*
 * TASDiagnostics - sanitized diagnostics engine of the VAFT iOS port.
 * Upstream: BananaOnGitHub/TwitchAdBlock-VAFT-iOS (Apache-2.0), port 2.2.0.
 * Hosted in TwitchPlusK - see UPSTREAM.md in this directory. The additions
 * below the original block are TwitchPlusK integration wrappers only.
 */
#ifndef TAS_DIAGNOSTICS_H
#define TAS_DIAGNOSTICS_H

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
    TAS_DIAG_METRIC_COUNT
} TASDiagnosticMetric;

void tas_diagnostics_initialize(void);
void tas_diag_metric(TASDiagnosticMetric metric, uint64_t amount);
void tas_diag_log(const char *event, const char *detail);
void tas_diag_log_url(const char *event, const char *url, const char *detail);

/* --- TwitchPlusK integration surface (thin wrappers, no logic changes) --- */

bool tas_diagnostics_logging_enabled(void);
void tas_diagnostics_set_logging_enabled(bool enabled);
id tas_create_diagnostic_log_viewer(void);
void tas_copy_diagnostic_report_to_clipboard(void);
void tas_perform_clear_diagnostic_log(void);

#endif /* TAS_DIAGNOSTICS_H */
