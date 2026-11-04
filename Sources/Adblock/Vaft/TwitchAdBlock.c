#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <math.h>

#include "TASDiagnostics.h"

extern BOOL TPKAdblockEnabledFast(void);

typedef unsigned long NSUInteger;
typedef long NSInteger;
#define TAS_INTERNAL_HEADER "X-TAS-Internal"
#define TAS_SCHEME "tashttps"
#define TAS_CLIENT_ID "kimne78kx3ncx6brgo4mv6wki5h1ko"
#define TAS_TOKEN_HASH "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
#define TAS_PLAYER_TYPE_COUNT 3
#define TAS_MAX_AD_SEGMENTS 256
#define TAS_MAX_STREAMS 8
#define TAS_MAX_VARIANT_ROUTES 256
#define TAS_STREAM_TTL 1800
#define TAS_MANIFEST_CAPACITY 262144
#define TAS_URL_CAPACITY 8192

extern id objc_getAssociatedObject(id object, const void *key);
extern int objc_sync_enter(id object);
extern int objc_sync_exit(id object);
extern id objc_retain(id object);
extern void objc_release(id object);
extern void objc_setAssociatedObject(id object, const void *key, id value, uintptr_t policy);
extern uint32_t arc4random_uniform(uint32_t upper_bound);

static id msg0(id object, const char *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static id msg1(id object, const char *selector, id a) {
    return ((id (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), a);
}

static id msg2(id object, const char *selector, id a, id b) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(object, sel_registerName(selector), a, b);
}

static void vmsg1(id object, const char *selector, id a) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), a);
}

static void vmsg2(id object, const char *selector, id a, id b) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(object, sel_registerName(selector), a, b);
}

static void vmsg3(id object, const char *selector, id a, id b, NSInteger c) {
    ((void (*)(id, SEL, id, id, NSInteger))objc_msgSend)(object, sel_registerName(selector), a, b, c);
}

static BOOL bmsg1(id object, const char *selector, id a) {
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(object, sel_registerName(selector), a);
}

static NSInteger imsg0(id object, const char *selector) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static id nsstr(const char *value) {
    if (!value) return nil;
    return msg1((id)objc_getClass("NSString"), "stringWithUTF8String:", (id)value);
}

static const char *utf8(id value) {
    if (!value) return NULL;
    return ((const char *(*)(id, SEL))objc_msgSend)(value, sel_registerName("UTF8String"));
}

static id nsurl(const char *value) {
    return msg1((id)objc_getClass("NSURL"), "URLWithString:", nsstr(value));
}

static id data_from_bytes(const void *bytes, size_t length) {
    return ((id (*)(id, SEL, const void *, NSUInteger))objc_msgSend)(
        (id)objc_getClass("NSData"), sel_registerName("dataWithBytes:length:"), bytes, (NSUInteger)length);
}

static const uint8_t *data_bytes(id data) {
    return ((const uint8_t *(*)(id, SEL))objc_msgSend)(data, sel_registerName("bytes"));
}

