#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import "Adblock/tpK-adblock-settings.h"
#import "System/tpK-system-player-reload.h"
#include <inttypes.h>
#include <math.h>
#include <stdlib.h>

#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "TASDiagnostics.h"


typedef struct {
    CGFloat x;
    CGFloat y;
} TASPoint;

typedef struct {
    CGFloat width;
    CGFloat height;
} TASSize;

typedef struct {
    TASPoint origin;
    TASSize size;
} TASRect;

#define TAS_DIAGNOSTICS_KEY "TASDiagnosticsEnabled"
#define TAS_DIAGNOSTICS_DIRECTORY "TwitchAdBlock-VAFT"
#define TAS_DIAGNOSTICS_FILENAME "diagnostics.log"
#define TAS_DIAGNOSTICS_LIMIT (1024ULL * 1024ULL)
#define TAS_REPORT_VERSION "2.2.0"

extern id objc_retain(id object);
extern void objc_release(id object);

static pthread_mutex_t g_diag_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_metrics[TAS_DIAG_METRIC_COUNT];
static uint64_t g_logged_events;
static id g_diagnostics_path;
static Class g_log_class;
static IMP g_log_super_view_did_load;
static IMP g_log_super_view_will_appear;
static char g_log_text_view_key;
static void TPKVAFTInstallURLTaskObservers(void);

static id msg0(id object, const char *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static id msg1(id object, const char *selector, id a) {
    return ((id (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), a);
}

static void vmsg1(id object, const char *selector, id a) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), a);
}

static void vmsg_integer(id object, const char *selector, NSInteger value) {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, sel_registerName(selector), value);
}

static void vmsg_bool(id object, const char *selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, sel_registerName(selector), value);
}

static BOOL bmsg0(id object, const char *selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static BOOL bmsg1(id object, const char *selector, id value) {
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), value);
}

static NSInteger imsg0(id object, const char *selector) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static id nsstr(const char *value) {
    if (!value) value = "";
    return msg1((id)objc_getClass("NSString"), "stringWithUTF8String:", (id)value);
}

static const char *utf8(id value) {
    return value ? ((const char *(*)(id, SEL))objc_msgSend)(value, sel_registerName("UTF8String")) : NULL;
}

static id data_from_bytes(const void *bytes, size_t length) {
    return ((id (*)(id, SEL, const void *, NSUInteger))objc_msgSend)(
        (id)objc_getClass("NSData"), sel_registerName("dataWithBytes:length:"), bytes, (NSUInteger)length);
}

static size_t data_length(id data) {
    return data ? (size_t)((NSUInteger (*)(id, SEL))objc_msgSend)(data, sel_registerName("length")) : 0;
}

static id defaults(void) {
    return msg0((id)objc_getClass("NSUserDefaults"), "standardUserDefaults");
}

static bool diagnostics_enabled(void) {
    return bmsg1(defaults(), "boolForKey:", nsstr(TAS_DIAGNOSTICS_KEY));
}

static void set_diagnostics_enabled(bool enabled) {
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
        defaults(), sel_registerName("setBool:forKey:"), enabled ? YES : NO, nsstr(TAS_DIAGNOSTICS_KEY));
}

static id diagnostics_path_locked(void) {
    if (g_diagnostics_path) return g_diagnostics_path;

    id manager = msg0((id)objc_getClass("NSFileManager"), "defaultManager");
    id urls = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(
        manager, sel_registerName("URLsForDirectory:inDomains:"), (NSUInteger)14, (NSUInteger)1);
    id base_url = msg0(urls, "firstObject");
    id base_path = msg0(base_url, "path");
    if (!base_path) {
        id environment = msg0(msg0((id)objc_getClass("NSProcessInfo"), "processInfo"), "environment");
        id home = msg1(environment, "objectForKey:", nsstr("HOME"));
        base_path = msg1(home, "stringByAppendingPathComponent:", nsstr("Library/Application Support"));
    }
    if (!base_path) return nil;

    id directory = msg1(base_path, "stringByAppendingPathComponent:", nsstr(TAS_DIAGNOSTICS_DIRECTORY));
    ((BOOL (*)(id, SEL, id, BOOL, id, id *))objc_msgSend)(
        manager, sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, YES, nil, NULL);
    id path = msg1(directory, "stringByAppendingPathComponent:", nsstr(TAS_DIAGNOSTICS_FILENAME));
    g_diagnostics_path = objc_retain(path);
    return g_diagnostics_path;
}

void tas_diag_metric(TASDiagnosticMetric metric, uint64_t amount) {
    if (metric < 0 || metric >= TAS_DIAG_METRIC_COUNT) return;
    pthread_mutex_lock(&g_diag_lock);
    g_metrics[metric] += amount;
    pthread_mutex_unlock(&g_diag_lock);
}

static void append_log_line_locked(const char *line) {
    id path = diagnostics_path_locked();
    if (!path) return;
    id manager = msg0((id)objc_getClass("NSFileManager"), "defaultManager");
    id handle = msg1((id)objc_getClass("NSFileHandle"), "fileHandleForWritingAtPath:", path);
    if (!handle) {
        ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(
            manager, sel_registerName("createFileAtPath:contents:attributes:"),
            path, data_from_bytes("", 0), nil);
        handle = msg1((id)objc_getClass("NSFileHandle"), "fileHandleForWritingAtPath:", path);
    }
    if (!handle) return;

    unsigned long long offset = ((unsigned long long (*)(id, SEL))objc_msgSend)(
        handle, sel_registerName("seekToEndOfFile"));
    if (offset >= TAS_DIAGNOSTICS_LIMIT) {
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
            handle, sel_registerName("truncateFileAtOffset:"), 0ULL);
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
            handle, sel_registerName("seekToFileOffset:"), 0ULL);
        char rotated[160];
        snprintf(rotated, sizeof(rotated), "[%lld] LOG_ROTATED previous log exceeded 1024 KiB\n",
                 (long long)time(NULL));
        vmsg1(handle, "writeData:", data_from_bytes(rotated, strlen(rotated)));
    }
    vmsg1(handle, "writeData:", data_from_bytes(line, strlen(line)));
    msg0(handle, "synchronizeFile");
    msg0(handle, "closeFile");
}

