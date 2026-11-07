# Third-party notices

TwitchPlusK includes or adapts the components below. Their source, attribution and license are listed here.

## VAFT ad-blocking engine

Location: `Sources/Adblock/Vaft/` (`TwitchAdBlock.c/.h`, `TASDiagnostics.c/.h`).

- Adapted from [TwitchAdBlock-VAFT-iOS](https://github.com/BananaOnGitHub/TwitchAdBlock-VAFT-iOS), version 2.2.0 (Apache-2.0).
- Based on [TwitchAdSolutions](https://github.com/pixeltris/TwitchAdSolutions), VAFT solution 24 (MIT).
- Upstream commit: `c51ef2fe8f667f9dc9216eb550924cf0d732ce27`.
- Copied strategy SHA-256: `8ba15a99627c3d2a8fab3c3011b43d68ecb89eb40af549b0052d98449f02f591`.
- Copyright: BananaOnGitHub (TwitchAdBlock-VAFT-iOS).

TwitchPlusK integration changes:

- Calls `vaft_initialize()` from `S7TVAdblockInstallRuntimeHooks` instead of adding a second constructor.
- Adds an O(1) master-toggle snapshot at the three VAFT entry points.
- Updates the NSURLProtocol HLS transport and cancellation from [Streamside](https://github.com/BananaOnGitHub/Streamside/blob/2f81a409c143644e3e2e11f016a3de970e49ef7b/src/Streamside.c), commit `2f81a409c143644e3e2e11f016a3de970e49ef7b` (Apache-2.0). Provider-image branches are excluded; the HLS session, asynchronous tasks, callback delivery and cancellation follow upstream.
- Installs Foundation hooks only when Local mode is active.
- Replaces VAFT settings injection with `register_log_class()` and `PORT_LOADED`; settings live in TwitchPlusK Logs.

The VAFT playlist selection, fallback strategy, retries, TTLs and per-channel contexts remain unchanged.

Licensed under the Apache License, Version 2.0. A copy is available at
http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law
or agreed to in writing, software distributed under the License is provided on
an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.

## TwitchAdBlock integration

Ad-blocking, GraphQL filtering, HLS proxy/authentication, playback bypass,
AVFoundation loading, Turbo/Stories hiding, launch handling and Live-feed
watch-limit code are derived from [TwitchAdBlock](https://github.com/gunnerkidBT/TwitchAdBlock),
including work by level3tjg and gunnerkidBT. Source: `Sources/Adblock/Proxy/`.

Live-feed React Native watch-limit handling is adapted from commit
`ce878d46205c7d7ed22df0cb78422ba913aef252` (`Tweak.x` and
`NSData+TwitchAdBlock.m`): response-byte rewriting, native watch-behavior
limits and the `awaitFeedPreload:rejecter:` bridge. TwitchPlusK uses its
independent Keep Live Feed Playing setting. The v0.1.17 preload ad filter is
also applied before resolving the bridge when any AdBlock method is enabled,
independently of the watch-limit setting. Feed/UI ad filtering is shared by Proxy,
Local VAFT and Proxy + Local; it preserves typed ad metadata fields in preloads.
The same commit supplies Stories GraphQL shelf/access filtering and launch
selection retries/navigation guards in `Sources/System/tpK-system-home-features.m`.
Launch selection retains TwitchPlusK's hidden-tab mapping and existing RN tap
selection when no native paged scroll view is available.

Copyright (c) 2025 level3tjg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## fishhook

Facebook's fishhook is included unchanged as a TwitchAdBlock Proxy dependency.

Copyright (c) 2013, Facebook, Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name Facebook nor the names of its contributors may be used to
  endorse or promote products derived from this software without specific
  prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## React Native JSI

JSI headers and the Buffer/Value lifetime helpers in `Sources/Chat/` are from
[React Native v0.86.3](https://github.com/facebook/react-native/tree/v0.86.3/packages/react-native/ReactCommon/jsi/jsi).
Copyright Meta Platforms, Inc. and affiliates. MIT license: `Sources/Chat/JSI/LICENSE`.