static size_t data_length(id data) {
    return (size_t)((NSUInteger (*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
}

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_authorization[4096];
static char g_integrity[4096];
static char g_device_id[512];
static char g_client_version[512];
static char g_client_session[512];
static const char *g_player_types[TAS_PLAYER_TYPE_COUNT] = {"embed", "popout", "autoplay"};

typedef struct {
    bool active;
    uint64_t generation;
    time_t last_seen;
    char channel[512];
    char *master_url;
    char *master_manifest;
    char *backup_variant_url;
    char backup_player_type[64];
    time_t backup_created;
    char *backup_masters[TAS_PLAYER_TYPE_COUNT];
    char *backup_master_urls[TAS_PLAYER_TYPE_COUNT];
} TASStreamContext;

typedef struct TASContinuity TASContinuity;
static void continuity_free(TASContinuity *state);

typedef struct {
    char url[TAS_URL_CAPACITY];
    size_t stream_index;
    uint64_t generation;
    time_t last_seen;
    TASContinuity *continuity[2];
} TASVariantRoute;

typedef struct {
    size_t index;
    uint64_t generation;
    bool valid;
} TASStreamRef;

typedef struct {
    TASStreamRef ref;
    char channel[512];
    char master_url[TAS_URL_CAPACITY];
    char backup_variant_url[TAS_URL_CAPACITY];
    time_t backup_created;
    char *master_manifest;
} TASStreamSnapshot;

static TASStreamContext g_streams[TAS_MAX_STREAMS];
static TASVariantRoute g_variant_routes[TAS_MAX_VARIANT_ROUTES];
static uint64_t g_next_stream_generation = 1;

typedef struct {
    char url[4096];
    time_t created;
} TASAdSegment;

static TASAdSegment g_ad_segments[TAS_MAX_AD_SEGMENTS];
static size_t g_next_ad_segment;

static char g_association_key;
static char g_protocol_task_key, g_protocol_stopped_key, g_protocol_completed_key;
static id g_protocol_session;
static IMP g_original_asset_init;
static IMP g_original_default_configuration;
static IMP g_original_ephemeral_configuration;
static IMP g_original_session_with_configuration;
static IMP g_original_session_with_configuration_delegate_queue;
static IMP g_original_data_task_request;
static IMP g_original_data_task_request_completion;
static Class g_protocol_class;
static Class g_loader_class;

static char *absolute_url(const char *base, const char *relative);
static char *process_manifest(const char *url, const char *playlist, bool custom_scheme);

static void copy_string(char *destination, size_t capacity, const char *source) {
    if (!destination || capacity == 0) return;
    if (!source) source = "";
    snprintf(destination, capacity, "%s", source);
}

static bool starts_with(const char *value, const char *prefix) {
    return value && prefix && strncmp(value, prefix, strlen(prefix)) == 0;
}

static bool contains(const char *value, const char *needle) {
    return value && needle && strstr(value, needle) != NULL;
}

static void replace_owned_string(char **destination, const char *source) {
    char *replacement = source ? strdup(source) : NULL;
    if (source && !replacement) return;
    free(*destination);
    *destination = replacement;
}

static bool stream_ref_matches_locked(TASStreamRef ref) {
    return ref.valid && ref.index < TAS_MAX_STREAMS &&
           g_streams[ref.index].active &&
           g_streams[ref.index].generation == ref.generation;
}

static void clear_routes_for_stream_locked(size_t stream_index) {
    for (size_t i = 0; i < TAS_MAX_VARIANT_ROUTES; i++) {
        if (g_variant_routes[i].url[0] && g_variant_routes[i].stream_index == stream_index) {
            continuity_free(g_variant_routes[i].continuity[0]);
            continuity_free(g_variant_routes[i].continuity[1]);
            memset(&g_variant_routes[i], 0, sizeof(g_variant_routes[i]));
        }
    }
}

static void clear_active_backup_locked(TASStreamContext *stream) {
    free(stream->backup_variant_url);
    stream->backup_variant_url = NULL;
    stream->backup_player_type[0] = '\0';
    stream->backup_created = 0;
}

static void clear_stream_context_locked(size_t stream_index) {
    TASStreamContext *stream = &g_streams[stream_index];
    clear_routes_for_stream_locked(stream_index);
    free(stream->master_url);
    free(stream->master_manifest);
    free(stream->backup_variant_url);
    for (size_t i = 0; i < TAS_PLAYER_TYPE_COUNT; i++) {
        free(stream->backup_masters[i]);
        free(stream->backup_master_urls[i]);
    }
    memset(stream, 0, sizeof(*stream));
}

static void prune_streams_locked(time_t now) {
    for (size_t i = 0; i < TAS_MAX_STREAMS; i++) {
        if (g_streams[i].active && now - g_streams[i].last_seen > TAS_STREAM_TTL) {
            clear_stream_context_locked(i);
        }
    }
}

static TASStreamRef update_stream_master_locked(const char *channel, const char *url,
                                                const char *playlist) {
    time_t now = time(NULL);
    prune_streams_locked(now);

    size_t stream_index = TAS_MAX_STREAMS;
    for (size_t i = 0; i < TAS_MAX_STREAMS; i++) {
        if (g_streams[i].active && strcmp(g_streams[i].channel, channel) == 0) {
            stream_index = i;
            break;
        }
    }
    if (stream_index == TAS_MAX_STREAMS) {
        for (size_t i = 0; i < TAS_MAX_STREAMS; i++) {
            if (!g_streams[i].active) {
                stream_index = i;
                break;
            }
        }
    }
    if (stream_index == TAS_MAX_STREAMS) {
        stream_index = 0;
        for (size_t i = 1; i < TAS_MAX_STREAMS; i++) {
            if (g_streams[i].last_seen < g_streams[stream_index].last_seen) stream_index = i;
        }
        clear_stream_context_locked(stream_index);
    }

    TASStreamContext *stream = &g_streams[stream_index];
    if (!stream->active) {
        stream->active = true;
        stream->generation = g_next_stream_generation++;
        if (!g_next_stream_generation) g_next_stream_generation = 1;
        copy_string(stream->channel, sizeof(stream->channel), channel);
    }
    replace_owned_string(&stream->master_url, url);
    replace_owned_string(&stream->master_manifest, playlist);
    clear_active_backup_locked(stream);
    stream->last_seen = now;

    TASStreamRef ref = {stream_index, stream->generation, true};
    return ref;
}

static void clear_active_backup(TASStreamRef ref) {
    pthread_mutex_lock(&g_lock);
    if (stream_ref_matches_locked(ref)) clear_active_backup_locked(&g_streams[ref.index]);
    pthread_mutex_unlock(&g_lock);
}

static bool is_twitch_hls_url(const char *url) {
    return url && contains(url, ".m3u8") &&
           (contains(url, "ttvnw.net") || contains(url, "twitch.tv"));
}

static bool is_cached_ad_segment(const char *url) {
    bool found = false;
    time_t now = time(NULL);
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < TAS_MAX_AD_SEGMENTS; i++) {
        if (g_ad_segments[i].created && now - g_ad_segments[i].created > 120) {
            g_ad_segments[i].url[0] = '\0';
            g_ad_segments[i].created = 0;
        }
        if (g_ad_segments[i].url[0] && strcmp(g_ad_segments[i].url, url) == 0) {
            found = true;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

static void remember_ad_segment(const char *base_url, const char *segment_url) {
    if (!segment_url || !segment_url[0]) return;
    char cleaned[4096];
    copy_string(cleaned, sizeof(cleaned), segment_url);
    size_t cleaned_length = strlen(cleaned);
    while (cleaned_length && (cleaned[cleaned_length - 1] == '\r' || cleaned[cleaned_length - 1] == '\n')) {
        cleaned[--cleaned_length] = '\0';
    }
    char *absolute = absolute_url(base_url, cleaned);
    if (!absolute || strlen(absolute) >= sizeof(g_ad_segments[0].url)) {
        free(absolute);
        return;
    }
    pthread_mutex_lock(&g_lock);
    size_t index = g_next_ad_segment++ % TAS_MAX_AD_SEGMENTS;
    copy_string(g_ad_segments[index].url, sizeof(g_ad_segments[index].url), absolute);
    g_ad_segments[index].created = time(NULL);
    pthread_mutex_unlock(&g_lock);
    free(absolute);
}

static char *copy_data_text(id data) {
    if (!data) return NULL;
    size_t length = data_length(data);
    char *result = calloc(length + 1, 1);
    if (!result) return NULL;
    memcpy(result, data_bytes(data), length);
    return result;
}

static void cache_header(id request, const char *header, char *destination, size_t capacity) {
    id value = msg1(request, "valueForHTTPHeaderField:", nsstr(header));
    const char *string = utf8(value);
    if (string && string[0]) copy_string(destination, capacity, string);
}

static void cache_twitch_headers(id request) {
    pthread_mutex_lock(&g_lock);
    cache_header(request, "Authorization", g_authorization, sizeof(g_authorization));
    cache_header(request, "Client-Integrity", g_integrity, sizeof(g_integrity));
    cache_header(request, "X-Device-Id", g_device_id, sizeof(g_device_id));
    if (!g_device_id[0]) cache_header(request, "Device-ID", g_device_id, sizeof(g_device_id));
    cache_header(request, "Client-Version", g_client_version, sizeof(g_client_version));
    cache_header(request, "Client-Session-Id", g_client_session, sizeof(g_client_session));
    pthread_mutex_unlock(&g_lock);
}

static bool json_space(char value) {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

static char *replace_json_string(char *source, const char *key, const char *replacement) {
    if (!source || !key || !replacement) return source;
    char needle[256];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    size_t source_length = strlen(source);
    size_t replacement_length = strlen(replacement);
    size_t capacity = source_length + 64;
    size_t length = 0;
    char *result = calloc(capacity, 1);
    if (!result) return source;

    const char *cursor = source;
    const char *match;
    bool changed = false;
    while ((match = strstr(cursor, needle))) {
        const char *colon = match + strlen(needle);
        while (json_space(*colon)) colon++;
        if (*colon != ':') {
            size_t chunk = (size_t)(colon - cursor);
            if (length + chunk + 1 > capacity) {
                capacity = (length + chunk + 1) * 2;
                result = realloc(result, capacity);
            }
            memcpy(result + length, cursor, chunk);
            length += chunk;
            cursor = colon;
            continue;
        }
        const char *quote = colon + 1;
        while (json_space(*quote)) quote++;
        if (*quote != '"') {
            size_t chunk = (size_t)(quote - cursor);
            if (length + chunk + 1 > capacity) {
                capacity = (length + chunk + 1) * 2;
                result = realloc(result, capacity);
            }
            memcpy(result + length, cursor, chunk);
            length += chunk;
            cursor = quote;
            continue;
        }
        const char *value = quote + 1;
        const char *end = value;
        while (*end && (*end != '"' || (end > value && end[-1] == '\\'))) end++;
        if (!*end) break;
        size_t prefix = (size_t)(value - cursor);
        size_t needed = length + prefix + replacement_length + 1;
        if (needed > capacity) {
            capacity = needed * 2;
            result = realloc(result, capacity);
        }
        memcpy(result + length, cursor, prefix);
        length += prefix;
        memcpy(result + length, replacement, replacement_length);
        length += replacement_length;
        cursor = end;
        changed = true;
    }
    size_t tail = strlen(cursor);
    if (length + tail + 1 > capacity) {
        capacity = length + tail + 1;
        result = realloc(result, capacity);
    }
    memcpy(result + length, cursor, tail + 1);
    if (!changed) {
        free(result);
        return source;
    }
    free(source);
    return result;
}

static id normalized_graphql_body(id body) {
    char *json = copy_data_text(body);
    if (!json) return body;
    if (!(contains(json, "PlaybackAccessToken") || contains(json, "StreamAccessToken") ||
          contains(json, "streamPlaybackAccessToken"))) {
        free(json);
        return body;
    }
    tas_diag_metric(TAS_DIAG_GRAPHQL_REWRITE, 1);
    tas_diag_log("GQL_REWRITE", "Playback access-token request playerType normalized to popout");
    json = replace_json_string(json, "playerType", "popout");
    id result = data_from_bytes(json, strlen(json));
    free(json);
    return result ?: body;
}

static id normalized_graphql_request_copy(id original) {
    if (!original) return nil;
    if (!TPKAdblockEnabledFast()) return nil;
    id url = msg0(original, "URL");
    const char *host = utf8(msg0(url, "host"));
    if (!host || strcmp(host, "gql.twitch.tv") != 0) return nil;

    cache_twitch_headers(original);
    id body = msg0(original, "HTTPBody");
    if (!body) return nil;
    char *json = copy_data_text(body);
    bool is_playback_token = json &&
        (contains(json, "PlaybackAccessToken") || contains(json, "StreamAccessToken") ||
         contains(json, "streamPlaybackAccessToken"));
    free(json);
    if (!is_playback_token) return nil;

    id request = msg0(original, "mutableCopy");
    vmsg1(request, "setHTTPBody:", normalized_graphql_body(body));
    return request;
}

static char *remove_query_parameter(const char *url, const char *name) {
    const char *question = strchr(url, '?');
    if (!question) return strdup(url);
    size_t base_length = (size_t)(question - url);
    char *result = calloc(strlen(url) + 1, 1);
    memcpy(result, url, base_length);
    char *query = strdup(question + 1);
    char *save = NULL;
    bool first = true;
    size_t name_length = strlen(name);
    for (char *item = strtok_r(query, "&", &save); item; item = strtok_r(NULL, "&", &save)) {
        if (strncmp(item, name, name_length) == 0 && item[name_length] == '=') continue;
        strcat(result, first ? "?" : "&");
        strcat(result, item);
        first = false;
    }
    free(query);
    return result;
}

static id make_internal_request(const char *url, const char *method) {
    id request = msg1((id)objc_getClass("NSMutableURLRequest"), "requestWithURL:", nsurl(url));
    vmsg1(request, "setHTTPMethod:", nsstr(method));
    vmsg2(request, "setValue:forHTTPHeaderField:", nsstr("1"), nsstr(TAS_INTERNAL_HEADER));
    return request;
}

static id synchronous_request(id request, id *response, id *error) {
    return ((id (*)(id, SEL, id, id *, id *))objc_msgSend)(
        (id)objc_getClass("NSURLConnection"),
        sel_registerName("sendSynchronousRequest:returningResponse:error:"),
        request, response, error);
}

static id blank_video_data(void) {
    static const char encoded[] =
        "AAAAKGZ0eXBtcDQyAAAAAWlzb21tcDQyZGFzaGF2YzFpc282aGxzZgAABEltb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAYagAAAAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAABqHRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAURtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAADvbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAACzc3RibAAAAGdzdHNkAAAAAAAAAAEAAABXbXA0YQAAAAAAAAABAAAAAAAAAAAAAgAQAAAAALuAAAAAAAAzZXNkcwAAAAADgICAIgABAASAgIAUQBUAAAAAAAAAAAAAAAWAgIACEZAGgICAAQIAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAeV0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAoAAAAFoAAAAAAGBbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAA9CQAAAAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABLG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAOxzdGJsAAAAoHN0c2QAAAAAAAAAAQAAAJBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAoABaABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAOmF2Y0MBTUAe/+EAI2dNQB6WUoFAX/LgLUBAQFAAAD6AAA6mDgAAHoQAA9CW7y4KAQAEaOuPIAAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAAASG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAC4AAAAAAoAAAAAAACB0cmV4AAAAAAAAAAIAAAABAACCNQAAAAACQAAA";
    return ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        msg0((id)objc_getClass("NSData"), "alloc"),
        sel_registerName("initWithBase64EncodedString:options:"),
        nsstr(encoded), 0);
}

static id http_response(const char *url, NSInteger status, const char *mime, size_t length, id original) {
    id original_headers = original ? msg0(original, "allHeaderFields") : nil;
    id headers = original_headers ? msg0(original_headers, "mutableCopy") :
                                   msg0((id)objc_getClass("NSMutableDictionary"), "dictionary");
    char length_string[64];
    snprintf(length_string, sizeof(length_string), "%zu", length);
    vmsg2(headers, "setObject:forKey:", nsstr(length_string), nsstr("Content-Length"));
    vmsg2(headers, "setObject:forKey:", nsstr(mime), nsstr("Content-Type"));
    id response = msg0((id)objc_getClass("NSHTTPURLResponse"), "alloc");
    response = ((id (*)(id, SEL, id, NSInteger, id, id))objc_msgSend)(
        response, sel_registerName("initWithURL:statusCode:HTTPVersion:headerFields:"),
        nsurl(url), status, nsstr("HTTP/1.1"), headers);
    if (original_headers) objc_release(headers);
    return response;
}

// Sérialiser les callbacks et l'annulation sur le même verrou récursif.
static void protocol_deliver(id self, id data, id response, id error) {
    objc_sync_enter(self);
    if (!objc_getAssociatedObject(self, &g_protocol_stopped_key)) {
        id client = msg0(self, "client");
        if (error || !response) {
            if (!error) error = ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
                (id)objc_getClass("NSError"), sel_registerName("errorWithDomain:code:userInfo:"),
                nsstr("NSURLErrorDomain"), -1, nil);
            vmsg2(client, "URLProtocol:didFailWithError:", self, error);
        } else {
            vmsg3(client, "URLProtocol:didReceiveResponse:cacheStoragePolicy:", self, response, 0);
            if (data && !objc_getAssociatedObject(self, &g_protocol_stopped_key))
                vmsg2(client, "URLProtocol:didLoadData:", self, data);
            if (!objc_getAssociatedObject(self, &g_protocol_stopped_key))
                vmsg1(client, "URLProtocolDidFinishLoading:", self);
        }
    }
    objc_setAssociatedObject(self, &g_protocol_task_key, nil, 1);
    objc_sync_exit(self);
}

static void protocol_complete(id self, id data, id response, id error) {
    id original = msg0(self, "request");
    const char *original_url = utf8(msg0(msg0(original, "URL"), "absoluteString"));
    objc_sync_enter(self);
    bool stopped = objc_getAssociatedObject(self, &g_protocol_stopped_key) != nil;
    objc_setAssociatedObject(self, &g_protocol_completed_key, nsstr("completed"), 1);
    objc_sync_exit(self);
    if (stopped) {
        if (original_url && is_twitch_hls_url(original_url)) {
            char detail[96];
            snprintf(detail, sizeof(detail), "route=%016llx delivery=cancelled",
                     (unsigned long long)tas_playback_url_id(original_url));
            tas_diag_log("HLS_CANCELLED", detail);
        }
        return;
    }

    id output_data = data, output_response = response, rewritten_response = nil;
    if (original_url && is_twitch_hls_url(original_url)) {
        char detail[256];
        snprintf(detail, sizeof(detail), "transport=NSURLProtocol status=%ld bytes=%zu error=%s",
                 response ? (long)imsg0(response, "statusCode") : 0L,
                 data ? data_length(data) : 0, error ? "yes" : "no");
        tas_diag_log_url("HLS_RESPONSE", original_url, detail);
        if (error || !data || !response || imsg0(response, "statusCode") < 200 ||
            imsg0(response, "statusCode") >= 300) tas_diag_metric(TAS_DIAG_HLS_FAILURE, 1);
    }
    if (!error && data && response && original_url && is_twitch_hls_url(original_url)) {
        char *text = copy_data_text(data);
        if (text && starts_with(text, "#EXTM3U")) {
            char *processed = process_manifest(original_url, text, false);
            output_data = data_from_bytes(processed, strlen(processed));
            rewritten_response = http_response(original_url, imsg0(response, "statusCode"),
                                               "application/vnd.apple.mpegurl",
                                               data_length(output_data), response);
            output_response = rewritten_response;
            free(processed);
        }
        free(text);
    }
    protocol_deliver(self, output_data, output_response, error);
    if (rewritten_response) objc_release(rewritten_response);
}

static id protocol_session(void) {
    static pthread_mutex_t session_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&session_lock);
    id *slot = &g_protocol_session;
    if (!*slot) {
        id config = msg0((id)objc_getClass("NSURLSessionConfiguration"), "defaultSessionConfiguration");
        *slot = objc_retain(msg1((id)objc_getClass("NSURLSession"), "sessionWithConfiguration:", config));
    }
    id session = *slot;
    pthread_mutex_unlock(&session_lock);
    return session;
}

static void protocol_start_loading(id self, SEL command) {
    (void)command;
    id original = msg0(self, "request");
    const char *original_url = utf8(msg0(msg0(original, "URL"), "absoluteString"));

    if (original_url && is_cached_ad_segment(original_url)) {
        tas_diag_metric(TAS_DIAG_SYNTHETIC_SEGMENT, 1);
        tas_diag_log_url("SYNTHETIC_SEGMENT", original_url, "transport=NSURLProtocol");
        id data = blank_video_data();
        id response = http_response(original_url, 200, "video/mp4", data_length(data), nil);
        protocol_deliver(self, data, response, nil);
        objc_release(response);
        return;
    }

    id request = msg0(original, "mutableCopy");
    vmsg2(request, "setValue:forHTTPHeaderField:", nsstr("1"), nsstr(TAS_INTERNAL_HEADER));
    if (original_url && contains(original_url, "/channel/hls/")) {
        char *network_url = remove_query_parameter(original_url, "parent_domains");
        vmsg1(request, "setURL:", nsurl(network_url));
        free(network_url);
    }
    cache_twitch_headers(request);
    id body = msg0(request, "HTTPBody");
    if (body) vmsg1(request, "setHTTPBody:", normalized_graphql_body(body));

    if (original_url && is_twitch_hls_url(original_url)) {
        tas_diag_metric(TAS_DIAG_HLS_INTERCEPTED, 1);
        tas_diag_log_url("HLS_REQUEST", original_url, "transport=NSURLProtocol");
    }

    id session = protocol_session();
    objc_sync_enter(self);
    if (!objc_getAssociatedObject(self, &g_protocol_stopped_key)) {
        id held = objc_retain(self);
        id task = ((id (*)(id, SEL, id, id))objc_msgSend)(session,
            sel_registerName("dataTaskWithRequest:completionHandler:"), request,
            (id)^(id data, id response, id error) {
                protocol_complete(held, data, response, error);
                objc_release(held);
            });
        if (task) {
            objc_setAssociatedObject(self, &g_protocol_task_key, task, 1);
            msg0(task, "resume");
        } else {
            objc_release(held);
            protocol_deliver(self, nil, nil, nil);
        }
    }
    objc_sync_exit(self);
    objc_release(request);
}

static void protocol_stop_loading(id self, SEL command) {
    (void)command;
    objc_sync_enter(self);
    objc_setAssociatedObject(self, &g_protocol_stopped_key, nsstr("stopped"), 1);
    id task = objc_retain(objc_getAssociatedObject(self, &g_protocol_task_key));
    objc_setAssociatedObject(self, &g_protocol_task_key, nil, 1);
    msg0(task, "cancel");
    objc_release(task);
    objc_sync_exit(self);
}

static BOOL protocol_can_init(id self, SEL command, id request) {
    (void)self;
    (void)command;
    if (!TPKAdblockEnabledFast()) return NO;
    // Ignorer les requêtes internes pour éviter une interception récursive.
    if (msg1(request, "valueForHTTPHeaderField:", nsstr(TAS_INTERNAL_HEADER))) return NO;
    id url = msg0(request, "URL");
    const char *absolute = utf8(msg0(url, "absoluteString"));
    return is_twitch_hls_url(absolute) || is_cached_ad_segment(absolute);
}

static id protocol_canonical_request(id self, SEL command, id request) {
    (void)self;
    (void)command;
    return request;
}

static void append_text(char **buffer, size_t *length, size_t *capacity, const char *text) {
    size_t incoming = strlen(text);
    if (*length + incoming + 1 > *capacity) {
        size_t next = *capacity ? *capacity : 4096;
        while (next < *length + incoming + 1) next *= 2;
        char *grown = realloc(*buffer, next);
        if (!grown) return;
        *buffer = grown;
        *capacity = next;
    }
    memcpy(*buffer + *length, text, incoming);
    *length += incoming;
    (*buffer)[*length] = '\0';
}

static char *absolute_url(const char *base, const char *relative) {
    if (starts_with(relative, "http://") || starts_with(relative, "https://")) return strdup(relative);
    id base_url = nsurl(base);
    id value = msg2((id)objc_getClass("NSURL"), "URLWithString:relativeToURL:", nsstr(relative), base_url);
    return strdup(utf8(msg0(value, "absoluteString")) ?: relative);
}

static char *custom_scheme_url(const char *value) {
    if (starts_with(value, "https://")) {
        size_t length = strlen(value) + strlen(TAS_SCHEME) + 1;
        char *result = malloc(length);
        snprintf(result, length, TAS_SCHEME "://%s", value + strlen("https://"));
        return result;
    }
    return strdup(value);
}

static char *https_scheme_url(const char *value) {
    if (starts_with(value, TAS_SCHEME "://")) {
        size_t length = strlen(value) + 1;
        char *result = malloc(length);
        snprintf(result, length, "https://%s", value + strlen(TAS_SCHEME "://"));
        return result;
    }
    return strdup(value);
}

static void parse_attribute(const char *line, const char *name, char *output, size_t capacity) {
    output[0] = '\0';
    const char *start = strstr(line, name);
    if (!start) return;
    start += strlen(name);
    if (*start == '"') start++;
    const char *end = start;
    while (*end && *end != ',' && *end != '"' && *end != '\r' && *end != '\n') end++;
    size_t length = (size_t)(end - start);
    if (length >= capacity) length = capacity - 1;
    memcpy(output, start, length);
    output[length] = '\0';
}

static void trim_manifest_line(char *line) {
    size_t length = strlen(line);
    while (length && (line[length - 1] == '\r' || line[length - 1] == '\n')) {
        line[--length] = '\0';
    }
}

static void channel_from_master_url(const char *url, char *output, size_t capacity) {
    output[0] = '\0';
    const char *marker = strstr(url, "/channel/hls/");
    if (!marker) return;
    marker += strlen("/channel/hls/");
    const char *end = strstr(marker, ".m3u8");
    if (!end) return;
    size_t length = (size_t)(end - marker);
    if (length >= capacity) length = capacity - 1;
    memcpy(output, marker, length);
    output[length] = '\0';
}

static void add_variant_route_locked(TASStreamRef ref, const char *url, time_t now) {
    if (!stream_ref_matches_locked(ref) || !url || !url[0] || strlen(url) >= TAS_URL_CAPACITY) return;

    size_t route_index = TAS_MAX_VARIANT_ROUTES;
    for (size_t i = 0; i < TAS_MAX_VARIANT_ROUTES; i++) {
        if (g_variant_routes[i].url[0] && strcmp(g_variant_routes[i].url, url) == 0) {
            route_index = i;
            break;
        }
        if (route_index == TAS_MAX_VARIANT_ROUTES && !g_variant_routes[i].url[0]) route_index = i;
    }
    if (route_index == TAS_MAX_VARIANT_ROUTES) {
        route_index = 0;
        for (size_t i = 1; i < TAS_MAX_VARIANT_ROUTES; i++) {
            if (g_variant_routes[i].last_seen < g_variant_routes[route_index].last_seen) route_index = i;
        }
    }

    TASVariantRoute *route = &g_variant_routes[route_index];
    if (strcmp(route->url, url) || route->generation != ref.generation) {
        continuity_free(route->continuity[0]);
        continuity_free(route->continuity[1]);
        route->continuity[0] = route->continuity[1] = NULL;
    }
    copy_string(route->url, sizeof(route->url), url);
    route->stream_index = ref.index;
    route->generation = ref.generation;
    route->last_seen = now;
}

static void register_variant_routes_locked(TASStreamRef ref, const char *master_url,
                                           const char *master) {
    if (!stream_ref_matches_locked(ref)) return;
    clear_routes_for_stream_locked(ref.index);

    char *copy = strdup(master);
    if (!copy) return;
    time_t now = time(NULL);
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (line[0] != '#' && contains(line, ".m3u8")) {
            char *absolute = absolute_url(master_url, line);
            add_variant_route_locked(ref, absolute, now);
            free(absolute);
        }
    }
    free(copy);
}

static TASStreamRef stream_for_variant_locked(const char *url) {
    TASStreamRef invalid = {0, 0, false};
    time_t now = time(NULL);
    for (size_t i = 0; i < TAS_MAX_VARIANT_ROUTES; i++) {
        TASVariantRoute *route = &g_variant_routes[i];
        if (!route->url[0] || strcmp(route->url, url) != 0) continue;
        TASStreamRef ref = {route->stream_index, route->generation, true};
        if (!stream_ref_matches_locked(ref)) {
            continuity_free(route->continuity[0]);
            continuity_free(route->continuity[1]);
            memset(route, 0, sizeof(*route));
            continue;
        }
        route->last_seen = now;
        g_streams[ref.index].last_seen = now;
        return ref;
    }
    return invalid;
}

static bool snapshot_stream_for_variant(const char *url, TASStreamSnapshot *snapshot) {
    memset(snapshot, 0, sizeof(*snapshot));
    pthread_mutex_lock(&g_lock);
    TASStreamRef ref = stream_for_variant_locked(url);
    if (!stream_ref_matches_locked(ref)) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }
    TASStreamContext *stream = &g_streams[ref.index];
    snapshot->ref = ref;
    copy_string(snapshot->channel, sizeof(snapshot->channel), stream->channel);
    copy_string(snapshot->master_url, sizeof(snapshot->master_url), stream->master_url);
    copy_string(snapshot->backup_variant_url, sizeof(snapshot->backup_variant_url),
                stream->backup_variant_url);
    snapshot->backup_created = stream->backup_created;
    snapshot->master_manifest = stream->master_manifest ? strdup(stream->master_manifest) : NULL;
    pthread_mutex_unlock(&g_lock);
    return snapshot->master_manifest != NULL;
}

static long long variant_resolution_area(const char *resolution) {
    if (!resolution || resolution[0] < '0' || resolution[0] > '9') return 0;
    char *end = NULL;
    errno = 0;
    unsigned long long width = strtoull(resolution, &end, 10);
    if (errno || !width || *end != 'x' || end[1] < '0' || end[1] > '9') return 0;
    const char *height_start = end + 1;
    errno = 0;
    unsigned long long height = strtoull(height_start, &end, 10);
    if (errno || *end || !height || width > INT64_MAX / height) return 0;
    return (long long)(width * height);
}

static bool variant_is_audio_only(const char *attributes, bool *video_codec) {
    char video[128], name[128];
    parse_attribute(attributes, "VIDEO=", video, sizeof(video));
    parse_attribute(attributes, "NAME=", name, sizeof(name));
    bool audio_codec = false;
    *video_codec = false;
    const char *codecs = strstr(attributes, "CODECS=");
    if (codecs) {
        codecs += strlen("CODECS=");
        bool quoted = *codecs == '"';
        if (quoted) codecs++;
        const char *end = codecs;
        while (*end && *end != '"' && *end != '\r' && *end != '\n' && (quoted || *end != ',')) end++;
        while (codecs < end) {
            while (codecs < end && (*codecs == ',' || *codecs == ' ')) codecs++;
            size_t length = (size_t)(end - codecs);
            const char *video_prefixes[] = {"avc1", "avc3", "hvc1", "hev1", "av01", "vp09", "vp08", "dvh1", "dvhe", "mp4v"};
            const char *audio_prefixes[] = {"mp4a", "ac-3", "ec-3", "opus", "flac", "alac"};
            for (size_t i = 0; i < sizeof(video_prefixes) / sizeof(video_prefixes[0]); i++)
                if (length >= 4 && !strncmp(codecs, video_prefixes[i], 4) && (length == 4 || codecs[4] == '.' || codecs[4] == ',' || codecs[4] == ' ')) *video_codec = true;
            for (size_t i = 0; i < sizeof(audio_prefixes) / sizeof(audio_prefixes[0]); i++)
                if (length >= 4 && !strncmp(codecs, audio_prefixes[i], 4) && (length == 4 || codecs[4] == '.' || codecs[4] == ',' || codecs[4] == ' ')) audio_codec = true;
            while (codecs < end && *codecs != ',') codecs++;
        }
    }
    return !strcmp(video, "audio_only") || !strcmp(name, "audio_only") || (audio_codec && !*video_codec);
}

static bool variant_metadata(const char *master, const char *master_url, const char *variant_url,
                             char *resolution, size_t resolution_capacity,
                             char *framerate, size_t framerate_capacity, bool *audio_only) {
    char *copy = strdup(master);
    char *save = NULL;
    char *previous = NULL;
    bool found = false;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (line[0] != '#' && contains(line, ".m3u8")) {
            char *absolute = absolute_url(master_url, line);
            if (strcmp(absolute, variant_url) == 0 && previous && starts_with(previous, "#EXT-X-STREAM-INF")) {
                parse_attribute(previous, "RESOLUTION=", resolution, resolution_capacity);
                parse_attribute(previous, "FRAME-RATE=", framerate, framerate_capacity);
                bool video_codec;
                *audio_only = variant_is_audio_only(previous, &video_codec);
                found = true;
                free(absolute);
                break;
            }
            free(absolute);
        }
        previous = line;
    }
    free(copy);
    return found;
}