void tas_diag_log(const char *event, const char *detail) {
    if (!diagnostics_enabled()) return;
    char line[2048];
    snprintf(line, sizeof(line), "[%lld] %s%s%s\n", (long long)time(NULL),
             event ? event : "EVENT", detail && detail[0] ? " " : "", detail ? detail : "");
    pthread_mutex_lock(&g_diag_lock);
    g_logged_events++;
    append_log_line_locked(line);
    pthread_mutex_unlock(&g_diag_lock);
}

void tas_diag_log_url(const char *event, const char *url, const char *detail) {
    if (!diagnostics_enabled()) return;
    char combined[1536];
    snprintf(combined, sizeof(combined), "url_id=%016llx%s%s",
             (unsigned long long)tas_playback_url_id(url),
             detail && detail[0] ? " " : "", detail ? detail : "");
    tas_diag_log(event, combined);
}

static id diagnostic_log_data_locked(void) {
    id path = diagnostics_path_locked();
    if (!path) return nil;
    return msg1((id)objc_getClass("NSData"), "dataWithContentsOfFile:", path);
}

static id diagnostic_report_create(void) {
    uint64_t metrics[TAS_DIAG_METRIC_COUNT];
    uint64_t events;
    id log_data;
    pthread_mutex_lock(&g_diag_lock);
    memcpy(metrics, g_metrics, sizeof(metrics));
    events = g_logged_events;
    log_data = objc_retain(diagnostic_log_data_locked());
    pthread_mutex_unlock(&g_diag_lock);

    id bundle = msg0((id)objc_getClass("NSBundle"), "mainBundle");
    id original_version = msg1(bundle, "objectForInfoDictionaryKey:", nsstr("TPKOriginalTwitchVersion"));
    id original_build = msg1(bundle, "objectForInfoDictionaryKey:", nsstr("TPKOriginalTwitchBuild"));
    const char *app_version = utf8(original_version ?: msg1(bundle, "objectForInfoDictionaryKey:", nsstr("CFBundleShortVersionString")));
    const char *app_build = utf8(original_build ?: msg1(bundle, "objectForInfoDictionaryKey:", nsstr("CFBundleVersion")));
    char header[4096];
    snprintf(header, sizeof(header),
        "TwitchAdBlock VAFT iOS diagnostic report\n"
        "Port build: %s\n"
        "TwitchPlusK build: %s\n"
        "Playback trace: segments-v3-continuity\n"
        "Segment coverage: observed NSURLSession tasks/callbacks only; absent events do not prove absent downloads.\n"
        "Segment bodies: bounded prefix; fMP4 decode times are raw track ticks, not seconds.\n"
        "Twitch: %s (%s)\n"
        "Diagnostic logging: %s\n"
        "Privacy: headers, tokens, URL queries/fragments and manifest bodies are not stored; playback traces contain metadata and fingerprints only.\n"
        "Log limit: 1024 KiB\n\n"
        "Session counters\n"
        "HLS intercepted: %llu\n"
        "Master manifests: %llu\n"
        "Variant manifests: %llu\n"
        "Ad-marked manifests: %llu\n"
        "Clean alternate swaps: %llu\n"
        "Suppressed ad segments: %llu\n"
        "Access-token failures: %llu\n"
        "Unmapped variants: %llu\n"
        "Synthetic segment responses: %llu\n"
        "GraphQL rewrites: %llu\n"
        "HLS failures: %llu\n"
        "Playback source selections: %llu\n"
        "IVS snapshots: %llu\n"
        "Observed segment tasks: %llu\n"
        "Observed segment body callbacks: %llu\n"
        "Logged events this launch: %llu\n\n--- Log ---\n",
        TAS_REPORT_VERSION, TPK_BUILD_VERSION,
        app_version ? app_version : "unknown", app_build ? app_build : "unknown",
        diagnostics_enabled() ? "enabled" : "disabled",
        (unsigned long long)metrics[TAS_DIAG_HLS_INTERCEPTED],
        (unsigned long long)metrics[TAS_DIAG_MASTER_MANIFEST],
        (unsigned long long)metrics[TAS_DIAG_VARIANT_MANIFEST],
        (unsigned long long)metrics[TAS_DIAG_AD_MANIFEST],
        (unsigned long long)metrics[TAS_DIAG_CLEAN_ALTERNATE],
        (unsigned long long)metrics[TAS_DIAG_STRIPPED_SEGMENT],
        (unsigned long long)metrics[TAS_DIAG_TOKEN_FAILURE],
        (unsigned long long)metrics[TAS_DIAG_UNMAPPED_VARIANT],
        (unsigned long long)metrics[TAS_DIAG_SYNTHETIC_SEGMENT],
        (unsigned long long)metrics[TAS_DIAG_GRAPHQL_REWRITE],
        (unsigned long long)metrics[TAS_DIAG_HLS_FAILURE],
        (unsigned long long)metrics[TAS_DIAG_PLAYBACK_SWITCH],
        (unsigned long long)metrics[TAS_DIAG_PLAYER_SNAPSHOT],
        (unsigned long long)metrics[TAS_DIAG_SEGMENT_TASK],
        (unsigned long long)metrics[TAS_DIAG_SEGMENT_BODY],
        (unsigned long long)events);

    id report = msg1((id)objc_getClass("NSMutableString"), "stringWithString:", nsstr(header));
    if (log_data && data_length(log_data)) {
        id log_text = msg0((id)objc_getClass("NSString"), "alloc");
        log_text = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(
            log_text, sel_registerName("initWithData:encoding:"), log_data, (NSUInteger)4);
        if (log_text) {
            vmsg1(report, "appendString:", log_text);
            objc_release(log_text);
        }
    } else {
        vmsg1(report, "appendString:", nsstr("No diagnostic entries yet.\n"));
    }
    if (log_data) objc_release(log_data);
    return objc_retain(report);
}

