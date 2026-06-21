# banger — Android app (Auxio fork)

This is a fork of **[Auxio](https://github.com/OxygenCobalt/Auxio)** v4.1.0
(`org.oxycblt.auxio`, GPLv3) — chosen via fact-checked research because it's the
local-FLAC player whose complete Android MediaSession is *confirmed in source* (so
ListenBrainz scrobbling is guaranteed to work), with FLAC + full ReplayGain, a modern
Material 3 UI, and active maintenance (Android 16 support).

The **app source is vendored here** (our editable fork). The heavy build dependencies are
**NOT vendored** (they belong as submodules / build artifacts, not committed bytes):

- `media/` — Auxio's **fork of AndroidX Media3** (~515 MB), built FROM SOURCE
  (`settings.gradle` → `apply from: file("media/core_settings.gradle")`). Submodule of
  `OxygenCobalt/media`.
- `musikr/src/main/cpp/taglib/` — **TagLib** (C++) for native metadata, built via the
  NDK. Submodule of `taglib/taglib` (pinned tag `ee1931b`).

## Build reality (the hard part)

`gradlew assembleDebug` here is a **native toolchain build**, not a quick assemble:
- **Android SDK** (platform-tools, platform `android-36`, build-tools) — not yet installed.
- **NDK + CMake** — to compile TagLib and `musikr`'s native code.
- **JDK 21 toolchain** — the project targets Java 21 (this box has JDK 25; Gradle 9.4.1
  can run on it but the toolchain target is 21, auto-provisioned via foojay).
- Gradle 9.4.1 (wrapper present) pulls a large dependency set on first build.

**Planned simplification:** drop `media-lib-decoder-ffmpeg` (the FFmpeg decoder extension,
also built from source — `app/build.gradle:155`). FLAC playback doesn't need it, and it's
the most painful native piece (manual FFmpeg build). To evaluate next: whether we can use
**upstream `androidx.media3` from Maven** instead of building the 515 MB fork from source.

## banger additions to build on top (the actual feature work)

1. **👍 / 👎 like-dislike** on now-playing + track rows → write the per-track label to the
   CRDT changelog (synced to the desktop via Syncthing) **and** send ListenBrainz love/hate.
2. **Karaoke lyrics view** — read the embedded FLAC `LYRICS` vorbis comment (the same
   enhanced-LRC the desktop writes) and render the word-by-word widget.
3. **ListenBrainz scrobbling** — native, or pair with Pano Scrobbler (`com.arn.scrobble`).

No downloading happens here (desktop-only). See `../docs/architecture.md`.
