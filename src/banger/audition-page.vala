/*
 * banger — the Audition page.
 *
 * A self-contained MusicList that lists the current audition batch (the tracks
 * in ~/Music/audition) and plays them, with a header holding a Refresh button +
 * progress bar. Refresh clears the batch and downloads the next one; like/dislike
 * happen on the play bar. All work is delegated to BangerService.
 */
namespace G4 {

    public class AuditionPage : MusicList {
        private Gtk.Button _refresh_btn = new Gtk.Button.with_label (_("Refresh"));
        private Gtk.Label _status = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private string _audition_uri;

        public AuditionPage (Application app) {
            base (app, typeof (Music), null, false);
            _audition_uri = File.new_build_filename (
                Environment.get_home_dir (), "Music", "audition").get_uri () + "/";

            // Header: a toolbar row (Refresh + status) and a progress bar, above the list.
            var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bar.add_css_class ("toolbar");
            _refresh_btn.add_css_class ("suggested-action");
            _refresh_btn.tooltip_text = _("Clear this batch and download the next one");
            _refresh_btn.clicked.connect (on_refresh);
            bar.append (_refresh_btn);
            _status.add_css_class ("dim-label");
            _status.hexpand = true;
            _status.halign = Gtk.Align.START;
            _status.ellipsize = Pango.EllipsizeMode.END;
            bar.append (_status);
            header.append (bar);
            _progress.visible = false;
            header.append (_progress);
            prepend (header);

            item_binded.connect ((item) => {
                ((MusicEntry) item.child).set_titles ((Music) item.item, SortMode.TITLE);
            });
            item_activated.connect ((position, obj) => {
                var playlist = get_as_playlist ();
                _app.current_item = _app.insert_after_current (playlist) + (int) position;
                if (!_app.player.playing)
                    _app.player.play ();
            });

            if (BangerService.instance.available)
                _app.music_library_changed.connect ((external) => reload ());
            else
                _refresh_btn.sensitive = false;

            map.connect (() => { reload (); });
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
                var sb = new StringBuilder ();
                if (s.batch_number > 0)
                    sb.append_printf (_("Batch #%d   ·   "), s.batch_number);
                sb.append_printf (_("%u songs   ·   %d liked   ·   %d disliked"),
                                  data_store.get_n_items (), s.liked, s.disliked);
                if (!s.configured)
                    sb.append (_("   ·   add your token to ~/.config/banger/config.toml"));
                _status.label = sb.str;
            });
        }

        private void on_refresh () {
            _refresh_btn.sensitive = false;
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
                _refresh_btn.sensitive = true;
                _app.reload_library ();   // rescans -> music_library_changed -> reload ()
                update_status ();
            });
        }
    }
}
