# Research: ad blocking and video downloads in the YouTube iOS app

*November 2026. Background for `AdBlock.x` and `Downloader/`.*

## TL;DR

- **Ad blocking only works reliably inside the app process.** YouTube serves ads through the same InnerTube API responses and the same `googlevideo.com` media servers as the videos themselves, so DNS or host blocklists (Pi-hole, NextDNS, AdGuard DNS) can't tell ads from content. A tweak runs inside YouTube, so it can remove the ads from the decoded response objects before the app acts on them. That is what `AdBlock.x` does, in four layers: video ads, feed ads, Shorts ads and shopping placements.
- **The biggest long-term threat is server-side ad insertion (SSAI).** There the ad is stitched into the media stream itself. The iOS player already has a code path for it (`MLPlayerReloadContext … disableDAI:`). If YouTube turns it on for the app, removing the ad schedule from the response will no longer be enough. Sources disagree about how far it has rolled out (see below).
- **Downloads:** since the switch to SABR (server-side adaptive bitrate), the YouTube app's own player response no longer contains per-format stream URLs. The downloader asks InnerTube for the same video with client profiles that still get plain URLs without a proof-of-origin (PO) token (`VISIONOS`, then `ANDROID_VR`). It downloads them in 8 MiB range chunks and merges video and audio with AVFoundation. No FFmpeg is involved.

---

## Part 1 — Ad blocking

### Where the ads come from

All YouTube content reaches the app as protobuf messages from InnerTube (`youtubei.googleapis.com/youtubei/v1/...`). The app decodes them into generated `YTI…` Objective-C classes (subclasses of `GPBMessage`). Ads arrive in the same messages:

| Ad type | Where it lives in the response | Class / field (iOS app) |
|---|---|---|
| Pre-, mid- and post-roll video ads | `/player` response | `YTIPlayerResponse.playerAdsArray`, `adSlotsArray`, `adPlacementsArray`, `isMonetized` |
| Ads in Home / Search / Watch next | `/browse`, `/search`, `/next` responses | `YTIElementRenderer`s carrying `compatibilityOptions.adLoggingData` or ad layout identifiers (`feed_ad_metadata`, `text_search_ad`, `product_carousel`, …), plus `promotedVideoRenderer` items |
| Inline feed ads inserted later | Ad slots attached to the list | `YTAdElementsCellExternallyManagedSlotAdapterImpl` |
| Shorts ads | `/reel/...` sequence entries | `YTReelModel.videoType == 3`, `YTReelNonVideoContentModel` with `reelNonVideoAdsCustomData` |
| Shopping / product placements | `/next` `onUiReady` commands, player overlays | Engagement panel `PAproduct_list`, overlay `player_overlay_product_in_video`, view `eml.expandable_metadata.vpp` |
| The ad media itself | `googlevideo.com` | Same servers and URL format as regular videos |

### Approaches I evaluated

