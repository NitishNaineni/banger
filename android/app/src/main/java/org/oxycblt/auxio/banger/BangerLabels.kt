/*
 * banger fork addition — cross-device like/dislike.
 *
 * Appends this phone's decision to its OWN append-only log in the Syncthing-synced
 * library folder, matching the desktop's labels_sync.py format:
 *     <Music>/Library/.banger/labels-<device>.jsonl
 *     {"k": "<artist>|<title>", "l": "like|dislike", "t": <epoch_ms>, "d": "<device>"}
 * No two devices write the same file (so Syncthing never conflicts); the desktop merges
 * all device logs by last-writer-wins and reconciles into its DB + ListenBrainz.
 */
package org.oxycblt.auxio.banger

import android.content.Context
import android.os.Environment
import android.provider.Settings
import android.widget.Toast
import java.io.File
import org.json.JSONObject

object BangerLabels {
    private val syncDir
        get() = File(Environment.getExternalStorageDirectory(), "Music/Library/.banger")

    private fun deviceId(context: Context): String {
        val id = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        return "ph-" + (id ?: "unknown").take(8)
    }

    /** Record a like/dislike (or "none") for a track; artist/title come from the FLAC tags. */
    fun record(context: Context, artist: String, title: String, label: String) {
        try {
            val key = "${artist.trim().lowercase()}|${title.trim().lowercase()}"
            val entry = JSONObject()
                .put("k", key)
                .put("l", label)
                .put("t", System.currentTimeMillis())
                .put("d", deviceId(context))
            val dir = syncDir.also { it.mkdirs() }
            File(dir, "labels-${deviceId(context)}.jsonl")
                .appendText(entry.toString() + "\n")
            val msg = if (label == "like") "👍 Liked" else "👎 Disliked"
            Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(context, "Couldn't save rating — grant All files access", Toast.LENGTH_LONG)
                .show()
        }
    }
}
