/*
 * banger fork addition — log completed listens to a Syncthing-shared file. The desktop reads
 * these and submits them to ListenBrainz (keeping the LB token on the desktop only), with its
 * own offline retry, so a phone listen reaches LB online or off, at some point.
 */
package org.oxycblt.auxio.banger

import android.content.Context
import java.io.File
import org.json.JSONObject

object BangerScrobbles {
    /** Append a qualifying listen; the desktop submits it to ListenBrainz. */
    fun record(context: Context, artist: String, title: String, album: String, listenedAt: Long) {
        try {
            val device = BangerLabels.deviceId(context)
            val entry =
                JSONObject()
                    .put("ts", listenedAt)
                    .put("artist", artist)
                    .put("title", title)
                    .put("album", album)
                    .put("d", device)
            val dir = BangerLabels.syncDir.also { it.mkdirs() }
            File(dir, "listens-$device.jsonl").appendText(entry.toString() + "\n")
        } catch (e: Exception) {
            // Best-effort; a missed listen is not worth interrupting playback for.
        }
    }
}
