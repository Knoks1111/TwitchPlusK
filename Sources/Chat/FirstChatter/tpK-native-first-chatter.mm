#import "Chat/FirstChatter/tpK-native-first-chatter.h"
#import "Chat/Appearance/tpK-chat-event-appearance.h"
#import "Settings/tpK-chat-appearance-config.h"
#import <UIKit/UIKit.h>
#import "Localization/tpK-localization-manager.h"
#define JSI_EXPORT __attribute__((visibility("hidden")))
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;

class TPKFirstChatterBuffer final : public jsi::Buffer {
    std::string text;
public:
    explicit TPKFirstChatterBuffer(const char *value) : text(value) {}
    size_t size() const override { return text.size(); }
    const uint8_t *data() const override { return (const uint8_t *)text.data(); }
};

// Called only by the runtime adapter admitted for the exact Twitch 32.0 bundle.
static const char *firstChatterAdapter = R"TPKFIRST(
(function () {
  if (globalThis.__TPKNativeFirstChatter) return true;
  const module = __r(4710), reactModule = __r(72), React = reactModule.default || reactModule, RN = __r(5);
  const original = module.ChatLine;
  if (!original || typeof React.createElement !== 'function') return false;
  const listeners = new Set();
  let config = JSON.parse(__TPKFirstChatterSettings());
  function FirstMessage(props) {
    const [, refresh] = React.useReducer(value => value + 1, 0);
    React.useEffect(() => { listeners.add(refresh); return () => listeners.delete(refresh); }, []);
    const line = React.createElement(original, props), event = props.line;
    const settings = config;
    if (!settings.enabled || event.hidden) return line;
    const header = props.moderation && event.type === 'firstchatter' ? null : React.createElement(RN.Text,
      {style: {color: settings.color, fontSize: 9, lineHeight: 10, textAlign: 'right', alignSelf: 'stretch',
               paddingHorizontal: 6}}, settings.label);
    // Compenser une partie du padding natif sous notre bandeau.
    const body = header ? React.createElement(RN.View, {style: {marginTop: -4}}, line) : line;
    return React.createElement(RN.View, {testID: 'tpk-firstchatter-line', style: {
      borderLeftWidth: 2, borderLeftColor: settings.color, backgroundColor: settings.background
    }}, header, body);
  }
  module.ChatLine = function (props) {
    const event = props.line;
    const first = event && typeof event.id === 'string' && event.id.length && !event.hidden &&
      (event.isFirstMessage === true || event.type === 'firstchatter');
    return React.createElement(first ? FirstMessage : original, props);
  };
  Object.defineProperty(globalThis, '__TPKNativeFirstChatter', {value: {
    refresh() {
      const next = JSON.parse(__TPKFirstChatterSettings());
      if (['enabled', 'color', 'background', 'label'].every(key => next[key] === config[key])) return true;
      config = next;
      listeners.forEach(refresh => refresh()); return true;
    }
  }});
  return true;
})()
)TPKFIRST";

bool TPKNativeFirstChatterInstall(jsi::Runtime &runtime) {
    try {
        auto settings = jsi::Function::createFromHostFunction(runtime,
            jsi::PropNameID::forAscii(runtime, "__TPKFirstChatterSettings"), 0,
            [](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *, size_t) -> jsi::Value {
                @autoreleasepool {
                    TPKChatAppearanceConfig *config = TPKChatAppearanceConfig.sharedConfig;
                    CGFloat red = 0, green = 0, blue = 0, alpha = 1;
                    UIColor *color = [config.firstMessageHighlightColor resolvedColorWithTraitCollection:
                        [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
                    [color getRed:&red green:&green blue:&blue alpha:&alpha];
                    NSString *accent = [NSString stringWithFormat:@"rgba(%d,%d,%d,%.3f)",
                        (int)lround(red * 255), (int)lround(green * 255), (int)lround(blue * 255), (double)alpha];
                    NSString *background = [NSString stringWithFormat:@"rgba(%d,%d,%d,%.3f)",
                        (int)lround(red * 255), (int)lround(green * 255), (int)lround(blue * 255), (double)(alpha * TPKChatHighlightBackgroundOpacity)];
                    NSDictionary *value = @{@"enabled": @(config.showFirstMessageBadge),
                        @"color": accent, @"background": background, @"label": L(@"first_message_badge_label")};
                    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                    return jsi::Value(jsi::String::createFromUtf8(rt, (const uint8_t *)json.bytes, json.length));
                }
            });
        runtime.global().setProperty(runtime, "__TPKFirstChatterSettings", std::move(settings));
        auto result = runtime.evaluateJavaScript(std::make_shared<TPKFirstChatterBuffer>(firstChatterAdapter),
                                                 "twitchplusk-native-first-chatter.js");
        return result.isBool() && result.getBool();
    } catch (...) { return false; }
}
