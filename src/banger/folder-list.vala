/*
 * banger — a self-contained MusicList over a folder.
 *
 * It owns its own ListStore, derived purely by scanning a folder — decoupled from
 * the app's library scan, the m3u playlists and the play queue. So adding/removing
 * a track is immediate, never disturbs playback (current_music stays put), and
 * covers load per-row (MusicList's native lazy thumbnailing). This is the
 * foundation for both the Audition and Library tabs.
 */
namespace G4 {

    public class FolderList : MusicList {
        protected File folder;
        protected uint sort_order = SortMode.TITLE;
        private HashTable<string, Music> _cache = new HashTable<string, Music> (str_hash, str_equal);
        private bool _loading = false;
        private bool _reload_pending = false;
        private uint _cooldown = 0;
        private Gdk.Paintable _placeholder;

        public signal void reloaded (uint count);

        public FolderList (Application app, File folder, string sort_key) {
            base (app, typeof (Music), null, false);
            this.folder = folder;
            _placeholder = app.thumbnailer.create_simple_text_paintable ("...", Thumbnailer.ICON_SIZE);
            // each tab keeps its OWN sort, persisted in its own setting
            sort_order = app.settings.get_uint (sort_key);
            app.settings.bind (sort_key, this, "list-sort", SettingsBindFlags.DEFAULT);

            item_binded.connect ((item) => {
                var entry = (MusicEntry) item.child;
                // give the cover a placeholder so its first draw fires and the real
                // album art lazy-loads (matches the built-in lists).
                entry.paintable = _placeholder;
                entry.set_titles ((Music) item.item, sort_order);
            });
            // playback is wired by the owner (store-panel), which mirrors this list
            // into the play queue so the Playing tab reflects it.

            BangerService.instance.lists_changed.connect (reload);
            map.connect (reload);
        }

        // Re-scan the folder and refresh the list (tags parsed off the main thread,
        // cached by uri so repeat scans are instant). Leading-edge + cooldown: the
        // first call runs immediately, a burst (e.g. a 70-track refresh firing per
        // track) collapses into one trailing rescan instead of thrashing the view.
        public void reload () {
            if (_loading || _cooldown != 0) {
                _reload_pending = true;
                return;
            }
            run_reload ();
        }

        private void run_reload () {
            _reload_pending = false;
            do_reload.begin ((obj, res) => {
                do_reload.end (res);
                _cooldown = Timeout.add (300, () => {
                    _cooldown = 0;
                    if (_reload_pending)
                        run_reload ();
                    return Source.REMOVE;
                });
            });
        }

        private async void do_reload () {
            _loading = true;
            var found = new GenericArray<Music> ();
            var dir = folder;
            var cache = _cache;
            yield run_void_async (() => {
                try {
                    var en = dir.enumerate_children (
                        "standard::name,standard::content-type,time::modified",
                        FileQueryInfoFlags.NONE);
                    FileInfo? info = null;
                    while ((info = en.next_file ()) != null) {
                        unowned var ctype = ((!) info).get_content_type () ?? "";
                        if (!is_music_type (ctype))
                            continue;
                        var file = dir.get_child (((!) info).get_name ());
                        var uri = file.get_uri ();
                        Music? m = cache.get (uri);
                        if (m == null) {
                            var time = ((!) info).get_modification_date_time ()?.to_unix () ?? 0;
                            var music = new Music (uri, ((!) info).get_name (), time);
                            music.parse_tags ();
                            cache.set (uri, music);
                            m = music;
                        }
                        found.add ((!) m);
                    }
                } catch (Error e) {
                }
            });
            sort_music_array (found, sort_order);
            data_store.splice (0, data_store.get_n_items (), (Object[]) found.data);
            _loading = false;
            reloaded (found.length);
        }

        // bound to the tab's sort setting; the store-panel sets this when the user
        // picks a sort while viewing this tab.
        public uint list_sort {
            get { return sort_order; }
            set { set_sort_order (value); }
        }

        public void set_sort_order (uint mode) {
            if (sort_order != mode) {
                sort_order = mode;
                reload ();
            }
        }
    }
}