static void clear_diagnostic_log(void) {
    pthread_mutex_lock(&g_diag_lock);
    id path = diagnostics_path_locked();
    if (path) {
        ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(
            data_from_bytes("", 0), sel_registerName("writeToFile:atomically:"), path, YES);
    }
    g_logged_events = 0;
    pthread_mutex_unlock(&g_diag_lock);
    tas_diag_log("LOG_CLEARED", "The on-disk diagnostic log was cleared");
}

static id make_bar_button(const char *title, id target, const char *action) {
    id item = msg0((id)objc_getClass("UIBarButtonItem"), "alloc");
    return ((id (*)(id, SEL, id, NSInteger, id, SEL))objc_msgSend)(
        item, sel_registerName("initWithTitle:style:target:action:"),
        nsstr(title), (NSInteger)0, target, sel_registerName(action));
}

static void show_notice(id controller, const char *title, const char *message) {
    id alert = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
        (id)objc_getClass("UIAlertController"),
        sel_registerName("alertControllerWithTitle:message:preferredStyle:"),
        nsstr(title), nsstr(message), (NSInteger)1);
    id action = ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
        (id)objc_getClass("UIAlertAction"), sel_registerName("actionWithTitle:style:handler:"),
        nsstr("OK"), (NSInteger)0, nil);
    vmsg1(alert, "addAction:", action);
    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
        controller, sel_registerName("presentViewController:animated:completion:"), alert, YES, nil);
}

static void update_log_text(id self) {
    id text_view = objc_getAssociatedObject(self, &g_log_text_view_key);
    if (!text_view) return;
    id report = diagnostic_report_create();
    vmsg1(text_view, "setText:", report);
    objc_release(report);
}

static void log_copy(id self, SEL command) {
    (void)command;
    id report = diagnostic_report_create();
    vmsg1(msg0((id)objc_getClass("UIPasteboard"), "generalPasteboard"), "setString:", report);
    objc_release(report);
    show_notice(self, "Copied", "The diagnostic report was copied to the clipboard.");
}

static void log_view_did_load(id self, SEL command) {
    if (g_log_super_view_did_load) {
        ((void (*)(id, SEL))g_log_super_view_did_load)(self, command);
    }
    vmsg1(self, "setTitle:", nsstr("Diagnostic Report"));
    id parent = msg0(self, "view");
    TASRect bounds = ((TASRect (*)(id, SEL))objc_msgSend)(parent, sel_registerName("bounds"));
    id text_view = msg0((id)objc_getClass("UITextView"), "alloc");
    text_view = ((id (*)(id, SEL, TASRect))objc_msgSend)(
        text_view, sel_registerName("initWithFrame:"), bounds);
    vmsg_integer(text_view, "setAutoresizingMask:", (NSInteger)18);
    vmsg_bool(text_view, "setEditable:", NO);
    vmsg_bool(text_view, "setSelectable:", YES);
    vmsg_bool(text_view, "setAlwaysBounceVertical:", YES);
    id font = ((id (*)(id, SEL, CGFloat, CGFloat))objc_msgSend)(
        (id)objc_getClass("UIFont"), sel_registerName("monospacedSystemFontOfSize:weight:"),
        (CGFloat)12.0, (CGFloat)0.0);
    vmsg1(text_view, "setFont:", font);
    vmsg1(text_view, "setBackgroundColor:", msg0((id)objc_getClass("UIColor"), "systemBackgroundColor"));
    vmsg1(text_view, "setTextColor:", msg0((id)objc_getClass("UIColor"), "labelColor"));
    vmsg1(parent, "addSubview:", text_view);
    objc_setAssociatedObject(self, &g_log_text_view_key, text_view, 1);
    objc_release(text_view);

    id copy = make_bar_button("Copy", self, "tas_copyDiagnosticReport");
    vmsg1(msg0(self, "navigationItem"), "setRightBarButtonItem:", copy);
    objc_release(copy);
    update_log_text(self);
}

static void log_view_will_appear(id self, SEL command, BOOL animated) {
    if (g_log_super_view_will_appear) {
        ((void (*)(id, SEL, BOOL))g_log_super_view_will_appear)(self, command, animated);
    }
    update_log_text(self);
}

static bool register_log_class(void) {
    Class superclass = objc_getClass("UIViewController");
    if (!superclass) return false;
    g_log_super_view_did_load = method_getImplementation(
        class_getInstanceMethod(superclass, sel_registerName("viewDidLoad")));
    g_log_super_view_will_appear = method_getImplementation(
        class_getInstanceMethod(superclass, sel_registerName("viewWillAppear:")));
    g_log_class = objc_allocateClassPair(superclass, "TASDiagnosticLogViewController", 0);
    if (!g_log_class) g_log_class = objc_getClass("TASDiagnosticLogViewController");
    if (!g_log_class) return false;
    if (!objc_getClass("TASDiagnosticLogViewController")) {
        class_addMethod(g_log_class, sel_registerName("viewDidLoad"), (IMP)log_view_did_load, "v@:");
        class_addMethod(g_log_class, sel_registerName("viewWillAppear:"), (IMP)log_view_will_appear, "v@:B");
        class_addMethod(g_log_class, sel_registerName("tas_copyDiagnosticReport"), (IMP)log_copy, "v@:");
        objc_registerClassPair(g_log_class);
    }
    return true;
}

void tas_diagnostics_initialize(void) {
    TPKVAFTInstallURLTaskObservers();
    bool log_registered = register_log_class();
    fprintf(stderr, "[TAS] diagnostics log viewer %s\n",
            log_registered ? "registered" : "unavailable");
    tas_diag_log("PORT_LOADED", "VAFT v24 iOS port initialized; hosted by TwitchPlusK");
}


bool tas_diagnostics_logging_enabled(void) {
    return diagnostics_enabled();
}

void tas_diagnostics_set_logging_enabled(bool enabled) {
    set_diagnostics_enabled(enabled);
    if (enabled) {
        tas_diag_log("LOGGING_ENABLED", "Diagnostic logging enabled from Twitch settings");
    }
}

id tas_create_diagnostic_log_viewer(void) {
    if (!register_log_class()) return nil;
    // Retourner un objet non possédé aux appelants ARC.
    id controller = msg0((id)g_log_class, "new");
    return msg0(controller, "autorelease");
}

