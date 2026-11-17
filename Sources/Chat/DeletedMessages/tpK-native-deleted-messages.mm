#import "Chat/DeletedMessages/tpK-native-deleted-messages.h"
#import "Core/tpK-core-manager.h"
#import "Settings/tpK-chat-appearance-config.h"

#import "Localization/tpK-localization-manager.h"
#define JSI_EXPORT __attribute__((visibility("hidden")))
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;
class TPKDeletedBuffer final : public jsi::Buffer {
    std::string text;
public:
    explicit TPKDeletedBuffer(const char *value) : text(value) {}
    size_t size() const override { return text.size(); }
    const uint8_t *data() const override { return (const uint8_t *)text.data(); }
};

// Exact Twitch 32.0 bundle admission is enforced by the shared chat runtime.
static const char *deletedAdapter = R"TPKDELETED(
(function () {
  if (globalThis.__TPKNativeDeleted) return true;
  const reactModule = __r(72), React = reactModule.default || reactModule, RN = __r(5);
  const stores = __r(3486), Client = __r(3488).LibraryTmiClient;
  const rows = __r(4710), bodies = __r(3667);
  if (!Client || typeof Client.prototype.onModeration !== 'function' ||
      typeof Client.prototype.onLine !== 'function' || typeof stores.useChatSelector !== 'function' ||
      !rows.ChatLine || !bodies.MessageBody) return false;
  let clients = new WeakMap(), fallback = new WeakMap();
  const bindings = new WeakMap(), stampKey = Symbol('tpkModeration');
  const settingsCache = new Map(), listeners = new Set();
  const MessageStyle = React.createContext(null);
  const settings = duration => {
    duration = duration || 0;
    if (!settingsCache.has(duration)) {
      settingsCache.set(duration, JSON.parse(__TPKDeletedSettings(duration)));
      if (settingsCache.size > 64) settingsCache.delete(settingsCache.keys().next().value);
    }
    return settingsCache.get(duration);
  };
  let enabled = settings().enabled && settings().mode !== 0;
  const channel = value => typeof value === 'string' ? value.replace(/^#/, '').toLowerCase() : '';
  const supported = line => line && ['chat', 'firstchatter', 'channelpointsreward'].includes(line.type) &&
                             typeof line.id === 'string' && line.id && typeof line.body === 'string';
  function owner(client) {
    let record = clients.get(client);
    if (!record) {
      record = {epoch: {}, tail: {}, store: bindings.get(client) || null, bound: false, channel: '', listeners: new Set()};
      clients.set(client, record);
    }
    return record;
  }
  function stamp(record, line) {
    if (!supported(line)) return null;
    let value = line[stampKey];
    if (!value || value.epoch !== record.epoch) value = fallback.get(line);
    if (!value || value.epoch !== record.epoch) {
      value = {epoch: record.epoch, cursor: record.tail, moderation: null, expanded: false};
      // Enumerable symbols survive Twitch's reply-model copies but never enter JSON or IRC.
      try { Object.defineProperty(line, stampKey, {value, enumerable: true, configurable: true}); }
      catch (_) { fallback.set(line, value); }
    }
    return value;
  }
  function resolve(record, line) {
    const value = stamp(record, line);
    if (!value) return null;
    while (value.cursor.event) {
      const event = value.cursor.event;
      if (channel(line.channel) === event.channel && (event.kind === 'clear' ||
          (event.kind === 'delete' ? line.id === event.id :
           typeof line.user === 'string' && line.user.toLowerCase() === event.user)))
        value.moderation = event;
      value.cursor = value.cursor.next;
    }
    return value.moderation ? value : null;
  }
  function nativeLines(record, visit) {
    const state = record.store.getState();
    for (const list of [state.lines, state.pausedWindow]) if (Array.isArray(list))
      for (const item of list) {
        const line = item.line || item;
        if (supported(line)) visit(line);
      }
  }
  function attach(store) {
    if (!enabled || !store || typeof store.getState !== 'function') return null;
    const state = store.getState(), client = state._tmiClient;
    if (!client || typeof client !== 'object') return null;
    bindings.set(client, store);
    const record = owner(client);
    if (record.store !== store || !record.bound) {
      record.store = store;
      record.bound = true;
      nativeLines(record, line => stamp(record, line));
      __TPKDeletedTrace(1);
    }
    return record;
  }
  for (const name of ['disconnect', 'dispose']) {
    const original = Client.prototype[name];
    if (typeof original !== 'function') continue;
    Client.prototype[name] = function () {
      const record = clients.get(this);
      clients.delete(this);
      bindings.delete(this);
      if (record) {
        record.epoch = {}; record.tail = {}; record.store = null;
        for (const entry of [...record.listeners]) entry.refresh();
      }
      return original.apply(this, arguments);
    };
  }
  const useSelector = stores.useChatSelector;
  stores.useChatSelector = function (store) {
    attach(store);
    return useSelector.apply(this, arguments);
  };
  const onLine = Client.prototype.onLine, onModeration = Client.prototype.onModeration;
  Client.prototype.onLine = function (callback) {
    const client = this;
    return onLine.call(this, function (line) {
      if (!enabled) return callback.apply(this, arguments);
      stamp(owner(client), line);
      return callback.apply(this, arguments);
    });
  };
  Client.prototype.onModeration = function (callback) {
    const client = this;
    return onModeration.call(this, function (event) {
      if (!enabled) return callback.apply(this, arguments);
      const record = clients.get(client);
      if (!record || !record.store || !event ||
          !['delete', 'clear', 'ban', 'timeout'].includes(event.kind)) return callback.apply(this, arguments);
      const target = channel(event.channel);
      if (!target || (record.channel && record.channel !== target)) return callback.apply(this, arguments);
      if (event.kind === 'delete' && (typeof event.targetMsgId !== 'string' || !event.targetMsgId)) return callback.apply(this, arguments);
      if (['ban', 'timeout'].includes(event.kind) && (typeof event.userLogin !== 'string' || !event.userLogin)) return callback.apply(this, arguments);
      record.channel = target;
      const state = record.store.getState();
      if (state._tmiClient !== client) return callback.apply(this, arguments);
      nativeLines(record, line => stamp(record, line));
      // Only native messages keep earlier nodes alive; the client retains the empty tail.
      record.tail.event = {kind: event.kind, channel: target, id: event.targetMsgId,
        user: typeof event.userLogin === 'string' ? event.userLogin.toLowerCase() : '',
        duration: Number.isSafeInteger(event.durationSeconds) && event.durationSeconds > 0 ? event.durationSeconds : 0};
      record.tail.next = {};
      record.tail = record.tail.next;
      for (const entry of record.listeners) {
        const previous = stamp(record, entry.line).moderation;
        const value = resolve(record, entry.line);
        if (value && value.moderation !== previous) entry.refresh();
      }
      __TPKDeletedTrace();
    });
  };
  const originalBody = bodies.MessageBody;
  bodies.MessageBody = function (props) {
    const style = React.useContext(MessageStyle);
    if (!enabled) return originalBody(props);
    const body = originalBody(style && style.strike ? {...props, strikethrough: true} : props);
    if (!style || style.opacity === 1 || !React.isValidElement(body)) return body;
    return React.cloneElement(body, {style: [body.props.style, {opacity: style.opacity}]});
  };
  const originalRow = rows.ChatLine;
  rows.ChatLine = function (props) {
    const owner = attach(props.chatStore), line = props.line;
    const [, refresh] = React.useReducer(value => value + 1, 0);
    React.useEffect(() => {
      if (!owner || !supported(line)) return;
      const entry = {line, refresh};
      owner.listeners.add(entry); listeners.add(entry);
      return () => { owner.listeners.delete(entry); listeners.delete(entry); };
    }, [owner, line]);
    const record = owner ? resolve(owner, line) : null;
    if (!record || line.hidden) return React.createElement(originalRow, props);
    const config = settings(record.moderation.duration);
    if (!config.enabled) return React.createElement(originalRow, props);
    const expanded = config.mode === 2 || (config.mode === 1 && record.expanded);
    const toggle = () => { record.expanded = !record.expanded; __TPKDeletedTrace(2); refresh(); };
    const detail = record.moderation.kind === 'timeout' ? config.timeout : record.moderation.kind === 'ban' ? config.ban : config.label;
    const collapsedLine = {...line, body: detail, emotes: [], gif: undefined, reply: undefined,
                           gigantifiedEmote: false, bits: 0, deleted: false};
    const displayedLine = expanded ? {...line, deleted: false} : collapsedLine;
    const content = React.createElement(MessageStyle.Provider, {value: {
      strike: expanded && config.style !== 0, opacity: expanded && config.style === 1 ? 1 : config.opacity
    }}, React.createElement(originalRow, {...props, line: displayedLine}));
    return React.createElement(RN.View, {testID: 'tpk-deleted-message', style: {paddingVertical: 2}},
      config.mode === 1 ? React.createElement(RN.Pressable,
        {onPress: toggle, accessibilityRole: 'button'}, content) : content);
  };
  const selectorAdapter = stores.useChatSelector, bodyAdapter = bodies.MessageBody, rowAdapter = rows.ChatLine;
  function applyViews() {
    stores.useChatSelector = enabled ? selectorAdapter : useSelector;
    bodies.MessageBody = enabled ? bodyAdapter : originalBody;
    rows.ChatLine = enabled ? rowAdapter : originalRow;
  }
  applyViews();
  Object.defineProperty(globalThis, '__TPKNativeDeleted', {value: {
    refresh() {
      settingsCache.clear();
      enabled = settings().enabled && settings().mode !== 0;
      if (!enabled) { clients = new WeakMap(); fallback = new WeakMap(); }
      applyViews();
      for (const entry of [...listeners]) entry.refresh();
      return true;
    }
  }});
  return true;
})()
)TPKDELETED";

