/*
 * banger fork addition — replace Auxio's MusicType home tabs with the desktop's set:
 * Audition · Library · Artists · Albums. Audition/Library are the same song pool split by
 * folder (the Syncthing-synced ~/Music/audition vs ~/Music/Library); Artists/Albums are
 * Auxio's native lists. The play queue stays in the player (no "Playing" home tab).
 */
package org.oxycblt.auxio.home

import org.oxycblt.musikr.Song

enum class BangerTab(val title: String) {
    AUDITION("Audition"),
    LIBRARY("Library"),
    ARTISTS("Artists"),
    ALBUMS("Albums");

    companion object {
        val ALL = listOf(AUDITION, LIBRARY, ARTISTS, ALBUMS)

        /** A song belongs to Audition if its path has an "audition" folder segment; everything
         *  else (the liked Library/ copies + any stray music) is treated as Library. */
        fun isAudition(song: Song) =
            song.path.components.components.any { it.equals("audition", ignoreCase = true) }
    }
}