void tas_copy_diagnostic_report_to_clipboard(void) {
    id report = diagnostic_report_create();
    vmsg1(msg0((id)objc_getClass("UIPasteboard"), "generalPasteboard"),
          "setString:", report);
    objc_release(report);
}

void tas_perform_clear_diagnostic_log(void) {
    clear_diagnostic_log();
}

static uint64_t hash_bytes(const char *text, size_t length) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < length; i++) {
        hash ^= (unsigned char)text[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

uint64_t tas_playback_url_id(const char *url) {
    return url ? hash_bytes(url, strcspn(url, "?#")) : 0;
}

static bool has_prefix(const char *line, size_t length, const char *prefix) {
    size_t size = strlen(prefix);
    return length >= size && memcmp(line, prefix, size) == 0;
}

static void copy_date(char output[64], const char *text, size_t length) {
    if (length < 19 || length >= 64) return;
    for (size_t i = 0; i < length; i++) {
        char c = text[i];
        if (!((c >= '0' && c <= '9') || strchr("-:+.TZ", c))) return;
    }
    memcpy(output, text, length);
    output[length] = '\0';
}

TASPlaybackManifest tas_playback_parse(const char *manifest) {
    TASPlaybackManifest result = {0};
    if (!manifest) return result;
    result.payload = hash_bytes(manifest, strlen(manifest));
    for (const char *line = manifest; *line;) {
        const char *end = strchr(line, '\n');
        if (!end) end = line + strlen(line);
        size_t length = (size_t)(end - line);
        if (length && line[length - 1] == '\r') length--;
        if (has_prefix(line, length, "#EXT-X-MEDIA-SEQUENCE:")) {
            const char *value = line + strlen("#EXT-X-MEDIA-SEQUENCE:");
            if (value < line + length && *value >= '0' && *value <= '9') {
                result.media_sequence = strtoull(value, NULL, 10);
                result.media_sequence_present = true;
            }
        } else if (has_prefix(line, length, "#EXT-X-DISCONTINUITY-SEQUENCE:")) {
            const char *value = line + strlen("#EXT-X-DISCONTINUITY-SEQUENCE:");
            if (value < line + length && *value >= '0' && *value <= '9') {
                result.discontinuity_sequence = strtoull(value, NULL, 10);
                result.discontinuity_sequence_present = true;
            }
        } else if (length == strlen("#EXT-X-DISCONTINUITY") &&
                   memcmp(line, "#EXT-X-DISCONTINUITY", length) == 0) {
            result.discontinuities++;
        } else if (has_prefix(line, length, "#EXTINF:")) {
            double duration = strtod(line + strlen("#EXTINF:"), NULL);
            if (isfinite(duration) && duration >= 0) result.duration += duration;
        } else if (has_prefix(line, length, "#EXT-X-TARGETDURATION:")) {
            double target = strtod(line + strlen("#EXT-X-TARGETDURATION:"), NULL);
            if (isfinite(target) && target >= 0) result.target_duration = target;
        } else if (has_prefix(line, length, "#EXT-X-PROGRAM-DATE-TIME:")) {
            size_t prefix = strlen("#EXT-X-PROGRAM-DATE-TIME:");
            copy_date(result.last_date, line + prefix, length - prefix);
            if (!result.first_date[0] && result.last_date[0])
                memcpy(result.first_date, result.last_date, sizeof(result.first_date));
        } else if (has_prefix(line, length, "#EXT-X-MAP:")) {
            result.initialization_map = true;
        } else if (length && line[0] != '#') {
            uint64_t segment = hash_bytes(line, length);
            if (!result.segments) result.first_segment = segment;
            result.last_segment = segment;
            result.segments++;
        }
        line = *end ? end + 1 : end;
    }
    return result;
}

void tas_playback_format(char *output, size_t capacity, const TASPlaybackManifest *m) {
    snprintf(output, capacity,
             "media_seq=%" PRIu64 " media_tag=%d disc_seq=%" PRIu64 " disc_tag=%d "
             "disc=%zu segments=%zu duration=%.3f target=%.3f map=%d "
             "first=%016" PRIx64 " last=%016" PRIx64 " payload=%016" PRIx64 " pdt_first=%s pdt_last=%s",
             m->media_sequence, m->media_sequence_present,
             m->discontinuity_sequence, m->discontinuity_sequence_present,
             m->discontinuities, m->segments, m->duration, m->target_duration,
             m->initialization_map, m->first_segment, m->last_segment, m->payload,
             m->first_date[0] ? m->first_date : "unknown",
             m->last_date[0] ? m->last_date : "unknown");
}

static char TPKVAFTPlayerIDKey;

static BOOL TPKVAFTTracingEnabled(void) {
    return TPKAdblockEnabledFast() && TPKAdblockActiveMethodUsesLocal() &&
           tas_diagnostics_logging_enabled();
}

static NSMutableDictionary *g_segment_refs;
static char g_segment_task_key, g_segment_body_key, g_segment_completion_key;
static NSUInteger g_segment_polls;
static void TPKVAFTSnapshotVisiblePlayers(uint64_t generation, uint64_t route,
                                         uint64_t master, NSString *phase, NSUInteger delay);

static NSNumber *TPKVAFTResourceID(NSURL *url) {
    NSString *text = url.absoluteString;
    if ([text hasPrefix:@"tashttps:"]) text = [@"https:" stringByAppendingString:[text substringFromIndex:9]];
    return @(tas_playback_url_id(text.UTF8String));
}

static NSDictionary *TPKVAFTResource(NSURL *url) {
    if (!url || !TPKVAFTTracingEnabled()) return nil;
    @synchronized(NSProcessInfo.class) {
        return [[[g_segment_refs objectForKey:TPKVAFTResourceID(url)] retain] autorelease];
    }
}

static NSString *TPKVAFTURIAttribute(NSString *line) {
    NSRange start = [line rangeOfString:@"URI=\""];
    if (start.location == NSNotFound) return nil;
    NSString *tail = [line substringFromIndex:NSMaxRange(start)];
    NSRange end = [tail rangeOfString:@"\""];
    return end.location == NSNotFound ? nil : [tail substringToIndex:end.location];
}

void tas_diag_trace_resources(uint64_t generation, uint64_t route, uint64_t source,
                              const char *playlist) {
    if (!playlist || !TPKVAFTTracingEnabled()) return;
    @autoreleasepool {
        static NSTimeInterval lastSnapshot;
        BOOL sample = NO;
        @synchronized(NSProcessInfo.class) {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (now - lastSnapshot >= 5) { lastSnapshot = now; sample = YES; }
        }
        if (sample) dispatch_async(dispatch_get_main_queue(), ^{
            TPKVAFTSnapshotVisiblePlayers(generation, route, 0, @"periodic", 0);
        });
        NSString *text = [NSString stringWithUTF8String:playlist];
        if (!text) return;
        TASPlaybackManifest manifest = tas_playback_parse(playlist);
        uint64_t sequence = manifest.media_sequence, discontinuity = manifest.discontinuity_sequence;
        double duration = 0;
        NSString *date = @"unknown", *range = @"none";
        NSNumber *map = @0;
        for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL initialization = [line hasPrefix:@"#EXT-X-MAP:"];
            if ([line hasPrefix:@"#EXTINF:"]) duration = [[line substringFromIndex:8] doubleValue];
            else if ([line isEqualToString:@"#EXT-X-DISCONTINUITY"]) discontinuity++;
            else if ([line hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME:"]) {
                char safe[64] = {0};
                const char *value = [line substringFromIndex:25].UTF8String;
                if (value) copy_date(safe, value, strlen(value));
                date = safe[0] ? [NSString stringWithUTF8String:safe] : @"unknown";
            } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
                NSString *value = [line substringFromIndex:17];
                NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789@"] invertedSet];
                range = value.length < 64 && [value rangeOfCharacterFromSet:invalid].location == NSNotFound ? value : @"invalid";
            }
            BOOL prefetch = [line hasPrefix:@"#EXT-X-TWITCH-PREFETCH:"];
            if (!initialization && !prefetch && (!line.length || [line hasPrefix:@"#"])) continue;
            NSString *uri = initialization ? TPKVAFTURIAttribute(line) :
                (prefetch ? [line substringFromIndex:23] : line);
            NSURL *url = uri ? [NSURL URLWithString:uri] : nil;
            if (!url.scheme) continue;
            NSNumber *identifier = TPKVAFTResourceID(url);
            if (initialization) map = identifier;
            NSDictionary *reference = @{@"generation": @(generation), @"route": @(route), @"source": @(source),
                @"id": identifier, @"sequence": @(sequence), @"disc": @(discontinuity), @"duration": @(duration),
                @"pdt": date, @"range": range, @"map": map, @"kind": initialization ? @"init" : (prefetch ? @"prefetch" : @"media")};
            BOOL changed;
            @synchronized(NSProcessInfo.class) {
                if (!g_segment_refs) g_segment_refs = [NSMutableDictionary new];
                changed = ![g_segment_refs[identifier] isEqual:reference];
                if (g_segment_refs.count >= 512 && !g_segment_refs[identifier]) [g_segment_refs removeAllObjects];
                g_segment_refs[identifier] = reference;
            }
            if (changed) {
                NSString *detail = [NSString stringWithFormat:
                    @"generation=%llu route=%016llx source=%016llx resource=%016llx kind=%@ seq=%llu disc=%llu duration=%.3f pdt=%@ range=%@ map=%016llx",
                    (unsigned long long)generation, (unsigned long long)route, (unsigned long long)source,
                    identifier.unsignedLongLongValue, reference[@"kind"], (unsigned long long)sequence,
                    (unsigned long long)discontinuity, duration, date, range, map.unsignedLongLongValue];
                tas_diag_log("SEGMENT_REF", detail.UTF8String);
            }
            if (!initialization && !prefetch) { sequence++; date = @"unknown"; range = @"none"; duration = 0; }
        }
    }
}

static uint32_t TPKVAFTBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void TPKVAFTMP4(const uint8_t *data, size_t length, unsigned depth,
                       char *detail, size_t capacity, size_t *used, size_t *budget) {
    if (depth > 6) return;
    for (size_t offset = 0; length - offset >= 8 && *budget; ) {
        (*budget)--;
        const uint8_t *box = data + offset;
        uint64_t size = TPKVAFTBE32(box);
        size_t header = 8;
        if (size == 1) {
            if (length - offset < 16) return;
            size = ((uint64_t)TPKVAFTBE32(box + 8) << 32) | TPKVAFTBE32(box + 12);
            header = 16;
        } else if (!size) size = length - offset;
        if (size < header || size > length - offset) return;
        const uint8_t *body = box + header;
        size_t count = (size_t)size - header;
        int written = 0;
        if (!memcmp(box + 4, "tfdt", 4) && count >= 8 && body[0] <= 1 && (!body[0] || count >= 12)) {
            uint64_t ticks = body[0] ? ((uint64_t)TPKVAFTBE32(body + 4) << 32) | TPKVAFTBE32(body + 8) : TPKVAFTBE32(body + 4);
            written = snprintf(detail + *used, capacity - *used, " tfdt=%llu", (unsigned long long)ticks);
        } else if (!memcmp(box + 4, "tfhd", 4) && count >= 8) {
            written = snprintf(detail + *used, capacity - *used, " track=%u", TPKVAFTBE32(body + 4));
        } else if (!memcmp(box + 4, "tkhd", 4) && count >= 24 && body[0] <= 1 && (!body[0] || count >= 36)) {
            written = snprintf(detail + *used, capacity - *used, " init_track=%u", TPKVAFTBE32(body + (body[0] ? 20 : 12)));
        } else if (!memcmp(box + 4, "mdhd", 4) && count >= 24 && body[0] <= 1 && (!body[0] || count >= 36)) {
            written = snprintf(detail + *used, capacity - *used, " timescale=%u", TPKVAFTBE32(body + (body[0] ? 20 : 12)));
        } else if (!memcmp(box + 4, "hdlr", 4) && count >= 12) {
            written = snprintf(detail + *used, capacity - *used, " handler=%s", !memcmp(body + 8, "vide", 4) ? "video" : (!memcmp(body + 8, "soun", 4) ? "audio" : "other"));
        }
        if (written > 0) *used += (size_t)written < capacity - *used ? (size_t)written : capacity - *used - 1;
        if (capacity - *used < 48) return;
        if (!memcmp(box + 4, "moof", 4) || !memcmp(box + 4, "traf", 4) || !memcmp(box + 4, "moov", 4) ||
            !memcmp(box + 4, "trak", 4) || !memcmp(box + 4, "mdia", 4))
            TPKVAFTMP4(body, count, depth + 1, detail, capacity, used, budget);
        offset += (size_t)size;
    }
}

static void TPKVAFTTS(const uint8_t *data, size_t length, char *detail, size_t capacity, size_t *used) {
    BOOL video = NO, audio = NO;
    for (size_t offset = 0; length - offset >= 188; offset += 188) {
        const uint8_t *packet = data + offset;
        if (packet[0] != 0x47) return;
        if (!(packet[1] & 0x40) || (packet[1] & 0x80) || (packet[3] & 0xc0)) continue;
        unsigned control = (packet[3] >> 4) & 3;
        if (!(control & 1)) continue;
        size_t start = 4;
        if (control & 2) start += 1 + packet[4];
        if (start + 14 > 188) continue;
        const uint8_t *pes = packet + start;
        if (pes[0] || pes[1] || pes[2] != 1 || !(pes[7] & 0x80) || pes[8] < 5 ||
            !(pes[9] & 1) || !(pes[11] & 1) || !(pes[13] & 1)) continue;
        BOOL isVideo = (pes[3] & 0xf0) == 0xe0, isAudio = (pes[3] & 0xe0) == 0xc0;
        if ((!isVideo && !isAudio) || (isVideo && video) || (isAudio && audio)) continue;
        uint64_t pts = ((uint64_t)(pes[9] & 0x0e) << 29) | ((uint64_t)pes[10] << 22) |
                       ((uint64_t)(pes[11] & 0xfe) << 14) | ((uint64_t)pes[12] << 7) | (pes[13] >> 1);
        int written = snprintf(detail + *used, capacity - *used, " %s_pts90k=%llu", isVideo ? "video" : "audio", (unsigned long long)pts);
        if (written > 0) *used += (size_t)written < capacity - *used ? (size_t)written : capacity - *used - 1;
        video |= isVideo; audio |= isAudio;
        if ((video && audio) || capacity - *used < 48) return;
    }
}

static void TPKVAFTSegmentResult(NSURLRequest *request, NSData *data, NSURLResponse *response,
                                 NSError *error, NSString *path, NSDictionary *ref) {
    if (!ref || !TPKVAFTTracingEnabled()) return;
    char timeline[512] = {0};
    size_t used = 0, budget = 2048;
    TPKVAFTMP4(data.bytes, MIN(data.length, 256 * 1024), 0, timeline, sizeof(timeline), &used, &budget);
    if (!used) TPKVAFTTS(data.bytes, MIN(data.length, 256 * 1024), timeline, sizeof(timeline), &used);
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    NSString *detail = [NSString stringWithFormat:
        @"resource=%016llx generation=%@ route=%016llx source=%016llx seq=%@ path=%@ status=%ld body_bytes=%lu prefix_limited=%d error=%d code=%ld domain=%016llx timeline=%s",
        [ref[@"id"] unsignedLongLongValue], ref[@"generation"], [ref[@"route"] unsignedLongLongValue],
        [ref[@"source"] unsignedLongLongValue], ref[@"sequence"], path, (long)status,
        (unsigned long)data.length, data.length >= 256 * 1024, error != nil, (long)error.code,
        (unsigned long long)tas_playback_url_id(error.domain.UTF8String), used ? timeline : "unavailable"];
    tas_diag_metric(TAS_DIAG_SEGMENT_BODY, 1);
    tas_diag_log("SEGMENT_BODY", detail.UTF8String);
}

id tas_diag_segment_completion(id request, id completion) {
    if (!completion || objc_getAssociatedObject(completion, &g_segment_completion_key)) return completion;
    NSDictionary *ref = TPKVAFTResource([request URL]);
    if (!ref) return completion;
    void (^original)(NSData *, NSURLResponse *, NSError *) = completion;
    id wrapped = [[^(NSData *data, NSURLResponse *response, NSError *error) {
        @try { TPKVAFTSegmentResult(request, data, response, error, @"completion", ref); }
        @catch (__unused NSException *exception) { tas_diag_log("SEGMENT_TRACE_ERROR", "path=completion"); }
        original(data, response, error);
    } copy] autorelease];
    objc_setAssociatedObject(wrapped, &g_segment_completion_key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return wrapped;
}

static void TPKVAFTPollTask(NSURLSessionTask *task, NSDictionary *ref, NSTimeInterval created, NSUInteger tick) {
    @autoreleasepool {
        BOOL enabled = TPKVAFTTracingEnabled();
        NSURLSessionTaskState state = task.state;
        BOOL done = state == NSURLSessionTaskStateCompleted;
        if (enabled && (done || !tick || tick % 5 == 0)) {
            NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)task.response statusCode] : 0;
            NSString *detail = [NSString stringWithFormat:
                @"resource=%016llx generation=%@ seq=%@ task=%lu age=%.3f state=%ld status=%ld received=%lld expected=%lld error=%d code=%ld final_url=%016llx observation=%s",
                [ref[@"id"] unsignedLongLongValue], ref[@"generation"], ref[@"sequence"], (unsigned long)task.taskIdentifier,
                NSProcessInfo.processInfo.systemUptime - created, (long)state, (long)status,
                task.countOfBytesReceived, task.countOfBytesExpectedToReceive, task.error != nil, (long)task.error.code,
                TPKVAFTResourceID(task.response.URL).unsignedLongLongValue, tick >= 120 && !done ? "expired" : (done ? "completed" : "pending")];
            tas_diag_log("SEGMENT_TASK", detail.UTF8String);
        }
        if (!enabled || done || tick >= 120) {
            @synchronized(NSProcessInfo.class) { g_segment_polls--; }
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TPKVAFTPollTask(task, ref, created, tick + 1);
        });
    }
}