| # | Approach | Verdict |
|---|---|---|
| 1 | **DNS / host blocking** (Pi-hole, NextDNS, AdGuard DNS, a hosts file) | ❌ Doesn't work for YouTube. Ads and videos come from the same `googlevideo.com` hosts and the same InnerTube API, so blocking them breaks playback. This is the consensus on the Pi-hole and NextDNS forums. Only third-party trackers (`doubleclick.net`, `googlesyndication.com`) can be blocked, and that doesn't remove a single ad. |
| 2 | **Request blocking inside the app** (an `NSURLProtocol` or session hook that drops "ad" requests) | ❌ Same problem: there are no separate ad requests to drop. YouTube also does most of its networking through Cronet (Chromium's network stack), which bypasses `NSURLProtocol`, so coverage would be partial and fragile. Not implemented. |
| 3 | **Don't ask for ads** (strip the ad context and ad-targeting signals from outgoing requests) | ⚠️ Helps a little (less targeting) but doesn't remove ads on its own. Kept as a supporting layer (`YTAdsInnerTubeContextDecorator`, `YTDataUtils` / `YTAdShieldUtils` signal hooks). |
| 4 | **Rewrite the response model** (remove ads from the decoded protobuf objects before the player, feed or Shorts code reads them) | ✅ **The approach used.** It works because the tweak runs inside the app and sees the messages after TLS and decoding. It is what PoomSmart's YouTube-X (MIT, maintained against current YouTube builds), ytkace and YouMod all do. |
| 5 | **Hide views after they render** | ⚠️ A last resort only. It leaves blank gaps and depends on view identifiers that change often. Used for two leftovers (`elementData` and the `.vpp` view). |
| 6 | **Skip ads by timing** (seek past them, SponsorBlock-style) | Future option. It's the only client-side answer to stitched-in (SSAI) ads, and it handles creator-read sponsorships. Not implemented here (see "Next steps"). |

### What `AdBlock.x` does

Everything is behind the existing **Remove ads** switch (`noAds`, on by default). Every hook checks the switch when it runs and calls the original behavior when the switch is off.

| Layer | Hook | Effect |
|---|---|---|
| 1. Video ads | `YTIPlayerResponse` `playerAdsArray` / `adSlotsArray` / `adPlacementsArray` → empty | The player never learns about ad breaks. These are protobuf getters that `GPBMessage` creates lazily, so they are swapped at runtime in `%ctor` (see `YTLOverrideGetter`). `class_getInstanceMethod` triggers the lazy resolution first. |
| | `YTIPlayerResponse.isMonetized` → NO | Older code paths. |
| | `YTLocalPlaybackController createAdsPlaybackCoordinator` → nil | No ad playback coordinator, so nothing can schedule an ad. |
| | `MDXSession(Impl) adPlaying:`, `YTIClientMdxGlobalConfig enableSkippableAd` | Casting (TV) sessions. |
| | Ad context decorators, spam/ad signals, `YTHotConfig …FillingEncodedHacks…` | Stop sending ad-targeting context. |
| 2. Feed ads | `YTInnerTubeCollectionViewController` (`displaySections…`, `addSectionsFromArray:`), `YTArraySectionViewModel` (all entry paths) | Removes sections, shelf items and entries whose element renderer has ad logging data or an ad layout identifier. |
| | `YTAdElementsCellExternallyManagedSlotAdapterImpl isValidSlotType:` → NO | Inline feed ads inserted later through ad slots. |
| | `YTSectionListViewController loadWithModel:` | Promoted videos (older YouTube versions). |
| | `YTIElementRenderer elementData` (in `YTLite.x`) | A last line of defense for single elements. It fixes an old bug: the identifier list was compared with `containsObject:` against the whole description, so it never matched. |
| 3. Shorts ads | `YTReelDataSource` / `YTReelInfinitePlaybackDataSource` / `YTReelContentModel` `makeContentModelForEntry:`, `setReels:` | Ad entries are dropped from the Shorts sequence. |
| 4. Shopping | `YTWatchNextResponseViewController loadWithModel:` | Removes the auto-opening "products in this video" panel (`PAproduct_list`). |
| | `YTMainAppVideoPlayerOverlayViewController playerOverlayProvider:didInsertPlayerOverlay:` | Drops the `player_overlay_product_in_video` overlay. |
| | `_ASDisplayView didMoveToWindow` | Removes the `eml.expandable_metadata.vpp` product row. |

YouTube Premium upsells and interstitial promos were already blocked by the NoYTPremium hooks in `YTLite.x`. The separate "Hide paid promotion card" option still controls the "Includes paid promotion" label.

The ad-layout list follows YouTube-X (October 2026) with one deliberate exception: `post_shelf` is **not** treated as an ad, so community posts in the feed stay visible.

### Server-side ad insertion (SSAI / "DAI")

With SSAI the ad is part of the video segments the server sends, so there is no separate ad to remove. Facts and claims:

- The iOS player already knows about it: `MLPlayerReloadContext` has an initializer with `disableSABR:` and `disableDAI:` (Dynamic Ad Insertion) flags (from the YouTubeHeader dumps). No open-source tweak hooks this yet. It's the obvious place to investigate if stitched ads appear in the app.
- Reports conflict on how widely it has rolled out. A blocker vendor claims a global rollout in 2026. Privacy Intact said it was still limited testing as of July 10, 2026. Geeky Gadgets describes it as an experiment.
- What would likely still work against stitched ads is timing-based skipping. This is an inference, not verified: the player presumably still needs the ad-break boundaries to show the ad UI (the "Ad" label and skip button), so they would probably still be in the response and could be seeked past. SponsorBlock-style community timings are another option. YouTube Premium is the only approach that is fully reliable.

### Next steps (not implemented)

1. **SponsorBlock**: skip creator-read sponsor segments. Fetch segments with the privacy-preserving hash-prefix API (`https://sponsor.ajay.app/api/skipSegments/<sha256-prefix>`) and seek past them from the existing `singleVideo:currentVideoTimeDidChange:` hook in `YTLite.x`. The strings and `SponsorAudio.m4a` are already in the bundle.
2. **SSAI fallback**: if stitched ads show up, read the ad-break timing before it is stripped and seek past it, or experiment with the `disableDAI` reload flag.

---

## Part 2 — Downloading videos to local storage

### Why the app's own stream URLs can't be used anymore

YouTube moved its own apps to **SABR** (server-side adaptive bitrate). Media is requested through a single `serverAbrStreamingUrl` using the UMP protocol, and the server chooses the segments. The player response still lists every format (itag, codec, size), but the per-format `url` is empty. YouMod's source states this for YouTube 21.29, and I saw the same thing on 2026-11-01: an InnerTube `/player` request with the `IOS` client (the app's own client) returned 16 adaptive formats and **0** URLs.

