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
    internal val syncDir
        get() = File(Environment.getExternalStorageDirectory(), "Music/Library/.banger")

    internal fun deviceId(context: Context): String {
        val id = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        return "ph-" + (id ?: "unknown").take(8)
    }

    /** The cross-device track key — must match the desktop's labels_sync.key_for(). */
    fun key(artist: String, title: String) = "${artist.trim().lowercase()}|${title.trim().lowercase()}"

    /** Merge every device's log (last-writer-wins) into the current label per track key. */
    fun mergedLabels(): Map<String, String> {
        val label = HashMap<String, String>()
        val stamp = HashMap<String, Pair<Long, String>>()
        val files =
            syncDir.listFiles { f -> f.name.startsWith("labels-") && f.name.endsWith(".jsonl") }
                ?: return label
        for (f in files) {
            try {
                f.forEachLine { line ->
                    if (line.isBlank()) return@forEachLine
                    val o = JSONObject(line)
                    val k = o.getString("k")
                    val t = o.getLong("t")
                    val d = o.getString("d")
                    val cur = stamp[k]
                    if (cur == null || t > cur.first || (t == cur.first && d > cur.second)) {
                        stamp[k] = t to d
                        label[k] = o.getString("l")
                    }
                }
            } catch (e: Exception) {}
        }
        return label
    }

    /** The keys currently liked — the Library tab is built from this (dedup-proof). */
    fun likedKeys(): Set<String> = mergedLabels().filterValues { it == "like" }.keys

    /** The current label ("like"/"dislike"/null) for a track, for the play-bar 👍/👎 state. */
    fun labelFor(artist: String, title: String): String? = mergedLabels()[key(artist, title)]

    /**
     * Record a like/dislike (or "none") for a track; artist/title come from the FLAC tags.
     * [showToast] confirms the action — used by the menu (no other feedback there); the play-row
     * buttons pass false since their solid colour already shows the new state.
     */
    fun record(
        context: Context,
        artist: String,
        title: String,
        label: String,
        showToast: Boolean = true,
    ) {
        try {
            val key = key(artist, title)
            val entry = JSONObject()
                .put("k", key)
                .put("l", label)
                .put("t", System.currentTimeMillis())
                .put("d", deviceId(context))
            val dir = syncDir.also { it.mkdirs() }
            File(dir, "labels-${deviceId(context)}.jsonl")
                .appendText(entry.toString() + "\n")
            if (showToast) {
                val msg =
                    when (label) {
                        "like" -> "👍 Liked"
                        "dislike" -> "👎 Disliked"
                        else -> "Rating cleared"
                    }
                Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            Toast.makeText(context, "Couldn't save rating — grant All files access", Toast.LENGTH_LONG)
                .show()
        }
    }
}
