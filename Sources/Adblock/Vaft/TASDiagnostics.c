/*
 * TASDiagnostics — sanitized diagnostics engine of the VAFT iOS port.
 *
 * Upstream project: BananaOnGitHub/TwitchAdBlock-VAFT-iOS (Apache-2.0),
 * port version 2.2.0 — https://github.com/BananaOnGitHub/TwitchAdBlock-VAFT-iOS
 *
 * Hosted in TwitchPlusK. Divergence D5 (integration only): the original
 * App Settings injection cluster (register_settings_class, app-settings hook,
 * UIViewController fallback, retry observer, loaded notice, dedicated Ad Block
 * page) is intentionally NOT ported — the diagnostics controls live at the
 * bottom of the host tweak's Logs page and push the runtime-created viewer
 * below. Engine behavior (metrics, log file, rotation, sanitization, report,
 * clear) is preserved verbatim.
 */
/* TwitchPlusK: system/runtime headers first, then the module header (which
 * now declares id-returning integration wrappers). */
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

typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef double CGFloat;

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
#define TAS_DIAGNOSTICS_LIMIT (512ULL * 1024ULL)
#define TAS_REPORT_VERSION "2.2.0"

extern id objc_retain(id object);
extern void objc_release(id object);
extern void objc_setAssociatedObject(id object, const void *key, id value, uintptr_t policy);
extern id objc_getAssociatedObject(id object, const void *key);

static pthread_mutex_t g_diag_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_metrics[TAS_DIAG_METRIC_COUNT];
static uint64_t g_logged_events;
static id g_diagnostics_path;
static Class g_log_class;
static IMP g_log_super_view_did_load;
static IMP g_log_super_view_will_appear;
static char g_log_text_view_key;

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
        snprintf(rotated, sizeof(rotated), "[%lld] LOG_ROTATED previous log exceeded 512 KiB\n",
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

static void sanitized_url(const char *url, char *output, size_t capacity) {
    if (!output || !capacity) return;
    output[0] = '\0';
    if (!url) return;
    const char *end = strchr(url, '?');
    const char *fragment = strchr(url, '#');
    if (!end || (fragment && fragment < end)) end = fragment;
    size_t length = end ? (size_t)(end - url) : strlen(url);
    if (length >= capacity) length = capacity - 1;
    memcpy(output, url, length);
    output[length] = '\0';
}

void tas_diag_log_url(const char *event, const char *url, const char *detail) {
    if (!diagnostics_enabled()) return;
    char safe_url[1024];
    char combined[1536];
    sanitized_url(url, safe_url, sizeof(safe_url));
    snprintf(combined, sizeof(combined), "url=%s%s%s", safe_url,
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
    const char *app_version = utf8(msg1(bundle, "objectForInfoDictionaryKey:", nsstr("CFBundleShortVersionString")));
    const char *app_build = utf8(msg1(bundle, "objectForInfoDictionaryKey:", nsstr("CFBundleVersion")));
    char header[4096];
    snprintf(header, sizeof(header),
        "TwitchAdBlock VAFT iOS diagnostic report\n"
        "Port build: %s\n"
        "Twitch: %s (%s)\n"
        "Diagnostic logging: %s\n"
        "Privacy: URL query strings/fragments, headers, access tokens, and manifest contents are not stored.\n"
        "Log limit: 512 KiB\n\n"
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
        "Logged events this launch: %llu\n\n--- Log ---\n",
        TAS_REPORT_VERSION, app_version ? app_version : "unknown", app_build ? app_build : "unknown",
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

/* TwitchPlusK divergence D5: reduced initialization — the App Settings
 * injection cluster is not ported (controls live in the host tweak's Logs
 * page); the runtime report-viewer class is still registered here. */
void tas_diagnostics_initialize(void) {
    bool log_registered = register_log_class();
    fprintf(stderr, "[TAS] diagnostics log viewer %s\n",
            log_registered ? "registered" : "unavailable");
    tas_diag_log("PORT_LOADED", "VAFT v24 iOS port initialized; hosted by TwitchPlusK");
}

/* ── TwitchPlusK integration surface (thin wrappers, no logic changes) ── */

bool tas_diagnostics_logging_enabled(void) {
    return diagnostics_enabled();
}

void tas_diagnostics_set_logging_enabled(bool enabled) {
    /* Comportement upstream exact (settings_switch_changed) : l'activation
     * journalise LOGGING_ENABLED ; la désactivation ne journalise pas. */
    set_diagnostics_enabled(enabled);
    if (enabled) {
        tas_diag_log("LOGGING_ENABLED", "Diagnostic logging enabled from Twitch settings");
    }
}

id tas_create_diagnostic_log_viewer(void) {
    if (!register_log_class()) return nil;
    /* TwitchPlusK divergence D10 (ARC integration): the caller is compiled
     * with ARC and treats this plain-C return as +0 — autorelease here so the
     * freshly created viewer is not leaked. Same lifetime semantics as
     * upstream's settings_did_select (new + explicit release after push). */
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