bool TPKNativeDeletedMessagesInstall(jsi::Runtime &runtime) {
    try {
        auto settings = jsi::Function::createFromHostFunction(runtime,
            jsi::PropNameID::forAscii(runtime, "__TPKDeletedSettings"), 1,
            [](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                @autoreleasepool {
                    TPKChatAppearanceConfig *config = TPKChatAppearanceConfig.sharedConfig;
                    double seconds = count && args[0].isNumber() ? args[0].getNumber() : 0;
                    NSString *duration = TPKChatModerationDurationText(
                        isfinite(seconds) && seconds > 0 && seconds <= 9007199254740991.0 ? (NSInteger)seconds : 0);
                    NSString *timeout = duration.length ? [NSString stringWithFormat:
                        L(@"chat_moderation_timeout_format"), duration] : L(@"chat_moderation_timeout");
                    NSString *label = L(@"chat_deleted_message_placeholder");
                    if ([label hasPrefix:@"– "]) label = [label substringFromIndex:2];
                    NSDictionary *value = @{@"enabled": @(config.deletedMessageRevealMode != 0),
                        @"mode": @(config.deletedMessageRevealMode), @"style": @(config.deletedMessageStyle),
                        @"opacity": @(MAX(0.25, MIN(1.0, config.deletedMessageTextOpacity))),
                        @"label": label, @"timeout": timeout, @"ban": L(@"chat_moderation_permanent_ban")};
                    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                    return jsi::Value(jsi::String::createFromUtf8(rt, (const uint8_t *)json.bytes, json.length));
                }
            });
        runtime.global().setProperty(runtime, "__TPKDeletedSettings", std::move(settings));
        auto trace = jsi::Function::createFromHostFunction(runtime,
            jsi::PropNameID::forAscii(runtime, "__TPKDeletedTrace"), 1,
            [](jsi::Runtime &, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                TPKManager *manager = TPKManager.sharedManager;
                if (manager.logsEnabled && manager.logChat) {
                    double stage = count && args[0].isNumber() ? args[0].getNumber() : 0;
                    NSString *message = stage == 1 ? @"native store bound (metadata only)" : stage == 2 ?
                        @"reveal tap received" : @"moderation retained in native chat";
                    [manager log:@"[Chat] 🧪 Deleted messages: %@", message];
                }
                return jsi::Value::undefined();
            });
        runtime.global().setProperty(runtime, "__TPKDeletedTrace", std::move(trace));
        auto result = runtime.evaluateJavaScript(std::make_shared<TPKDeletedBuffer>(deletedAdapter),
                                                 "twitchplusk-native-deleted.js");
        return result.isBool() && result.getBool();
    } catch (...) { return false; }
}