static char *variant_for_resolution(const char *master, const char *master_url,
                                    const char *resolution, const char *framerate, bool require_video) {
    char *copy = strdup(master);
    char *save = NULL;
    char *previous = NULL;
    char *closest = NULL;
    long long closest_difference = INT64_MAX;
    char *resolution_match = NULL;
    char *exact = NULL;
    long long target_area = variant_resolution_area(resolution);
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (line[0] != '#' && contains(line, ".m3u8") && previous && starts_with(previous, "#EXT-X-STREAM-INF")) {
            char line_resolution[128];
            char line_framerate[64];
            parse_attribute(previous, "RESOLUTION=", line_resolution, sizeof(line_resolution));
            parse_attribute(previous, "FRAME-RATE=", line_framerate, sizeof(line_framerate));
            long long area = variant_resolution_area(line_resolution);
            bool video_codec;
            bool audio_only = variant_is_audio_only(previous, &video_codec);
            if (require_video && (audio_only || (!area && !video_codec))) {
                tas_diag_log("VAFT_VARIANT_REJECTED", audio_only ? "reason=audio_only" : "reason=video_unconfirmed");
                previous = line;
                continue;
            }
            char *absolute = absolute_url(master_url, line);
            if (resolution[0] && strcmp(line_resolution, resolution) == 0) {
                if (!resolution_match) resolution_match = strdup(absolute);
                if (!framerate[0] || strcmp(line_framerate, framerate) == 0) {
                    exact = strdup(absolute);
                    free(absolute);
                    break;
                }
            }
            long long difference = require_video && !area ? INT64_MAX :
                                   (target_area && area ? llabs(area - target_area) : 0);
            if (!closest || difference < closest_difference) {
                free(closest);
                closest = strdup(absolute);
                closest_difference = difference;
            }
            free(absolute);
        }
        previous = line;
    }
    char *result = exact ?: resolution_match ?: closest;
    if (result != resolution_match) free(resolution_match);
    if (result != closest) free(closest);
    free(copy);
    return result;
}

