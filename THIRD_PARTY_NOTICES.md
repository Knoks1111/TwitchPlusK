# Third-party notices

## TwitchAdBlock VAFT for iOS (Local/VAFT engine)

The `Sources/Adblock/Vaft/` engine (TwitchAdBlock.c, TASDiagnostics.c) is
adapted from [TwitchAdBlock-VAFT-iOS](https://github.com/BananaOnGitHub/TwitchAdBlock-VAFT-iOS),
port version 2.2.0 — a native iOS port of the VAFT strategy from
[pixeltris/TwitchAdSolutions](https://github.com/pixeltris/TwitchAdSolutions)
(VAFT v24, MIT License).

Copyright BananaOnGitHub (TwitchAdBlock-VAFT-iOS) — Apache License, Version 2.0.
The upstream provenance and TwitchPlusK adaptations are documented below.

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use these files except in compliance with the License. You may obtain a copy
of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required
by applicable law or agreed to in writing, software distributed under the
License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
OF ANY KIND, either express or implied.

### Upstream provenance and TwitchPlusK adaptations

- Upstream project: `BananaOnGitHub/TwitchAdBlock-VAFT-iOS` (Apache-2.0)
- Port version: **2.2.0**
- Strategy: VAFT solution 24 from `pixeltris/TwitchAdSolutions`
- Upstream strategy commit: `c51ef2fe8f667f9dc9216eb550924cf0d732ce27`
- SHA-256 of the copied upstream strategy script: `8ba15a99627c3d2a8fab3c3011b43d68ecb89eb40af549b0052d98449f02f591`
- Imported files: `TwitchAdBlock.c/.h` (VAFT engine) and
  `TASDiagnostics.c/.h` (sanitized diagnostics)

TwitchPlusK adaptations are algorithmically neutral:

| ID | Upstream | TwitchPlusK | Reason |
|----|----------|-------------|--------|
| D1 | `__attribute__((constructor)) tas_initialize` | `vaft_initialize()` called by `S7TVAdblockInstallRuntimeHooks` when Local is active | One constructor; Proxy/Local exclusivity |
| D2 | No master toggle | O(1) `S7TVAdblockEnabledFast` snapshot gates at the three VAFT entry points | TwitchPlusK master toggle without preference reads in hot paths |
| D3 | Foundation hooks installed unconditionally | Installed only when Local is active | Proxy/Local exclusivity |
| D5 | Full `tas_diagnostics_initialize` settings injection | `register_log_class()` plus `PORT_LOADED` log; controls live in TwitchPlusK Logs | Host settings page is used instead of a separate VAFT page |

The remaining VAFT code is kept unchanged (functions, structures, constants,
operation order, retries, TTLs, rings, locking and snapshots).

## TwitchAdSolutions (VAFT strategy)

The VAFT strategy implemented by the engine above originates from
[pixeltris/TwitchAdSolutions](https://github.com/pixeltris/TwitchAdSolutions)
(`vaft` solution 24, uBlock Origin script distribution), licensed under the
MIT License.

## TwitchAdBlock

Parts of the ad-blocking, GraphQL filtering, HLS proxy, proxy authentication,
external-playback bypass, AVFoundation resource-loading, Twitch Turbo upsell
hiding, launch destination, Twitch Stories hiding, and Live-feed watch-limit code are derived from
[TwitchAdBlock](https://github.com/gunnerkidBT/TwitchAdBlock), including work
by level3tjg and gunnerkidBT.

The Proxy implementation and its fishhook dependency are located in
`Sources/Adblock/Proxy/`.

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

TwitchAdBlock uses Facebook's fishhook library for its client-side Swift
ad-controller interception. TwitchPlusK includes the same library unchanged.

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
