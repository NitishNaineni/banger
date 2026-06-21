# banger — Android app

A fork of **[Auxio](https://github.com/oxygen-updater/auxio)** (`org.oxycblt.auxio`,
GPLv3) — chosen via fact-checked research because it's the local-FLAC player whose
complete Android MediaSession is *confirmed in source* (so ListenBrainz scrobbling is
guaranteed to work), with FLAC + full ReplayGain, a modern Material 3 UI, and active
maintenance (Android 16 support).

## Status: scaffolding

Auxio's source will be vendored into this directory and built with its Gradle wrapper.
The banger additions to build on top of stock Auxio:

1. **👍 / 👎 like-dislike** on the now-playing + track rows → writes the per-track label
   to the CRDT changelog (synced to the desktop) **and** sends ListenBrainz love/hate.
2. **Karaoke lyrics view** — read the embedded FLAC `LYRICS` vorbis comment (the same
   enhanced-LRC the desktop writes) and render the word-by-word karaoke widget.
3. **ListenBrainz scrobbling** — native (preferred) or pair with Pano Scrobbler
   (`com.arn.scrobble`), which scrobbles Auxio's MediaSession playback to ListenBrainz
   with an offline queue.

No downloading happens here — the phone plays the Syncthing-synced library and
contributes taste; new music is fetched on the desktop hub. See `../docs/architecture.md`.

## Build (once vendored)

```
cd android && ./gradlew assembleDebug      # then: adb install -r app/build/.../app-debug.apk
```

Toolchain present on the hub: `adb`, JDK 25. Android SDK to be confirmed.