void tas_diag_observe_task(id object) {
    if (!TPKVAFTTracingEnabled() || ![object isKindOfClass:NSURLSessionTask.class]) return;
    NSURLSessionTask *task = object;
    NSDictionary *ref = TPKVAFTResource(task.originalRequest.URL);
    if (!ref) return;
    @synchronized(NSProcessInfo.class) {
        if (objc_getAssociatedObject(task, &g_segment_task_key)) return;
        if (g_segment_polls >= 64) { tas_diag_log("SEGMENT_COVERAGE", "task_limit=64 task_not_polled=yes"); return; }
        objc_setAssociatedObject(task, &g_segment_task_key, ref, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        g_segment_polls++;
    }
    tas_diag_metric(TAS_DIAG_SEGMENT_TASK, 1);
    NSTimeInterval created = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ TPKVAFTPollTask(task, ref, created, 0); });
}

static void TPKVAFTInstallURLTaskObservers(void) {
    Class cls = NSURLSession.class;
    SEL plain = @selector(dataTaskWithURL:);
    Method method = class_getInstanceMethod(cls, plain);
    if (method) {
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id session, NSURL *url) {
            id task = ((id (*)(id, SEL, id))original)(session, plain, url);
            tas_diag_observe_task(task);
            return task;
        });
        method_setImplementation(method, replacement);
    }
    SEL completed = @selector(dataTaskWithURL:completionHandler:);
    method = class_getInstanceMethod(cls, completed);
    if (method) {
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id session, NSURL *url, id completion) {
            id wrapped = completion;
            if (TPKVAFTResource(url)) wrapped = tas_diag_segment_completion([NSURLRequest requestWithURL:url], completion);
            id task = ((id (*)(id, SEL, id, id))original)(session, completed, url, wrapped);
            tas_diag_observe_task(task);
            return task;
        });
        method_setImplementation(method, replacement);
    }
}

