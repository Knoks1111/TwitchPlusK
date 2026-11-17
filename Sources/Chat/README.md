# Maintenance du chat

Après une mise à jour de Twitch, analyser le bundle Hermes et les métadonnées des binaires. Modifier uniquement les changements confirmés et tester sur appareil.

- `tpK-chat-runtime.mm` : vérifier l'ABI React Native, la taille et le SHA-256 du bundle dans `Approved()`, puis les hooks de cycle de vie. Ne pas contourner cette protection.
- `Emote/RNLive/tpK-chat-emote-size.mm` : retrouver le module Hermes `EmotePart`, `chat-emote-wrapper-*` et son enfant `chat-emote-*`.
- `FirstChatter/tpK-native-first-chatter.mm` : retrouver `translateChatMessage.isFirstMessage`, `ChatLine` et le type `firstchatter`.
- `DeletedMessages/tpK-native-deleted-messages.mm` : retrouver `useChatSelector`, `ChatLine`, `MessageBody` et les méthodes `LibraryTmiClient` utilisées.
- `Emote/UIKit/tpK-chat-uikit-emote-size.m` : vérifier l'UUID, les empreintes et instructions, les méthodes Swift de taille, leurs slots et les appels à `setBounds:`. Vérifier aussi le relais ARM64 et le ratio `tpk_r`.
- `Appearance/tpK-chat-event-appearance.m` : vérifier les `testID` des conteneurs d'événements, notamment `EventLineGroup`.
- `Emote/UIKit/VOD/tpK-chat-vod-emotes.m` : vérifier les opérations GraphQL de commentaires, les fragments et les callbacks du client réseau natif.
- `Core/tpK-channel-resolver.m` : vérifier les hooks de navigation live et les sources d'identité VOD. Ne pas lire directement les champs mémoire Swift.
- `Emote/RNLive/tpK-chat-emotes.mm` : vérifier `RCTWebSocketModule.webSocket:didReceiveMessage:`, les tags IRC `emotes` et les URL natives `emoticons/v2`.
- `Emote/RNLive/tpK-chat-emote-animation.m` : vérifier les méthodes `RCTUIImageViewAnimated` et `RCTImageComponentView` utilisées pour les animations.
- `Emote/UIKit/LegacyLive/tpK-chat-legacy-emotes.m` : vérifier le hook `NSURLSessionWebSocketTask.receiveMessageWithCompletionHandler:`.
- `Emote/tpK-chat-emote-images.m` : vérifier les routes natives d'images `emoticons/v1` et `v2`.