### Options

| Option | Notes | Verdict |
|---|---|---|
| URLs from the app's own response | Only works on YouTube versions from before SABR. | Kept as a **fallback** |
| **Another InnerTube client profile that still gets plain URLs** | One extra `/player` request per download. No signature deciphering or PO token needed for these clients. | ✅ **Primary** |
| Replay the app's own SABR/UMP requests | YouMod and ytkace do this. It captures the app's signed `videoplayback` request and parses UMP parts. Very version-sensitive (protobuf field numbers change). | Too fragile to maintain here |
| HLS manifest + `AVAssetDownloadURLSession` | Only some clients get `hlsManifestUrl`, and the result is a `.movpkg`. | Not used |
| Web/TV clients | Need a JavaScript player for signature and `n` deciphering plus a PO token (yt-dlp now needs an external JS runtime for this). | Not feasible in a tweak |

**Client survey (2026-11-01).** Same public video, logged out, with `visitorData`:

| Client | Status | Direct URLs |
|---|---|---|
| `VISIONOS` 1.02 | OK | all adaptive formats (+ HLS) |
| `ANDROID_VR` 1.65.10 | OK | all adaptive formats + muxed 360p (itag 18) |
| `IOS` / `ANDROID` | OK | **none** (SABR only) |
| `TVHTML5`, `MWEB` | UNPLAYABLE ("The page needs to be reloaded.") | — |

Without `visitorData` even `VISIONOS` returns `LOGIN_REQUIRED`. Every InnerTube client sends visitor data, and the downloader fetches it once and reuses it until it expires. It does **not** rotate identities or retry after a bot check. A bot-check answer is shown to the user as YouTube's own message.

This matches yt-dlp's documentation as of mid-2026. Its default clients are `tv_samsung, visionos, web`. `android_vr` needs no PO token, but "made for kids" videos aren't available through it. `ios` and `android` need a PO token. `web` only has SABR formats.

### Pipeline (`Downloader/`)

1. **`YTLStreamResolver`**: tries `VISIONOS`, then `ANDROID_VR`, then the app's own response. It returns only formats that have a URL, with the matching User-Agent.
2. **Quality picker**: H.264 MP4 up to 1080p60 (plays everywhere and can be saved to Photos). AV1 MP4 up to 4K is offered **only** on devices with a hardware AV1 decoder (A17 Pro / M3 or later on iOS 17+). VP9 and Opus are in WebM containers that AVFoundation can't remux without FFmpeg, so they're skipped. Audio-only uses AAC and lists one entry per audio track for dubbed videos. "Stable volume" (DRC) duplicates are dropped.
3. **`YTLChunkedDownloader`**: 8 MiB HTTP `Range` requests, 3 in parallel. `googlevideo.com` throttles long single requests, and yt-dlp uses ≤10 MiB chunks for the same reason. Failed chunks are retried, and a `403`/`410` (expired URL) triggers a fresh `/player` lookup for the same itag.
4. **`YTLMediaMuxer`**: AVFoundation passthrough (`AVMutableComposition` + `AVAssetExportPresetPassthrough`). The video and audio streams become one `.mp4` without re-encoding. If MP4 refuses the codec it falls back to `.mov`. Audio is remuxed to a regular `.m4a`.
5. **Saving**: the file goes to `Documents/Downloads`, which is excluded from iCloud backup. After that, an "After download" setting decides what happens: ask, Photos, Files (export to any folder), share sheet, or keep in the app.