void tas_diag_observe_delegate(id delegate) {
    if (!delegate || !TPKVAFTTracingEnabled()) return;
    @synchronized(NSProcessInfo.class) {
        static NSMutableSet *installed;
        if (!installed) installed = [NSMutableSet new];
        for (NSString *name in @[@"URLSession:dataTask:didReceiveData:", @"URLSession:task:didCompleteWithError:"]) {
            SEL selector = NSSelectorFromString(name);
            Class owner = object_getClass(delegate);
            Method method = class_getInstanceMethod(owner, selector);
            if (!method) continue;
            while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), selector) == method)
                owner = class_getSuperclass(owner);
            NSString *key = [NSString stringWithFormat:@"%p:%@", owner, name];
            if ([installed containsObject:key]) continue;
            IMP original = method_getImplementation(method);
            BOOL dataCallback = [name containsString:@"didReceiveData:"];
            IMP replacement = imp_implementationWithBlock(^(id receiver, NSURLSession *session, NSURLSessionTask *task, id value) {
                @try {
                    if (TPKVAFTResource(task.originalRequest.URL)) {
                        tas_diag_observe_task(task);
                        @synchronized(task) {
                            if (dataCallback && [value isKindOfClass:NSData.class]) {
                                NSMutableData *prefix = objc_getAssociatedObject(task, &g_segment_body_key);
                                if (!prefix) {
                                    prefix = [NSMutableData data];
                                    objc_setAssociatedObject(task, &g_segment_body_key, prefix, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                }
                                NSUInteger count = MIN([(NSData *)value length], 256 * 1024 - prefix.length);
                                if (count) [prefix appendBytes:[value bytes] length:count];
                            } else if (!dataCallback) {
                                TPKVAFTSegmentResult(task.originalRequest, objc_getAssociatedObject(task, &g_segment_body_key), task.response, value, @"delegate-prefix",
                                    objc_getAssociatedObject(task, &g_segment_task_key) ?: TPKVAFTResource(task.originalRequest.URL));
                                objc_setAssociatedObject(task, &g_segment_body_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            }
                        }
                    }
                } @catch (__unused NSException *exception) { tas_diag_log("SEGMENT_TRACE_ERROR", "path=delegate"); }
                ((void (*)(id, SEL, id, id, id))original)(receiver, selector, session, task, value);
            });
            method_setImplementation(method, replacement);
            [installed addObject:key];
            tas_diag_log("SEGMENT_COVERAGE", dataCallback ? "delegate_data_hook=installed" : "delegate_completion_hook=installed");
        }
    }
}

