/*
 * banger fork addition — detect a qualifying listen (played ≥ half the track, or ≥ 4 min) and
 * log it via BangerScrobbles. Modelled on MediaSessionHolder: a PlaybackStateManager.Listener
 * created by a Hilt factory and attached/released by the playback service.
 */
package org.oxycblt.auxio.playback

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.oxycblt.auxio.banger.BangerScrobbles
import org.oxycblt.auxio.music.resolve
import org.oxycblt.auxio.music.resolveNames
import org.oxycblt.auxio.playback.state.PlaybackStateManager
import org.oxycblt.auxio.playback.state.Progression
import org.oxycblt.auxio.playback.state.QueueChange
import org.oxycblt.musikr.Music
import org.oxycblt.musikr.MusicParent
import org.oxycblt.musikr.Song

class ScrobbleManager
private constructor(
    private val context: Context,
    private val playbackManager: PlaybackStateManager,
) : PlaybackStateManager.Listener {
    class Factory
    @Inject
    constructor(
        private val playbackManager: PlaybackStateManager,
        @ApplicationContext private val context: Context,
    ) {
        fun create() = ScrobbleManager(context, playbackManager)
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var pending: Job? = null
    private var trackedUid: Music.UID? = null
    private var startedAt = 0L
    private var logged = false

    fun attach() {
        playbackManager.addListener(this)
    }

    fun release() {
        pending?.cancel()
        scope.cancel()
        playbackManager.removeListener(this)
    }

    override fun onIndexMoved(index: Int) = evaluate()

    override fun onQueueChanged(queue: List<Song>, index: Int, change: QueueChange) = evaluate()

    override fun onNewPlayback(
        parent: MusicParent?,
        queue: List<Song>,
        index: Int,
        isShuffled: Boolean,
    ) = evaluate()

    override fun onProgressionChanged(progression: Progression) = evaluate()

    override fun onSessionEnded() {
        pending?.cancel()
    }

    /**
     * Re-arm the scrobble timer for the current song. Any state change (song, play/pause, seek)
     * routes here; it detects a song change itself, then schedules the listen for when the track
     * crosses the threshold (½ its length, capped at 4 min) of *playing* time.
     */
    private fun evaluate() {
        val song = playbackManager.currentSong
        if (song?.uid != trackedUid) {
            trackedUid = song?.uid
            startedAt = System.currentTimeMillis() / 1000
            logged = false
        }
        pending?.cancel()
        if (song == null || logged || song.durationMs < 30_000) return
        val progression = playbackManager.progression
        if (!progression.isPlaying) return
        val threshold = minOf(THRESHOLD_MS, song.durationMs / 2)
        val remaining = threshold - progression.calculateElapsedPositionMs()
        if (remaining <= 0) {
            logListen(song)
        } else {
            pending =
                scope.launch {
                    delay(remaining)
                    val now = playbackManager.currentSong
                    if (now?.uid == song.uid && playbackManager.progression.isPlaying && !logged) {
                        logListen(song)
                    }
                }
        }
    }

    private fun logListen(song: Song) {
        logged = true
        val artist = song.artists.resolveNames(context)
        val title = song.name.resolve(context)
        val album = song.album.name.resolve(context)
        val listenedAt = startedAt
        // Append off the main thread — it's a tiny write, but playback shouldn't wait on I/O.
        scope.launch(Dispatchers.IO) {
            BangerScrobbles.record(context, artist, title, album, listenedAt)
        }
    }

    private companion object {
        const val THRESHOLD_MS = 4 * 60 * 1000L
    }
}