static char *url_encode(const char *value) {
    static const char hex[] = "0123456789ABCDEF";
    size_t length = strlen(value);
    char *result = malloc(length * 3 + 1);
    char *out = result;
    for (const unsigned char *in = (const unsigned char *)value; *in; in++) {
        if ((*in >= 'a' && *in <= 'z') || (*in >= 'A' && *in <= 'Z') ||
            (*in >= '0' && *in <= '9') || strchr("-._~", *in)) {
            *out++ = (char)*in;
        } else {
            *out++ = '%';
            *out++ = hex[*in >> 4];
            *out++ = hex[*in & 15];
        }
    }
    *out = '\0';
    return result;
}

static char *usher_with_token(const char *original, const char *signature, const char *token) {
    char *sig = url_encode(signature);
    char *tok = url_encode(token);
    const char *question = strchr(original, '?');
    size_t base_length = question ? (size_t)(question - original) : strlen(original);
    size_t capacity = strlen(original) + strlen(sig) + strlen(tok) + 64;
    char *result = calloc(capacity, 1);
    memcpy(result, original, base_length);
    result[base_length] = '\0';
    strcat(result, "?");
    if (question) {
        char *query = strdup(question + 1);
        char *save = NULL;
        for (char *item = strtok_r(query, "&", &save); item; item = strtok_r(NULL, "&", &save)) {
            if (starts_with(item, "sig=") || starts_with(item, "token=") || starts_with(item, "parent_domains=")) continue;
            strcat(result, item);
            strcat(result, "&");
        }
        free(query);
    }
    strcat(result, "sig=");
    strcat(result, sig);
    strcat(result, "&token=");
    strcat(result, tok);
    free(sig);
    free(tok);
    return result;
}

static id json_value(id object, const char *key) {
    return msg1(object, "objectForKeyedSubscript:", nsstr(key));
}

static bool fetch_bytes(const char *url, id *data, id *response) {
    id request = make_internal_request(url, "GET");
    id error = nil;
    *data = synchronous_request(request, response, &error);
    bool success = *data && *response && !error && imsg0(*response, "statusCode") >= 200 && imsg0(*response, "statusCode") < 300;
    if (!success) {
        char detail[192];
        snprintf(detail, sizeof(detail), "source=%016llx status=%ld data=%s error=%s error_code=%ld",
                 (unsigned long long)tas_playback_url_id(url),
                 *response ? (long)imsg0(*response, "statusCode") : 0L,
                 *data ? "yes" : "no", error ? "yes" : "no",
                 error ? (long)imsg0(error, "code") : 0L);
        tas_diag_log("BACKUP_FETCH_FAILURE", detail);
    }
    return success;
}

static bool request_access_token(const char *channel, const char *player_type,
                                 char *signature, size_t signature_capacity,
                                 char *token, size_t token_capacity) {
    const char *platform = strcmp(player_type, "autoplay") == 0 ? "android" : "web";
    char json[8192];
    snprintf(json, sizeof(json),
        "{\"operationName\":\"PlaybackAccessToken\",\"variables\":{\"isLive\":true,"
        "\"login\":\"%s\",\"isVod\":false,\"vodID\":\"\",\"playerType\":\"%s\","
        "\"platform\":\"%s\"},\"extensions\":{\"persistedQuery\":{\"version\":1,"
        "\"sha256Hash\":\"%s\"}}}", channel, player_type, platform, TAS_TOKEN_HASH);

    id request = make_internal_request("https://gql.twitch.tv/gql", "POST");
    vmsg2(request, "setValue:forHTTPHeaderField:", nsstr("application/json"), nsstr("Content-Type"));
    pthread_mutex_lock(&g_lock);
    if (!g_device_id[0]) {
        static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
        for (size_t i = 0; i < 32; i++) g_device_id[i] = alphabet[arc4random_uniform(36)];
        g_device_id[32] = '\0';
    }
    vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(TAS_CLIENT_ID), nsstr("Client-Id"));
    if (g_device_id[0]) vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(g_device_id), nsstr("X-Device-Id"));
    if (g_authorization[0]) vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(g_authorization), nsstr("Authorization"));
    if (g_integrity[0]) vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(g_integrity), nsstr("Client-Integrity"));
    if (g_client_version[0]) vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(g_client_version), nsstr("Client-Version"));
    if (g_client_session[0]) vmsg2(request, "setValue:forHTTPHeaderField:", nsstr(g_client_session), nsstr("Client-Session-Id"));
    pthread_mutex_unlock(&g_lock);
    vmsg1(request, "setHTTPBody:", data_from_bytes(json, strlen(json)));

    id response = nil;
    id error = nil;
    id data = synchronous_request(request, &response, &error);
    if (!data || error || !response || imsg0(response, "statusCode") != 200) {
        char detail[256];
        snprintf(detail, sizeof(detail), "player=%s status=%ld data=%s error=%s",
                 player_type, response ? (long)imsg0(response, "statusCode") : 0L,
                 data ? "yes" : "no", error ? "yes" : "no");
        tas_diag_metric(TAS_DIAG_TOKEN_FAILURE, 1);
        tas_diag_log("TOKEN_FAILURE", detail);
        return false;
    }
    id json_error = nil;
    id root = ((id (*)(id, SEL, id, NSUInteger, id *))objc_msgSend)(
        (id)objc_getClass("NSJSONSerialization"), sel_registerName("JSONObjectWithData:options:error:"),
        data, 0, &json_error);
    if (!root || json_error) {
        tas_diag_metric(TAS_DIAG_TOKEN_FAILURE, 1);
        tas_diag_log("TOKEN_FAILURE", "PlaybackAccessToken response was not valid JSON");
        return false;
    }
    id access = json_value(json_value(root, "data"), "streamPlaybackAccessToken");
    const char *sig = utf8(json_value(access, "signature"));
    const char *tok = utf8(json_value(access, "value"));
    if (!sig || !tok) {
        char detail[160];
        snprintf(detail, sizeof(detail), "player=%s response missing signature or token", player_type);
        tas_diag_metric(TAS_DIAG_TOKEN_FAILURE, 1);
        tas_diag_log("TOKEN_FAILURE", detail);
        return false;
    }
    copy_string(signature, signature_capacity, sig);
    copy_string(token, token_capacity, tok);
    char detail[96];
    snprintf(detail, sizeof(detail), "player=%s", player_type);
    tas_diag_log("TOKEN_SUCCESS", detail);
    return true;
}

