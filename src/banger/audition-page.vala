/*
 * banger — the Audition page.
 *
 * A self-contained MusicList that lists the current audition batch (the tracks
 * in ~/Music/audition) and plays them. Its header is a single row: a Refresh
 * icon and, beside it, the batch number — replaced by an inline progress bar
 * while a refresh runs. Like/dislike happen on the play bar.
 */
namespace G4 {

    public class AuditionPage : MusicList {
        private Gtk.Button _refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        private Gtk.Label _batch = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private string _audition_uri;

        public AuditionPage (Application app) {
            base (app, typeof (Music), null, false);
            _audition_uri = File.new_build_filename (
                Environment.get_home_dir (), "Music", "audition").get_uri () + "/";

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
            _app.music_library_changed.connect ((external) => reload ());
            map.connect (() => reload ());
        }

        // Repopulate the list from the tracks currently under ~/Music/audition.
        private void reload () {
            var queue = _app.music_queue;
            var items = new GenericArray<Music> ();
            var n = queue.get_n_items ();
            for (uint i = 0; i < n; i++) {
                var m = (Music) queue.get_item (i);
                if (m.uri.has_prefix (_audition_uri))
                    items.add (m);
            }
            items.sort ((a, b) => strcmp (a.uri, b.uri));
            data_store.splice (0, data_store.get_n_items (), (Object[]) items.data);
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
                _app.reload_library ();   // single-threaded rescan -> reload ()
                update_status ();
            });
        }
    }
}