static NSInvocation *TPKVAFTGetter(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return nil;
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = object;
    call.selector = selector;
    return call;
}

static NSNumber *TPKVAFTNumber(id object, NSString *name) {
    @try {
        NSInvocation *call = TPKVAFTGetter(object, name);
        if (!call) return nil;
        const char *type = call.methodSignature.methodReturnType;
        while (*type && strchr("rnNoORV", *type)) type++;
        if (!*type || type[1] || !strchr("BcCsSiIlLqQfd", *type)) return nil;
        [call invoke];
#define TPK_VAFT_NUMBER(code, kind) case code: { kind value = 0; [call getReturnValue:&value]; return @(value); }
        switch (*type) {
            TPK_VAFT_NUMBER('B', bool)
            TPK_VAFT_NUMBER('c', signed char)
            TPK_VAFT_NUMBER('C', unsigned char)
            TPK_VAFT_NUMBER('s', short)
            TPK_VAFT_NUMBER('S', unsigned short)
            TPK_VAFT_NUMBER('i', int)
            TPK_VAFT_NUMBER('I', unsigned int)
            TPK_VAFT_NUMBER('l', long)
            TPK_VAFT_NUMBER('L', unsigned long)
            TPK_VAFT_NUMBER('q', long long)
            TPK_VAFT_NUMBER('Q', unsigned long long)
            TPK_VAFT_NUMBER('f', float)
            TPK_VAFT_NUMBER('d', double)
        }
#undef TPK_VAFT_NUMBER
    } @catch (__unused NSException *exception) {}
    return nil;
}