static bool has_ad_markers(const char *playlist) {
    return contains(playlist, "stitched") ||
           contains(playlist, "\"MIDROLL\"") || contains(playlist, "\"midroll\"");
}

typedef struct {
    size_t extinf;
    size_t live_segments;
    size_t non_live_segments;
    size_t variants;
    size_t dateranges;
    size_t discontinuities;
    size_t prefetches;
    size_t scte_markers;
    bool stitched;
    bool midroll;
    bool twitch_ad_url;
} TASManifestStats;

static TASManifestStats manifest_stats(const char *playlist) {
    TASManifestStats stats = {0};
    if (!playlist) return stats;
    stats.stitched = contains(playlist, "stitched");
    stats.midroll = contains(playlist, "\"MIDROLL\"") || contains(playlist, "\"midroll\"");
    stats.twitch_ad_url = contains(playlist, "X-TV-TWITCH-AD-URL") ||
                          contains(playlist, "X-TV-TWITCH-AD-CLICK-TRACKING-URL");
    char *copy = strdup(playlist);
    if (!copy) return stats;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (starts_with(line, "#EXTINF")) {
            stats.extinf++;
            if (contains(line, ",live")) stats.live_segments++;
            else stats.non_live_segments++;
        } else if (starts_with(line, "#EXT-X-STREAM-INF")) {
            stats.variants++;
        } else if (starts_with(line, "#EXT-X-DATERANGE")) {
            stats.dateranges++;
        } else if (starts_with(line, "#EXT-X-DISCONTINUITY")) {
            stats.discontinuities++;
        } else if (starts_with(line, "#EXT-X-TWITCH-PREFETCH")) {
            stats.prefetches++;
        }
        if (contains(line, "SCTE")) stats.scte_markers++;
    }
    free(copy);
    return stats;
}

static void format_manifest_stats(char *output, size_t capacity, const TASManifestStats *stats,
                                  size_t bytes, bool mapped) {
    snprintf(output, capacity,
             "bytes=%zu mapped=%s variants=%zu extinf=%zu live=%zu non_live=%zu "
             "stitched=%s midroll=%s ad_url_tag=%s daterange=%zu discontinuity=%zu "
             "prefetch=%zu scte=%zu",
             bytes, mapped ? "yes" : "no", stats->variants, stats->extinf,
             stats->live_segments, stats->non_live_segments,
             stats->stitched ? "yes" : "no", stats->midroll ? "yes" : "no",
             stats->twitch_ad_url ? "yes" : "no", stats->dateranges,
             stats->discontinuities, stats->prefetches, stats->scte_markers);
}

typedef struct {
    bool valid;
    uint64_t generation;
    uint64_t route;
    uint64_t source;
    int kind;
    time_t progress_at;
    TASPlaybackManifest output;
} TASPlaybackTraceState;

static pthread_mutex_t g_playback_trace_lock = PTHREAD_MUTEX_INITIALIZER;
static TASPlaybackTraceState g_playback_traces[64];
static size_t g_next_playback_trace;

static void trace_playback_output(TASStreamRef ref, const char *master_url,
                                  const char *original_url, const char *original,
                                  const char *selected_url, const char *selected,
                                  bool filtered) {
    if (!tas_diagnostics_logging_enabled() || !selected) return;
    uint64_t route = tas_playback_url_id(original_url);
    uint64_t source = tas_playback_url_id(selected_url);
    tas_diag_trace_resources(ref.generation, route, source, selected);
    int kind = selected_url && strcmp(selected_url, original_url) ? 1 : (filtered ? 2 : 0);
    const char *kinds[] = {"original", "alternate", "filtered"};
    TASPlaybackManifest input = tas_playback_parse(original);
    TASPlaybackManifest output = tas_playback_parse(selected);
    time_t now = time(NULL);
    pthread_mutex_lock(&g_playback_trace_lock);
    size_t slot = 64;
    for (size_t i = 0; i < 64; i++) {
        if (g_playback_traces[i].valid && g_playback_traces[i].generation == ref.generation &&
            g_playback_traces[i].route == route) {
            slot = i;
            break;
        }
    }
    bool initial = slot == 64;
    if (initial) slot = g_next_playback_trace++ % 64;
    TASPlaybackTraceState previous = initial ? (TASPlaybackTraceState){0} : g_playback_traces[slot];
    bool changed = initial || previous.kind != kind || previous.source != source;
    bool progressed = changed || previous.output.media_sequence != output.media_sequence ||
                      previous.output.last_segment != output.last_segment;
    time_t progress_at = progressed ? now : previous.progress_at;
    g_playback_traces[slot] = (TASPlaybackTraceState){
        .valid = true, .generation = ref.generation, .route = route, .source = source,
        .kind = kind, .progress_at = progress_at, .output = output
    };
    pthread_mutex_unlock(&g_playback_trace_lock);
    char input_detail[448], output_detail[448], previous_detail[448], detail[1536];
    tas_playback_format(input_detail, sizeof(input_detail), &input);
    tas_playback_format(output_detail, sizeof(output_detail), &output);
    if (changed) {
        tas_playback_format(previous_detail, sizeof(previous_detail), &previous.output);
        snprintf(detail, sizeof(detail),
                 "generation=%llu route=%016llx from=%s to=%s filtered=%d old_source=%016llx new_source=%016llx "
                 "previous={%s} output={%s}",
                 (unsigned long long)ref.generation, (unsigned long long)route,
                 initial ? "start" : kinds[previous.kind], kinds[kind], filtered,
                 (unsigned long long)previous.source, (unsigned long long)source,
                 initial ? "unknown" : previous_detail, output_detail);
        tas_diag_metric(TAS_DIAG_PLAYBACK_SWITCH, 1);
        tas_diag_log("PLAYBACK_SWITCH", detail);
        const char *phase = !initial && previous.kind == 1 && kind == 0 ? "return-original" :
                            (kind == 1 ? "alternate" : (kind == 2 ? "filtered" : "original"));
        tas_diag_player_snapshots(ref.generation, route, tas_playback_url_id(master_url), phase);
    }
    snprintf(detail, sizeof(detail),
             "generation=%llu route=%016llx source=%s filtered=%d source_id=%016llx unchanged_for=%lld "
             "input={%s} output={%s}",
             (unsigned long long)ref.generation, (unsigned long long)route, kinds[kind], filtered,
             (unsigned long long)source, (long long)(now >= progress_at ? now - progress_at : 0),
             input_detail, output_detail);
    tas_diag_log("PLAYBACK_HLS", detail);
}

