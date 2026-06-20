/*
 * banger — the Audition page.
 *
 * A self-contained MusicList that lists the current audition batch. It scans
 * ~/Music/audition itself (the app's library is pointed at ~/Music/library, so
 * audition tracks never appear in Albums/Artists/Playlists) — liking a track
 * copies it into the library, where it then shows up everywhere.
 *
 * Header: a Refresh icon and the batch number, the number replaced by an inline
 * progress bar while a refresh runs.
 */
namespace G4 {

    public class AuditionPage : MusicList {
        private Gtk.Button _refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        private Gtk.Label _batch = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private File _audition_dir;
        private HashTable<string, Music> _cache = new HashTable<string, Music> (str_hash, str_equal);
        private bool _loading = false;

        public AuditionPage (Application app) {
            base (app, typeof (Music), null, false);
            _audition_dir = File.new_build_filename (Environment.get_home_dir (), "Music", "audition");

            // Header row: [Refresh icon]  [batch number | progress bar].
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bar.add_css_class ("toolbar");
            _refresh_btn.add_css_class ("flat");
            _refresh_btn.tooltip_text = _("Refresh batch — download the next one");
            _refresh_btn.clicked.connect (on_refresh);
            bar.append (_refresh_btn);
            _batch.add_css_class ("dim-label");
            _batch.halign = Gtk.Align.START;
            _batch.hexpand = true;
            bar.append (_batch);
            _progress.hexpand = true;
            _progress.valign = Gtk.Align.CENTER;
            _progress.visible = false;
            bar.append (_progress);
            prepend (bar);

            item_binded.connect ((item) => {
                ((MusicEntry) item.child).set_titles ((Music) item.item, SortMode.TITLE);
            });
            item_activated.connect ((position, obj) => {
                var playlist = get_as_playlist ();
                _app.current_item = _app.insert_after_current (playlist) + (int) position;
                if (!_app.player.playing)
                    _app.player.play ();
            });

            if (!BangerService.instance.available)
                _refresh_btn.sensitive = false;
            map.connect (() => reload ());
        }

        // Scan ~/Music/audition (off the main thread) and show its tracks.
        private void reload () {
            if (!_loading)
                load_audition.begin ((obj, res) => load_audition.end (res));
        }

        private async void load_audition () {
            _loading = true;
            var found = new GenericArray<Music> ();
            var dir = _audition_dir;
            var cache = _cache;
            yield run_void_async (() => {
                try {
                    var e = dir.enumerate_children (
                        "standard::name,standard::content-type,time::modified",
                        FileQueryInfoFlags.NONE);
                    FileInfo? info = null;
                    while ((info = e.next_file ()) != null) {
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
            found.sort ((a, b) => strcmp (a.uri, b.uri));
            data_store.splice (0, data_store.get_n_items (), (Object[]) found.data);
            _loading = false;
            update_status ();
        }

        private void update_status () {
            BangerService.instance.get_status.begin ((obj, res) => {
                var s = BangerService.instance.get_status.end (res);
                _batch.label = s.batch_number > 0 ? _("Batch #%d").printf (s.batch_number)
                                                  : _("No batch yet");
            });
        }

        private void on_refresh () {
            _refresh_btn.sensitive = false;
            _batch.visible = false;
            _progress.visible = true;
            _progress.show_text = true;
            _progress.fraction = 0;
            _progress.text = _("Starting…");
            var banger = BangerService.instance;
            var id = banger.refresh_progress.connect ((msg, frac) => {
                _progress.text = msg;
                if (frac >= 0)
                    _progress.fraction = frac;
                else
                    _progress.pulse ();
            });
            banger.refresh.begin ((obj, res) => {
                banger.refresh.end (res);
                banger.disconnect (id);
                _progress.visible = false;
                _batch.visible = true;
                _refresh_btn.sensitive = true;
                _cache.remove_all ();   // new batch -> parse fresh
                reload ();
                update_status ();
            });
        }
    }
}