**Seeing files in the Files app:** an app's Documents folder only appears under *On My iPhone › YouTube* when its Info.plist has `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. The *Create YouTube Plus app* workflow adds both keys when **Build from source** is ticked. On jailbroken installs, use "Save to Files" or "Share" instead.

### Limitations

- Private, members-only, age-restricted and "made for kids" videos may fail. YouTube's own error message is shown. The downloader deliberately makes logged-out requests and never sends your account cookies or token.
- Live streams and premieres can't be downloaded.
- Keep YouTube open while downloading. The app gets a short background grace period, not unlimited background time.
- Client profiles age. If YouTube stops serving URLs to `VISIONOS` and `ANDROID_VR`, update `YTLClientProfiles()` in `Downloader/YTLStreamResolver.m`. yt-dlp's `player_client` defaults are a good indicator of what currently works.
- Use it for personal offline viewing and respect creators' rights. YouTube Premium offers official offline downloads.

---

## How this was verified

- All new and changed sources were type-checked with clang (`-Wall -Werror`, iOS 13 deployment target, iPhoneOS 16.5 SDK, the same flags Theos uses) against **two** YouTubeHeader revisions: `07bb69b` (July 2024, matching these sources) and `4b9977e` (October 2026). Logos files were checked through a converter that reproduces Logos's generated C functions. The four existing upstream `.x` files pass as well, after fixing one `-Wmisleading-indentation` error in `Sideloading.x` that would fail a `-Werror` build on current compilers.
- The InnerTube format discovery above was observed directly on 2026-11-01.
- **Not verified here:** running on a device. The sandbox can't reach `googlevideo.com`, so the actual media download, merge and every hook's runtime behavior still need testing in the app. Use the **Build from source** workflow option to produce an IPA.

## Sources

- PoomSmart, YouTube-X (MIT): <https://github.com/PoomSmart/YouTube-X>. Current hook targets for layers 1–4.
- PoomSmart, YouTubeHeader: <https://github.com/PoomSmart/YouTubeHeader>. Class dumps (`MLPlayerReloadContext`, `YTIFormatStream`, …).
- itzzace, ytkace (MIT): <https://github.com/itzzace/ytkace>. `DirectDownloader.mm` (VISIONOS client, range chunks), `AdsHooks.mm`.
- Tonwalter888, YouMod (GPL-3.0): <https://github.com/Tonwalter888/YouMod>. `SABRDownload.x` notes on SABR in YouTube 21.29. Used as a reference only, no code copied.
- yt-dlp, PO Token Guide (edited Jul 12, 2026): <https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide>
- yt-dlp README, `player_client` defaults: <https://github.com/yt-dlp/yt-dlp#youtube>
- yt-dlp issue #12482, "`web` only has SABR formats": <https://github.com/yt-dlp/yt-dlp/issues/12482>
- Pi-hole forum, YouTube ads and the shared domain: <https://discourse.pi-hole.net/t/so-youtube-ads-cant-really-be-blocked-properly-with-pi-hole/34986>
- NextDNS help, "Why can't YouTube ads be blocked": <https://help.nextdns.io/t/g9hmvcq/why-cant-youtube-ads-be-blocked>
- AdGuard, blocking YouTube ads in 2026: <https://adguard.com/en/article/how-to-block-ads-on-youtube.html>
- SSAI coverage: <https://www.geeky-gadgets.com/outube-server-side-advertising/>, <https://theproblocker.com/blog/youtube-server-side-ad-insertion-breakthrough/>, <https://privacyintact.com/block-youtube-ads/> (rollout claims differ; see above)
- SponsorBlock API: <https://wiki.sponsor.ajay.app/w/API_Docs>