static void clear_backup_master(TASStreamRef stream_ref, size_t index) {
    pthread_mutex_lock(&g_lock);
    if (stream_ref_matches_locked(stream_ref)) {
        TASStreamContext *stream = &g_streams[stream_ref.index];
        free(stream->backup_masters[index]);
        free(stream->backup_master_urls[index]);
        stream->backup_masters[index] = NULL;
        stream->backup_master_urls[index] = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

static char *load_backup_master(const char *original_master, const char *channel,
                                TASStreamRef stream_ref, size_t index,
                                bool *was_cached, char **master_url_out) {
    *was_cached = false;
    *master_url_out = NULL;
    pthread_mutex_lock(&g_lock);
    if (stream_ref_matches_locked(stream_ref) &&
        g_streams[stream_ref.index].backup_masters[index] &&
        g_streams[stream_ref.index].backup_master_urls[index]) {
        *was_cached = true;
        char *master = strdup(g_streams[stream_ref.index].backup_masters[index]);
        *master_url_out = strdup(g_streams[stream_ref.index].backup_master_urls[index]);
        pthread_mutex_unlock(&g_lock);
        if (!master || !*master_url_out) {
            free(master);
            free(*master_url_out);
            *master_url_out = NULL;
            return NULL;
        }
        return master;
    }
    pthread_mutex_unlock(&g_lock);

    char signature[4096];
    char token[16384];
    if (!request_access_token(channel, g_player_types[index], signature, sizeof(signature), token, sizeof(token))) {
        return NULL;
    }
    char *master_url = usher_with_token(original_master, signature, token);
    id master_data = nil;
    id master_response = nil;
    if (!fetch_bytes(master_url, &master_data, &master_response)) {
        char detail[192];
        snprintf(detail, sizeof(detail), "player=%s status=%ld",
                 g_player_types[index], master_response ? (long)imsg0(master_response, "statusCode") : 0L);
        tas_diag_log_url("BACKUP_MASTER_FAILURE", master_url, detail);
        free(master_url);
        return NULL;
    }
    char *master = copy_data_text(master_data);
    if (!master) {
        char detail[128];
        snprintf(detail, sizeof(detail), "player=%s response copy failed", g_player_types[index]);
        tas_diag_log("BACKUP_MASTER_FAILURE", detail);
        free(master_url);
        return NULL;
    }
    char detail[192];
    snprintf(detail, sizeof(detail), "player=%s bytes=%zu cached=no",
             g_player_types[index], strlen(master));
    tas_diag_log_url("BACKUP_MASTER", master_url, detail);
    if (strlen(master) < TAS_MANIFEST_CAPACITY && strlen(master_url) < TAS_URL_CAPACITY) {
        pthread_mutex_lock(&g_lock);
        if (stream_ref_matches_locked(stream_ref)) {
            replace_owned_string(&g_streams[stream_ref.index].backup_masters[index], master);
            replace_owned_string(&g_streams[stream_ref.index].backup_master_urls[index], master_url);
        }
        pthread_mutex_unlock(&g_lock);
    }
    *master_url_out = master_url;
    return master;
}

static char *fetch_vaft_variant(const char *original_master, const char *channel,
                                const char *resolution, const char *framerate,
                                TASStreamRef stream_ref, bool require_video,
                                char **selected_base_out) {
    char *fallback = NULL;
    char *fallback_url = NULL;
    const char *fallback_type = NULL;
    *selected_base_out = NULL;

    for (size_t player_index = 0; player_index < TAS_PLAYER_TYPE_COUNT; player_index++) {
        for (size_t attempt = 0; attempt < 2; attempt++) {
            bool was_cached = false;
            char *master_url = NULL;
            char *master = load_backup_master(original_master, channel, stream_ref, player_index,
                                              &was_cached, &master_url);
            if (!master || !master_url) {
                free(master);
                free(master_url);
                break;
            }
            char *variant_url = variant_for_resolution(master, master_url, resolution, framerate, require_video);
            if (!variant_url) tas_diag_log("VAFT_VARIANT_UNAVAILABLE", "reason=no_eligible_variant action=try_next_existing_candidate");
            free(master);
            free(master_url);

            id variant_data = nil;
            id variant_response = nil;
            bool loaded = variant_url && fetch_bytes(variant_url, &variant_data, &variant_response);
            char *variant = loaded ? copy_data_text(variant_data) : NULL;
            bool has_ads = !variant || has_ad_markers(variant);
            char candidate_detail[256];
            snprintf(candidate_detail, sizeof(candidate_detail),
                     "player=%s cached_master=%s loaded=%s status=%ld bytes=%zu known_ad=%s",
                     g_player_types[player_index], was_cached ? "yes" : "no",
                     loaded ? "yes" : "no",
                     variant_response ? (long)imsg0(variant_response, "statusCode") : 0L,
                     variant ? strlen(variant) : 0,
                     has_ads ? "yes" : "no");
            tas_diag_log_url("VAFT_CANDIDATE", variant_url, candidate_detail);

            if (variant && player_index == 0) {
                free(fallback);
                free(fallback_url);
                fallback = strdup(variant);
                fallback_url = strdup(variant_url);
                fallback_type = g_player_types[player_index];
            } else if (variant && player_index == TAS_PLAYER_TYPE_COUNT - 1 && !fallback) {
                fallback = strdup(variant);
                fallback_url = strdup(variant_url);
                fallback_type = g_player_types[player_index];
            }

            if (!has_ads) {
                pthread_mutex_lock(&g_lock);
                if (stream_ref_matches_locked(stream_ref)) {
                    TASStreamContext *stream = &g_streams[stream_ref.index];
                    replace_owned_string(&stream->backup_variant_url, variant_url);
                    copy_string(stream->backup_player_type, sizeof(stream->backup_player_type),
                                g_player_types[player_index]);
                    stream->backup_created = time(NULL);
                    stream->last_seen = stream->backup_created;
                }
                pthread_mutex_unlock(&g_lock);
                fprintf(stderr, "[TAS] VAFT switched %s to clean %s HLS\n", channel, g_player_types[player_index]);
                tas_diag_metric(TAS_DIAG_CLEAN_ALTERNATE, 1);
                char detail[128];
                snprintf(detail, sizeof(detail), "player=%s", g_player_types[player_index]);
                tas_diag_log_url("VAFT_CLEAN_SWAP", variant_url, detail);
                free(fallback);
                free(fallback_url);
                *selected_base_out = variant_url;
                return variant;
            }

            free(variant);
            free(variant_url);
            clear_backup_master(stream_ref, player_index);
            if (!was_cached) break;
        }
    }

    if (fallback) {
        fprintf(stderr, "[TAS] VAFT using %s fallback with stitched segments suppressed\n",
                fallback_type ?: "last-resort");
        char detail[160];
        snprintf(detail, sizeof(detail), "player=%s known_ad=yes action=strip",
                 fallback_type ?: "last-resort");
        tas_diag_log_url("VAFT_FALLBACK", fallback_url, detail);
        *selected_base_out = fallback_url;
        return fallback;
    }
    free(fallback_url);
    return NULL;
}

static char *strip_ad_segments(const char *playlist, const char *base_url) {
    char *copy = strdup(playlist);
    char *result = NULL;
    size_t length = 0;
    size_t capacity = 0;
    char *save = NULL;
    bool cache_next_uri = false;
    size_t stripped_segments = 0;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (cache_next_uri && line[0] != '#') {
            remember_ad_segment(base_url, line);
            stripped_segments++;
            cache_next_uri = false;
        }
        if (starts_with(line, "#EXTINF") && !contains(line, ",live")) {
            cache_next_uri = true;
        }
        if (starts_with(line, "#EXT-X-TWITCH-PREFETCH:")) continue;
        append_text(&result, &length, &capacity, line);
        append_text(&result, &length, &capacity, "\n");
    }
    free(copy);
    if (stripped_segments) {
        tas_diag_metric(TAS_DIAG_STRIPPED_SEGMENT, stripped_segments);
        char detail[128];
        snprintf(detail, sizeof(detail), "segments=%zu", stripped_segments);
        tas_diag_log_url("SEGMENTS_SUPPRESSED", base_url, detail);
    }
    return result ?: strdup("#EXTM3U\n");
}

static char *playback_url(const char *absolute, bool custom_scheme) {
    return custom_scheme ? custom_scheme_url(absolute) : strdup(absolute);
}

static char *rewrite_manifest_urls(const char *playlist, const char *base_url, bool custom_scheme) {
    char *copy = strdup(playlist);
    char *result = NULL;
    size_t length = 0;
    size_t capacity = 0;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (line[0] != '#' && line[0]) {
            char *absolute = absolute_url(base_url, line);
            char *playable = playback_url(absolute, custom_scheme);
            append_text(&result, &length, &capacity, playable);
            free(playable);
            free(absolute);
        } else if (starts_with(line, "#EXT-X-TWITCH-PREFETCH:")) {
            const char *value = line + strlen("#EXT-X-TWITCH-PREFETCH:");
            char *absolute = absolute_url(base_url, value);
            char *playable = playback_url(absolute, custom_scheme);
            append_text(&result, &length, &capacity, "#EXT-X-TWITCH-PREFETCH:");
            append_text(&result, &length, &capacity, playable);
            free(playable);
            free(absolute);
        } else {
            char *uri = strstr(line, "URI=\"");
            if (uri) {
                const char *value = uri + strlen("URI=\"");
                const char *end = strchr(value, '"');
                if (end) {
                    char relative[8192];
                    size_t size = (size_t)(end - value);
                    if (size >= sizeof(relative)) size = sizeof(relative) - 1;
                    memcpy(relative, value, size);
                    relative[size] = '\0';
                    char *absolute = absolute_url(base_url, relative);
                    char *playable = playback_url(absolute, custom_scheme);
                    char prefix[16384];
                    size_t prefix_length = (size_t)(value - line);
                    if (prefix_length >= sizeof(prefix)) prefix_length = sizeof(prefix) - 1;
                    memcpy(prefix, line, prefix_length);
                    prefix[prefix_length] = '\0';
                    append_text(&result, &length, &capacity, prefix);
                    append_text(&result, &length, &capacity, playable);
                    append_text(&result, &length, &capacity, end);
                    free(playable);
                    free(absolute);
                } else {
                    append_text(&result, &length, &capacity, line);
                }
            } else {
                append_text(&result, &length, &capacity, line);
            }
        }
        append_text(&result, &length, &capacity, "\n");
    }
    free(copy);
    return result ?: strdup(playlist);
}

#define TAS_CONTINUITY_SEGMENTS 128

typedef struct {
    char *body;
    char *map;
    double date;
    double duration;
    uint64_t discontinuity;
} TASContinuitySegment;

typedef struct {
    TASContinuitySegment segments[TAS_CONTINUITY_SEGMENTS];
    size_t count;
    uint64_t sequence;
    unsigned target;
    unsigned version;
    char *prefetch;
} TASContinuityPlaylist;

struct TASContinuity {
    TASContinuityPlaylist output;
    uint64_t source;
    uint64_t source_discontinuity;
    bool rewriting;
};

static void continuity_playlist_clear(TASContinuityPlaylist *playlist) {
    for (size_t i = 0; i < playlist->count; i++) {
        free(playlist->segments[i].body);
        free(playlist->segments[i].map);
    }
    free(playlist->prefetch);
    memset(playlist, 0, sizeof(*playlist));
}

static void continuity_free(TASContinuity *state) {
    if (!state) return;
    continuity_playlist_clear(&state->output);
    free(state);
}

static double continuity_date(const char *value) {
    struct tm date = {0};
    char *end = strptime(value, "%Y-%m-%dT%H:%M:%S", &date);
    if (!end) return NAN;
    double fraction = 0;
    if (*end == '.') {
        const char *start = end;
        fraction = strtod(start, &end);
        if (end == start || !isfinite(fraction)) return NAN;
    }
    int zone = 0;
    if (*end == 'Z' && !end[1]) {}
    else if ((*end == '+' || *end == '-') && strlen(end) == 6 && end[3] == ':' &&
             end[1] >= '0' && end[1] <= '9' && end[2] >= '0' && end[2] <= '9' &&
             end[4] >= '0' && end[4] <= '9' && end[5] >= '0' && end[5] <= '9') {
        int hours = (end[1] - '0') * 10 + end[2] - '0';
        int minutes = (end[4] - '0') * 10 + end[5] - '0';
        if (hours > 23 || minutes > 59) return NAN;
        zone = (hours * 3600 + minutes * 60) * (*end == '+' ? 1 : -1);
    } else return NAN;
    return (double)timegm(&date) + fraction - zone;
}

static bool continuity_parse(const char *text, TASContinuityPlaylist *result) {
    memset(result, 0, sizeof(*result));
    if (!text || strlen(text) >= TAS_MANIFEST_CAPACITY) return false;
    char *copy = strdup(text), *map = NULL, *pending = NULL;
    size_t length = 0, capacity = 0, tail_length = 0, tail_capacity = 0;
    double date = NAN, duration = NAN;
    uint64_t discontinuity = 0;
    bool ok = copy != NULL;
    char *save = NULL;
    for (char *line = ok ? strtok_r(copy, "\n", &save) : NULL; line && ok; line = strtok_r(NULL, "\n", &save)) {
        trim_manifest_line(line);
        if (starts_with(line, "#EXT-X-MEDIA-SEQUENCE:")) result->sequence = strtoull(line + 22, NULL, 10);
        else if (starts_with(line, "#EXT-X-DISCONTINUITY-SEQUENCE:")) discontinuity = strtoull(line + 30, NULL, 10);
        else if (starts_with(line, "#EXT-X-TARGETDURATION:")) result->target = (unsigned)strtoul(line + 22, NULL, 10);
        else if (starts_with(line, "#EXT-X-VERSION:")) result->version = (unsigned)strtoul(line + 15, NULL, 10);
        else if (starts_with(line, "#EXT-X-PROGRAM-DATE-TIME:")) {
            date = continuity_date(line + 25);
            append_text(&pending, &length, &capacity, line);
            append_text(&pending, &length, &capacity, "\n");
        } else if (starts_with(line, "#EXT-X-MAP:")) replace_owned_string(&map, line);
        else if (!strcmp(line, "#EXT-X-DISCONTINUITY")) {
            if (discontinuity == UINT64_MAX) ok = false;
            else discontinuity++;
        } else if (starts_with(line, "#EXTINF:")) {
            duration = strtod(line + 8, NULL);
            append_text(&pending, &length, &capacity, line);
            append_text(&pending, &length, &capacity, "\n");
        } else if (starts_with(line, "#EXT-X-TWITCH-PREFETCH:")) {
            append_text(&result->prefetch, &tail_length, &tail_capacity, line);
            append_text(&result->prefetch, &tail_length, &tail_capacity, "\n");
        } else if (starts_with(line, "#EXT-X-KEY:") && !contains(line, "METHOD=NONE")) ok = false;
        else if (starts_with(line, "#EXT-X-BYTERANGE:") || starts_with(line, "#EXT-X-PART") ||
                 starts_with(line, "#EXT-X-SKIP:") || !strcmp(line, "#EXT-X-ENDLIST")) ok = false;
        else if (line[0] && line[0] != '#') {
            if (!isfinite(date) || !isfinite(duration) || duration <= 0 || result->count == TAS_CONTINUITY_SEGMENTS) { ok = false; break; }
            append_text(&pending, &length, &capacity, line);
            append_text(&pending, &length, &capacity, "\n");
            TASContinuitySegment *segment = &result->segments[result->count++];
            *segment = (TASContinuitySegment){pending, map ? strdup(map) : NULL, date, duration, discontinuity};
            if (map && !segment->map) ok = false;
            pending = NULL; length = 0; capacity = 0;
            date += duration; duration = NAN;
        }
    }
    free(copy); free(map); free(pending);
    if (!ok || !result->count || !result->target || result->sequence > UINT64_MAX - result->count) {
        continuity_playlist_clear(result);
        return false;
    }
    return true;
}

