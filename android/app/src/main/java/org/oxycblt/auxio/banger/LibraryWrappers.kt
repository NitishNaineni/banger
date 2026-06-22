/*
 * banger fork addition — lightweight Artist/Album views whose song/album lists are pre-filtered
 * to the user's liked tracks. Auxio's music graph indexes both folders (so playback stays
 * robust), but the home Artists/Albums tabs and the detail headers should read library-only
 * counts. Wrapping is safe: the concrete musikr impls are `internal`, so the app only ever sees
 * the Artist/Album interfaces. Equality is by UID so selection/diffing behave normally.
 */
package org.oxycblt.auxio.banger

import org.oxycblt.musikr.Album
import org.oxycblt.musikr.Artist
import org.oxycblt.musikr.Song

class LibraryArtist(
    private val delegate: Artist,
    override val songs: Collection<Song>,
    override val explicitAlbums: Collection<Album>,
    override val implicitAlbums: Collection<Album>,
) : Artist {
    override val uid
        get() = delegate.uid

    override val name
        get() = delegate.name

    override val durationMs
        get() = delegate.durationMs

    override val covers
        get() = delegate.covers

    override val genres
        get() = delegate.genres

    override fun equals(other: Any?) = other is Artist && other.uid == delegate.uid

    override fun hashCode() = delegate.uid.hashCode()
}

class LibraryAlbum(private val delegate: Album, override val songs: Collection<Song>) : Album {
    override val uid
        get() = delegate.uid

    override val name
        get() = delegate.name

    override val dates
        get() = delegate.dates

    override val releaseType
        get() = delegate.releaseType

    override val covers
        get() = delegate.covers

    override val durationMs
        get() = delegate.durationMs

    override val addedMs
        get() = delegate.addedMs

    override val artists
        get() = delegate.artists

    override fun equals(other: Any?) = other is Album && other.uid == delegate.uid

    override fun hashCode() = delegate.uid.hashCode()
}
