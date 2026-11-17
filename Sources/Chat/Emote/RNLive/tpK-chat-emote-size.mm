#import "Chat/Emote/tpK-chat-emotes.h"
#import "Chat/tpK-chat-runtime.h"
#define JSI_EXPORT __attribute__((visibility("hidden")))
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;

class TPKEmoteSizeBuffer final : public jsi::Buffer {
    std::string text;
public:
    explicit TPKEmoteSizeBuffer(const char *value) : text(value) {}
    size_t size() const override { return text.size(); }
    const uint8_t *data() const override { return (const uint8_t *)text.data(); }
};

// Exact-bundle admission is owned by the shared chat runtime.
static const char *sizeAdapter = R"TPKSIZE(
(function () {
  if (globalThis.__TPKEmoteSize) return true;
  const emotes = __r(3461), reactModule = __r(72), React = reactModule.default || reactModule;
  const original = emotes.EmotePart;
  if (typeof original !== 'function' || typeof React.cloneElement !== 'function') return false;
  const listeners = new Set(), dimensions = new Map();
  let height = __TPKEmoteHeight();
  function sized(props) {
    const [, refresh] = React.useReducer(value => value + 1, 0);
    React.useEffect(() => { listeners.add(refresh); return () => listeners.delete(refresh); }, []);
    const tree = original(props);
    const match = /^tpk_r(\d{3,4})_/.exec(props.emoteId);
    const ratio = match && +match[1] >= 125 && +match[1] <= 5000 ? +match[1] / 1000 : 1;
    if (props.gigantified || (height === 24 && ratio === 1)) return tree;
    let box = dimensions.get(ratio);
    if (!box) {
      box = Object.freeze({width: height * ratio, height});
      if (dimensions.size >= 256) dimensions.clear();
      dimensions.set(ratio, box);
    }
    const wrapperID = 'chat-emote-wrapper-' + props.emoteId, imageID = 'chat-emote-' + props.emoteId;
    function resize(node, depth) {
      if (!React.isValidElement(node)) return node;
      if (node.props.testID === wrapperID) {
        const image = node.props.children;
        if (!React.isValidElement(image) || image.props.testID !== imageID) return node;
        return React.cloneElement(node, {style: [node.props.style, box], children:
          React.cloneElement(image, {style: [image.props.style, box]})});
      }
      if (!depth || !React.isValidElement(node.props.children)) return node;
      const child = resize(node.props.children, depth - 1);
      return child === node.props.children ? node : React.cloneElement(node, {children: child});
    }
    return resize(tree, 1);
  }
  emotes.EmotePart = function (props) {
    return React.createElement(typeof props.emoteId === 'string' && props.emoteId.startsWith('tpk_')
      ? sized : original, props);
  };
  Object.defineProperty(globalThis, '__TPKEmoteSize', {value: {
    refresh() {
      const next = __TPKEmoteHeight();
      if (next !== height) {
        height = next; dimensions.clear(); listeners.forEach(refresh => refresh());
      }
      return true;
    }
  }});
  return true;
})()
)TPKSIZE";

bool TPKChatEmoteSizeInstall(jsi::Runtime &runtime) {
    try {
        runtime.global().setProperty(runtime, "__TPKEmoteHeight", jsi::Function::createFromHostFunction(runtime,
            jsi::PropNameID::forAscii(runtime, "__TPKEmoteHeight"), 0,
            [](jsi::Runtime &, const jsi::Value &, const jsi::Value *, size_t) {
                return jsi::Value((double)TPKNativeEmoteHeight());
            }));
        auto result = runtime.evaluateJavaScript(std::make_shared<TPKEmoteSizeBuffer>(sizeAdapter),
                                                 "twitchplusk-emote-size.js");
        return result.isBool() && result.getBool();
    } catch (...) { return false; }
}