static char *continuity_render(const TASContinuityPlaylist *playlist) {
    char header[256];
    snprintf(header, sizeof(header), "#EXTM3U\n#EXT-X-VERSION:%u\n#EXT-X-TARGETDURATION:%u\n"
             "#EXT-X-MEDIA-SEQUENCE:%llu\n#EXT-X-DISCONTINUITY-SEQUENCE:%llu\n",
             playlist->version < 6 ? 6 : playlist->version, playlist->target,
             (unsigned long long)playlist->sequence,
             (unsigned long long)playlist->segments[0].discontinuity);
    char *text = NULL;
    size_t length = 0, capacity = 0;
    append_text(&text, &length, &capacity, header);
    const char *map = NULL;
    uint64_t discontinuity = playlist->segments[0].discontinuity;
    for (size_t i = 0; i < playlist->count; i++) {
        const TASContinuitySegment *segment = &playlist->segments[i];
        while (discontinuity < segment->discontinuity) {
            append_text(&text, &length, &capacity, "#EXT-X-DISCONTINUITY\n");
            discontinuity++;
        }
        if (segment->map && (!map || strcmp(map, segment->map))) {
            append_text(&text, &length, &capacity, segment->map);
            append_text(&text, &length, &capacity, "\n");
            map = segment->map;
        }
        if (!contains(segment->body, "#EXT-X-PROGRAM-DATE-TIME:")) {
            time_t seconds = (time_t)floor(segment->date);
            unsigned fraction = (unsigned)((segment->date - floor(segment->date)) * 1000000 + 0.5);
            if (fraction == 1000000) { seconds++; fraction = 0; }
            struct tm utc;
            char date[48], tag[96];
            if (gmtime_r(&seconds, &utc) && strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &utc)) {
                snprintf(tag, sizeof(tag), "#EXT-X-PROGRAM-DATE-TIME:%s.%06uZ\n", date, fraction);
                append_text(&text, &length, &capacity, tag);
            }
        }
        append_text(&text, &length, &capacity, segment->body);
    }
    if (playlist->prefetch) append_text(&text, &length, &capacity, playlist->prefetch);
    return text;
}

static void continuity_drop_first(TASContinuityPlaylist *playlist) {
    free(playlist->segments[0].body); free(playlist->segments[0].map);
    memmove(playlist->segments, playlist->segments + 1, (--playlist->count) * sizeof(playlist->segments[0]));
    playlist->sequence++;
}

static char *continuity_update(TASContinuity *state, const char *text, uint64_t source) {
    TASContinuityPlaylist incoming;
    if (!continuity_parse(text, &incoming)) {
        tas_diag_log("HLS_CONTINUITY_UNSUPPORTED", "reason=unsupported_or_missing_timeline unchanged=yes");
        return strdup(text);
    }
    TASContinuityPlaylist *output = &state->output;
    if (!output->count || (!state->rewriting && state->source == source && incoming.sequence >= output->sequence)) {
        continuity_playlist_clear(output);
        *output = incoming;
        state->source = source;
        state->source_discontinuity = incoming.segments[incoming.count - 1].discontinuity;
        return strdup(text);
    }
    size_t first = incoming.count;
    TASContinuitySegment *last = &output->segments[output->count - 1];
    double end = last->date + last->duration;
    for (size_t i = 0; i < incoming.count; i++) {
        if (incoming.segments[i].date >= end - 0.001) { first = i; break; }
    }
    bool switched = state->source != source;
    uint64_t previous_disc = first < incoming.count ? incoming.segments[first].discontinuity : 0;
    uint64_t next_disc = last->discontinuity;
    if (switched && first < incoming.count && next_disc != UINT64_MAX) next_disc++;
    uint64_t boundary = !switched && first < incoming.count ?
        (previous_disc >= state->source_discontinuity ? previous_disc - state->source_discontinuity : 1) : 0;
    bool boundary_valid = boundary <= 128 && next_disc <= UINT64_MAX - boundary;
    if (boundary_valid) next_disc += boundary;
    uint64_t checked_disc = next_disc, checked_previous = previous_disc;
    bool valid = boundary_valid && !(switched && first < incoming.count && last->discontinuity == UINT64_MAX);
    for (size_t i = first; valid && i < incoming.count; i++) {
        TASContinuitySegment *segment = &incoming.segments[i];
        valid = round(segment->duration) <= output->target && segment->discontinuity >= checked_previous &&
                segment->discontinuity - checked_previous <= 128 &&
                checked_disc <= UINT64_MAX - (segment->discontinuity - checked_previous);
        if (valid) checked_disc += segment->discontinuity - checked_previous;
        checked_previous = segment->discontinuity;
    }
    if (!valid || output->sequence > UINT64_MAX - output->count - (incoming.count - first)) {
        tas_diag_log("HLS_CONTINUITY_REJECTED", "reason=incompatible_duration_or_counter unchanged_previous_window=yes");
        continuity_playlist_clear(&incoming);
        return continuity_render(output);
    }
    double wanted = 3.0 * output->target, total = 0, window = 0;
    for (size_t i = 0; i < incoming.count; i++) window += incoming.segments[i].duration;
    if (window > wanted) wanted = window;
    for (size_t i = 0; i < output->count; i++) total += output->segments[i].duration;
    for (size_t i = first; i < incoming.count; i++) {
        TASContinuitySegment *segment = &incoming.segments[i];
        next_disc += segment->discontinuity - previous_disc;
        previous_disc = segment->discontinuity;
        if (output->count == TAS_CONTINUITY_SEGMENTS) {
            total -= output->segments[0].duration;
            continuity_drop_first(output);
        }
        segment->discontinuity = next_disc;
        output->segments[output->count++] = *segment;
        total += segment->duration;
        memset(segment, 0, sizeof(*segment));
    }
    while (output->count > 1 && total - output->segments[0].duration >= wanted) {
        total -= output->segments[0].duration;
        continuity_drop_first(output);
    }
    if (first < incoming.count && incoming.segments[first].body == NULL) {
        state->source = source;
        state->source_discontinuity = previous_disc;
    }
    state->rewriting = true;
    if (incoming.version > output->version) output->version = incoming.version;
    replace_owned_string(&output->prefetch, first < incoming.count ? incoming.prefetch : NULL);
    char *result = continuity_render(output);
    char detail[256];
    snprintf(detail, sizeof(detail), "source=%016llx input_seq=%llu output_seq=%llu segments=%zu switch=%d pending=%d",
             (unsigned long long)source, (unsigned long long)incoming.sequence,
             (unsigned long long)output->sequence, output->count, switched, first == incoming.count);
    tas_diag_log("HLS_CONTINUITY", detail);
    continuity_playlist_clear(&incoming);
    return result;
}