static id TPKVAFTObject(id object, NSString *name) {
    @try {
        NSInvocation *call = TPKVAFTGetter(object, name);
        if (!call || call.methodSignature.methodReturnType[0] != '@') return nil;
        [call invoke];
        __unsafe_unretained id value = nil;
        [call getReturnValue:&value];
        return value;
    } @catch (__unused NSException *exception) {}
    return nil;
}

static NSString *TPKVAFTTime(id player, NSString *name) {
    @try {
        NSInvocation *call = TPKVAFTGetter(player, name);
        if (!call || strcmp(call.methodSignature.methodReturnType, @encode(CMTime)) ||
            call.methodSignature.methodReturnLength != sizeof(CMTime)) return @"unknown";
        CMTime time = kCMTimeInvalid;
        [call invoke];
        [call getReturnValue:&time];
        double seconds = CMTimeGetSeconds(time);
        if (CMTIME_IS_NUMERIC(time) && isfinite(seconds))
            return [NSString stringWithFormat:@"%.3f", seconds];
    } @catch (__unused NSException *exception) {}
    return @"unknown";
}

static void TPKVAFTSnapshot(id player, uint64_t generation, uint64_t route,
                            uint64_t master, NSString *phase, NSUInteger delay) {
    static NSUInteger nextID;
    NSNumber *playerID = objc_getAssociatedObject(player, &TPKVAFTPlayerIDKey);
    if (!playerID) {
        playerID = @(++nextID);
        objc_setAssociatedObject(player, &TPKVAFTPlayerIDKey, playerID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id path = TPKVAFTObject(player, @"path");
    NSString *pathString = [path isKindOfClass:NSURL.class] ? [path absoluteString] :
        ([path isKindOfClass:NSString.class] ? path : nil);
    uint64_t pathID = tas_playback_url_id(pathString.UTF8String);
    NSError *error = TPKVAFTObject(player, @"error");
    if (![error isKindOfClass:NSError.class]) error = nil;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (![underlying isKindOfClass:NSError.class]) underlying = nil;
    NSString *errorFamily = !error ? @"none" :
        ([error.domain isEqualToString:NSURLErrorDomain] ? @"url" :
         ([error.domain localizedCaseInsensitiveContainsString:@"ivs"] ? @"ivs" : @"other"));
    NSString *detail = [NSString stringWithFormat:
        @"generation=%llu route=%016llx master=%016llx phase=%@ after=%lu player=%@ "
         "path=%016llx master_match=%@ state=%@ position=%@ buffered=%@ latency=%@ "
         "rate=%@ decoded=%@ dropped=%@ bitrate=%@ error_present=%d error_code=%ld "
         "error_family=%@ error_domain=%016llx underlying_present=%d underlying_code=%ld underlying_domain=%016llx",
        (unsigned long long)generation, (unsigned long long)route, (unsigned long long)master,
        phase, (unsigned long)delay, playerID, (unsigned long long)pathID,
        pathID && master ? (pathID == master ? @"yes" : @"no") : @"unknown",
        TPKVAFTNumber(player, @"state") ?: @"unknown", TPKVAFTTime(player, @"position"),
        TPKVAFTTime(player, @"buffered"), TPKVAFTTime(player, @"liveLatency"),
        TPKVAFTNumber(player, @"playbackRate") ?: @"unknown",
        TPKVAFTNumber(player, @"videoFramesDecoded") ?: @"unknown",
        TPKVAFTNumber(player, @"videoFramesDropped") ?: @"unknown",
        TPKVAFTNumber(player, @"videoBitrate") ?: @"unknown",
        error != nil, (long)error.code, errorFamily,
        (unsigned long long)tas_playback_url_id(error.domain.UTF8String),
        underlying != nil, (long)underlying.code,
        (unsigned long long)tas_playback_url_id(underlying.domain.UTF8String)];
    tas_diag_metric(TAS_DIAG_PLAYER_SNAPSHOT, 1);
    tas_diag_log("IVS_SNAPSHOT", detail.UTF8String);
}

static void TPKVAFTSnapshotVisiblePlayers(uint64_t generation, uint64_t route,
                                         uint64_t master, NSString *phase, NSUInteger delay) {
    if (!TPKVAFTTracingEnabled()) return;
    NSHashTable *players = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSArray<UIWindow *> *windows = [UIApplication.sharedApplication.windows.copy autorelease];
    for (UIWindow *window in windows) {
        if (window.hidden) continue;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        for (NSUInteger i = 0; i < queue.count && i < 2048 && players.count < 4; i++) {
            UIView *view = queue[i];
            if (tpk_isPlayerControlsContainer(view)) {
                id player = tpk_playerActivePlayerForView(view);
                if (player) [players addObject:player];
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    if (!players.count) {
        for (UIWindow *window in windows) {
            if (window.hidden || players.count >= 4) continue;
            id player = tpk_playerActivePlayerForView(window);
            if (player) [players addObject:player];
        }
    }
    if (!players.count) {
        NSString *detail = [NSString stringWithFormat:
            @"generation=%llu route=%016llx phase=%@ after=%lu player=not_found",
            (unsigned long long)generation, (unsigned long long)route, phase, (unsigned long)delay];
        tas_diag_metric(TAS_DIAG_PLAYER_SNAPSHOT, 1);
        tas_diag_log("IVS_SNAPSHOT", detail.UTF8String);
    }
    for (id player in players) TPKVAFTSnapshot(player, generation, route, master, phase, delay);
}

void tas_diag_player_snapshots(uint64_t generation, uint64_t route, uint64_t master,
                               const char *phase) {
    if (!TPKVAFTTracingEnabled()) return;
    NSString *phaseName = [NSString stringWithUTF8String:phase ?: "unknown"];
    for (NSNumber *delay in @[@0, @1, @3, @8, @15, @30]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.longLongValue * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            TPKVAFTSnapshotVisiblePlayers(generation, route, master, phaseName, delay.unsignedIntegerValue);
        });
    }
}