static char *continuous_manifest(TASStreamRef ref, const char *route_url, const char *source_url, const char *text, bool custom_scheme) {
    char *result = NULL;
    pthread_mutex_lock(&g_lock);
    if (stream_ref_matches_locked(ref)) {
        for (size_t i = 0; i < TAS_MAX_VARIANT_ROUTES; i++) {
            TASVariantRoute *route = &g_variant_routes[i];
            if (route->generation != ref.generation || strcmp(route->url, route_url)) continue;
            TASContinuity **state = &route->continuity[custom_scheme ? 1 : 0];
            if (!*state) *state = calloc(1, sizeof(**state));
            if (*state) result = continuity_update(*state, text, tas_playback_url_id(source_url));
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return result ?: strdup(text);
}

static char *process_manifest(const char *url, const char *playlist, bool custom_scheme) {
    char channel[512];
    channel_from_master_url(url, channel, sizeof(channel));
    if (channel[0]) {
        TASManifestStats stats = manifest_stats(playlist);
        char detail[768];
        format_manifest_stats(detail, sizeof(detail), &stats, strlen(playlist), true);
        tas_diag_metric(TAS_DIAG_MASTER_MANIFEST, 1);
        tas_diag_log_url("MASTER_MANIFEST", url, detail);
        pthread_mutex_lock(&g_lock);
        TASStreamRef stream_ref = update_stream_master_locked(channel, url, playlist);
        register_variant_routes_locked(stream_ref, url, playlist);
        pthread_mutex_unlock(&g_lock);
        return rewrite_manifest_urls(playlist, url, custom_scheme);
    }

    char resolution[128] = "";
    char framerate[64] = "";
    TASStreamSnapshot stream;
    if (!snapshot_stream_for_variant(url, &stream)) {
        TASManifestStats stats = manifest_stats(playlist);
        char detail[768];
        format_manifest_stats(detail, sizeof(detail), &stats, strlen(playlist), false);
        tas_diag_metric(TAS_DIAG_VARIANT_MANIFEST, 1);
        tas_diag_metric(TAS_DIAG_UNMAPPED_VARIANT, 1);
        if (has_ad_markers(playlist)) tas_diag_metric(TAS_DIAG_AD_MANIFEST, 1);
        tas_diag_log_url("VARIANT_UNMAPPED", url, detail);
        return rewrite_manifest_urls(playlist, url, custom_scheme);
    }
    TASManifestStats stats = manifest_stats(playlist);
    char manifest_detail[768];
    format_manifest_stats(manifest_detail, sizeof(manifest_detail), &stats, strlen(playlist), true);
    tas_diag_metric(TAS_DIAG_VARIANT_MANIFEST, 1);
    if (has_ad_markers(playlist)) tas_diag_metric(TAS_DIAG_AD_MANIFEST, 1);
    tas_diag_log_url(has_ad_markers(playlist) ? "VARIANT_AD_MARKED" : "VARIANT_MANIFEST",
                     url, manifest_detail);
    bool original_audio_only = false;
    variant_metadata(stream.master_manifest, stream.master_url, url,
                     resolution, sizeof(resolution), framerate, sizeof(framerate), &original_audio_only);

    char *selected = NULL;
    char *selected_base = NULL;
    bool filtered = false;
    if (has_ad_markers(playlist)) {
        if (stream.backup_variant_url[0] && time(NULL) - stream.backup_created < 600) {
            id backup_data = nil;
            id backup_response = nil;
            if (fetch_bytes(stream.backup_variant_url, &backup_data, &backup_response)) {
                char *candidate = copy_data_text(backup_data);
                if (candidate && !has_ad_markers(candidate)) {
                    selected = candidate;
                    selected_base = strdup(stream.backup_variant_url);
                } else {
                    free(candidate);
                    clear_active_backup(stream.ref);
                }
            }
        }
        if (!selected && stream.master_url[0] && stream.channel[0]) {
            selected = fetch_vaft_variant(stream.master_url, stream.channel, resolution, framerate,
                                          stream.ref, !original_audio_only, &selected_base);
        }
        if (!selected) {
            selected = strdup(playlist);
            selected_base = strdup(url);
            fprintf(stderr, "[TAS] VAFT alternates unavailable; suppressing stitched segments\n");
            tas_diag_log_url("VAFT_ALTERNATES_UNAVAILABLE", url,
                             "action=use_original_and_suppress_known_ad_segments");
        }
        if (has_ad_markers(selected)) {
            char *stripped = strip_ad_segments(selected, selected_base);
            free(selected);
            selected = stripped;
            filtered = true;
        }
    } else {
        clear_active_backup(stream.ref);
        selected = strdup(playlist);
        selected_base = strdup(url);
    }
    char *rewritten = rewrite_manifest_urls(selected, selected_base, custom_scheme);
    char *continuous = continuous_manifest(stream.ref, url, selected_base, rewritten, custom_scheme);
    free(rewritten);
    rewritten = continuous;
    trace_playback_output(stream.ref, stream.master_url, url, playlist,
                          selected_base, rewritten, filtered);
    free(selected);
    free(selected_base);
    free(stream.master_manifest);
    return rewritten;
}

static BOOL loader_handle(id self, SEL command, id loading_request) {
    (void)self;
    (void)command;
    id request = msg0(loading_request, "request");
    id original_url = msg0(request, "URL");
    const char *custom_url = utf8(msg0(original_url, "absoluteString"));
    if (!custom_url) return NO;
    char *url = https_scheme_url(custom_url);
    if (is_twitch_hls_url(url)) {
        tas_diag_metric(TAS_DIAG_HLS_INTERCEPTED, 1);
        tas_diag_log_url("HLS_REQUEST", url, "transport=AVAssetResourceLoader");
    }
    id network_request = msg0(request, "mutableCopy");
    vmsg1(network_request, "setURL:", nsurl(url));
    vmsg2(network_request, "setValue:forHTTPHeaderField:", nsstr("1"), nsstr(TAS_INTERNAL_HEADER));

    id response = nil;
    id error = nil;
    bool is_synthetic = is_cached_ad_segment(url);
    id data = nil;
    if (is_synthetic) {
        tas_diag_metric(TAS_DIAG_SYNTHETIC_SEGMENT, 1);
        tas_diag_log_url("SYNTHETIC_SEGMENT", url, "transport=AVAssetResourceLoader");
        data = blank_video_data();
        response = http_response(url, 200, "video/mp4", data_length(data), nil);
    } else {
        data = synchronous_request(network_request, &response, &error);
    }
    if (error || !data || !response) {
        tas_diag_metric(TAS_DIAG_HLS_FAILURE, 1);
        char detail[192];
        snprintf(detail, sizeof(detail), "transport=AVAssetResourceLoader status=%ld data=%s error=%s",
                 response ? (long)imsg0(response, "statusCode") : 0L,
                 data ? "yes" : "no", error ? "yes" : "no");
        tas_diag_log_url("HLS_FAILURE", url, detail);
        vmsg1(loading_request, "finishLoadingWithError:", error);
        objc_release(network_request);
        free(url);
        return YES;
    }

    const char *mime = utf8(msg0(response, "MIMEType"));
    if (is_twitch_hls_url(url)) {
        char detail[224];
        snprintf(detail, sizeof(detail), "transport=AVAssetResourceLoader status=%ld bytes=%zu",
                 (long)imsg0(response, "statusCode"), data_length(data));
        tas_diag_log_url("HLS_RESPONSE", url, detail);
        if (imsg0(response, "statusCode") < 200 || imsg0(response, "statusCode") >= 300) {
            tas_diag_metric(TAS_DIAG_HLS_FAILURE, 1);
        }
    }
    char *text = NULL;
    id output_data = data;
    if (contains(url, ".m3u8") || (mime && contains(mime, "mpegurl"))) {
        text = copy_data_text(data);
        if (text && starts_with(text, "#EXTM3U")) {
            char *processed = process_manifest(url, text, true);
            output_data = data_from_bytes(processed, strlen(processed));
            free(processed);
        }
        free(text);
    }

    id content = msg0(loading_request, "contentInformationRequest");
    if (content) {
        const char *type = contains(url, ".m3u8") ? "public.m3u-playlist" :
                           (contains(url, ".ts") ? "public.mpeg-2-transport-stream" : "public.mpeg-4");
        vmsg1(content, "setContentType:", nsstr(type));
        ((void (*)(id, SEL, long long))objc_msgSend)(content, sel_registerName("setContentLength:"), (long long)data_length(output_data));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(content, sel_registerName("setByteRangeAccessSupported:"), YES);
    }
    id data_request = msg0(loading_request, "dataRequest");
    if (data_request) vmsg1(data_request, "respondWithData:", output_data);
    msg0(loading_request, "finishLoading");
    if (is_synthetic) objc_release(response);
    objc_release(network_request);
    free(url);
    return YES;
}

static BOOL loader_wait(id self, SEL command, id resource_loader, id loading_request) {
    (void)resource_loader;
    return loader_handle(self, command, loading_request);
}

static id asset_init(id self, SEL command, id url, id options) {
    const char *absolute = utf8(msg0(url, "absoluteString"));
    if (!absolute || !starts_with(absolute, "https://") || !contains(absolute, ".m3u8") ||
        !(contains(absolute, "ttvnw.net") || contains(absolute, "twitch.tv"))) {
        return ((id (*)(id, SEL, id, id))g_original_asset_init)(self, command, url, options);
    }
    if (!TPKAdblockEnabledFast()) {
        return ((id (*)(id, SEL, id, id))g_original_asset_init)(self, command, url, options);
    }
    tas_diag_log_url("ASSET_INTERCEPT", absolute, "transport=AVURLAsset");
    char *custom = custom_scheme_url(absolute);
    id asset = ((id (*)(id, SEL, id, id))g_original_asset_init)(self, command, nsurl(custom), options);
    free(custom);
    if (!asset) return asset;
    id delegate = msg0((id)g_loader_class, "new");
    id loader = msg0(asset, "resourceLoader");
    dispatch_queue_t queue = dispatch_queue_create("dev.tas.hls-loader", DISPATCH_QUEUE_SERIAL);
    ((void (*)(id, SEL, id, dispatch_queue_t))objc_msgSend)(
        loader, sel_registerName("setDelegate:queue:"), delegate, queue);
    objc_setAssociatedObject(asset, &g_association_key, delegate, 1);
    objc_release(delegate);
    return asset;
}

static void add_protocol_to_configuration(id configuration) {
    if (!configuration || !g_protocol_class) return;
    id classes = msg0(configuration, "protocolClasses");
    id mutable = classes ? msg0(classes, "mutableCopy") : msg0((id)objc_getClass("NSMutableArray"), "array");
    if (!bmsg1(mutable, "containsObject:", (id)g_protocol_class)) {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
            mutable, sel_registerName("insertObject:atIndex:"), (id)g_protocol_class, 0);
    }
    vmsg1(configuration, "setProtocolClasses:", mutable);
    if (classes) objc_release(mutable);
}

static id default_configuration(id self, SEL command) {
    id result = ((id (*)(id, SEL))g_original_default_configuration)(self, command);
    add_protocol_to_configuration(result);
    return result;
}

static id ephemeral_configuration(id self, SEL command) {
    id result = ((id (*)(id, SEL))g_original_ephemeral_configuration)(self, command);
    add_protocol_to_configuration(result);
    return result;
}

static id session_with_configuration(id self, SEL command, id configuration) {
    add_protocol_to_configuration(configuration);
    return ((id (*)(id, SEL, id))g_original_session_with_configuration)(self, command, configuration);
}

static id session_with_configuration_delegate_queue(id self, SEL command, id configuration,
                                                     id delegate, id queue) {
    add_protocol_to_configuration(configuration);
    tas_diag_observe_delegate(delegate);
    return ((id (*)(id, SEL, id, id, id))g_original_session_with_configuration_delegate_queue)(
        self, command, configuration, delegate, queue);
}

static id data_task_with_request(id self, SEL command, id original) {
    id replacement = normalized_graphql_request_copy(original);
    id task = ((id (*)(id, SEL, id))g_original_data_task_request)(
        self, command, replacement ?: original);
    tas_diag_observe_task(task);
    if (replacement) objc_release(replacement);
    return task;
}

static id data_task_with_request_completion(id self, SEL command, id original, id completion) {
    id replacement = normalized_graphql_request_copy(original);
    id task = ((id (*)(id, SEL, id, id))g_original_data_task_request_completion)(
        self, command, replacement ?: original, tas_diag_segment_completion(original, completion));
    tas_diag_observe_task(task);
    if (replacement) objc_release(replacement);
    return task;
}

static void swizzle_method(Class cls, const char *selector, IMP replacement, IMP *original, bool class_method) {
    Method method = class_method ? class_getClassMethod(cls, sel_registerName(selector)) :
                                   class_getInstanceMethod(cls, sel_registerName(selector));
    if (!method) return;
    if (original) *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

void vaft_initialize(void) {
    Class url_protocol = objc_getClass("NSURLProtocol");
    g_protocol_class = objc_allocateClassPair(url_protocol, "TASURLProtocol", 0);
    if (g_protocol_class) {
        class_addMethod(object_getClass((id)g_protocol_class), sel_registerName("canInitWithRequest:"), (IMP)protocol_can_init, "B@:@");
        class_addMethod(object_getClass((id)g_protocol_class), sel_registerName("canonicalRequestForRequest:"), (IMP)protocol_canonical_request, "@@:@");
        class_addMethod(g_protocol_class, sel_registerName("startLoading"), (IMP)protocol_start_loading, "v@:");
        class_addMethod(g_protocol_class, sel_registerName("stopLoading"), (IMP)protocol_stop_loading, "v@:");
        objc_registerClassPair(g_protocol_class);
        ((BOOL (*)(id, SEL, Class))objc_msgSend)((id)url_protocol, sel_registerName("registerClass:"), g_protocol_class);
    }

    g_loader_class = objc_allocateClassPair(objc_getClass("NSObject"), "TASAssetResourceLoaderDelegate", 0);
    if (g_loader_class) {
        class_addMethod(g_loader_class, sel_registerName("resourceLoader:shouldWaitForLoadingOfRequestedResource:"),
                        (IMP)loader_wait, "B@:@@");
        class_addMethod(g_loader_class, sel_registerName("resourceLoader:shouldWaitForRenewalOfRequestedResource:"),
                        (IMP)loader_wait, "B@:@@");
        objc_registerClassPair(g_loader_class);
    }

    Class asset = objc_getClass("AVURLAsset");
    swizzle_method(asset, "initWithURL:options:", (IMP)asset_init, &g_original_asset_init, false);

    Class configuration = objc_getClass("NSURLSessionConfiguration");
    swizzle_method(configuration, "defaultSessionConfiguration", (IMP)default_configuration,
                   &g_original_default_configuration, true);
    swizzle_method(configuration, "ephemeralSessionConfiguration", (IMP)ephemeral_configuration,
                   &g_original_ephemeral_configuration, true);

    Class session = objc_getClass("NSURLSession");
    swizzle_method(session, "sessionWithConfiguration:", (IMP)session_with_configuration,
                   &g_original_session_with_configuration, true);
    swizzle_method(session, "sessionWithConfiguration:delegate:delegateQueue:",
                   (IMP)session_with_configuration_delegate_queue,
                   &g_original_session_with_configuration_delegate_queue, true);
    swizzle_method(session, "dataTaskWithRequest:", (IMP)data_task_with_request,
                   &g_original_data_task_request, false);
    swizzle_method(session, "dataTaskWithRequest:completionHandler:",
                   (IMP)data_task_with_request_completion,
                   &g_original_data_task_request_completion, false);
    tas_diagnostics_initialize();
    fprintf(stderr, "[TAS] TwitchAdSolutions VAFT v24 iOS port loaded\n");
}
