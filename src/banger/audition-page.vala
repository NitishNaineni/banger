/*
 * banger — the Audition page.
 *
 * Deliberately simple: the batch number + a live song count, a Refresh button,
 * and (while a batch downloads) a progress bar with "n/total · ETA" and the
 * current track. Tracks load into the app the moment they finish downloading,
 * so the count ticks up live.
 */
namespace G4 {

    public class AuditionPage : Gtk.Box {
        private Application _app;
        private Gtk.Button _refresh = new Gtk.Button.with_label (_("Refresh Batch"));
        private Gtk.Label _status = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private Gtk.Label _track = new Gtk.Label ("");
        private string _audition_uri;
        private int _batch_number = 0;
        private int _song_count = 0;
        private bool _configured = true;
        private int64 _start_time = 0;

        public AuditionPage (Application app) {
            _app = app;
            _audition_uri = File.new_build_filename (
                Environment.get_home_dir (), "Music", "audition").get_uri () + "/";

            orientation = Gtk.Orientation.VERTICAL;
            spacing = 14;
            halign = Gtk.Align.CENTER;
            valign = Gtk.Align.CENTER;

            var title = new Gtk.Label (_("Audition"));
            title.halign = Gtk.Align.CENTER;
            title.add_css_class ("title-1");
            append (title);

            _status.halign = Gtk.Align.CENTER;
            _status.add_css_class ("dim-label");
            append (_status);

            _refresh.halign = Gtk.Align.CENTER;
            _refresh.margin_top = 4;
            _refresh.add_css_class ("suggested-action");
            _refresh.add_css_class ("pill");
            _refresh.tooltip_text = _("Clear this batch and download the next one");
            _refresh.clicked.connect (on_refresh);
            if (!BangerService.instance.available)
                _refresh.sensitive = false;
            append (_refresh);

            _progress.halign = Gtk.Align.CENTER;
            _progress.width_request = 300;
            _progress.show_text = true;
            _progress.visible = false;
            append (_progress);

            _track.halign = Gtk.Align.CENTER;
            _track.max_width_chars = 36;
            _track.ellipsize = Pango.EllipsizeMode.END;
            _track.add_css_class ("dim-label");
            _track.visible = false;
            append (_track);

            _app.music_library_changed.connect ((external) => update_count ());
            map.connect (() => { update_batch (); update_count (); });
        }

        private void rebuild_status () {
            if (_batch_number > 0)
                _status.label = _("Batch #%d   ·   %d songs").printf (_batch_number, _song_count);
            else
                _status.label = _("No batch yet");
            if (!_configured)
                _status.label += _("   ·   add your token to ~/.config/banger/config.toml");
        }

        // Count the audition tracks currently loaded in the app (cheap, live).
        private void update_count () {
            var queue = _app.music_queue;
            var n = queue.get_n_items ();
            var c = 0;
            for (uint i = 0; i < n; i++) {
                if (((Music) queue.get_item (i)).uri.has_prefix (_audition_uri))
                    c++;
            }
            _song_count = c;
            rebuild_status ();
        }

        private void update_batch () {
            BangerService.instance.get_status.begin ((obj, res) => {
                var s = BangerService.instance.get_status.end (res);
                _batch_number = s.batch_number;
                _configured = s.configured;
                rebuild_status ();
            });
        }

        private string format_eta (double seconds) {
            var s = (int) (seconds + 0.5);
            if (s >= 3600)
                return _("~%dh %dm left").printf (s / 3600, (s % 3600) / 60);
            if (s >= 60)
                return _("~%dm %ds left").printf (s / 60, s % 60);
            return _("~%ds left").printf (int.max (s, 1));
        }

        private void on_refresh () {
            _refresh.sensitive = false;
            _progress.visible = true;
            _progress.fraction = 0;
            _progress.text = _("Starting…");
            _track.visible = false;
            _start_time = GLib.get_monotonic_time ();
            var banger = BangerService.instance;
            var id = banger.refresh_progress.connect ((msg, done, total) => {
                if (total > 0) {
                    _progress.fraction = (double) done / total;
                    var eta = "";
                    if (done > 0) {
                        var elapsed = (GLib.get_monotonic_time () - _start_time) / 1e6;
                        eta = "   ·   " + format_eta (elapsed * (total - done) / done);
                    }
                    _progress.text = @"$done/$total$eta";
                    _track.label = msg;
                    _track.visible = true;
                } else {
                    _progress.pulse ();
                    _progress.text = msg;
                    _track.visible = false;
                }
            });
            banger.refresh.begin ((obj, res) => {
                banger.refresh.end (res);
                banger.disconnect (id);
                _progress.visible = false;
                _track.visible = false;
                _refresh.sensitive = true;
                _app.reload_library ();   // load the Audition / Library playlists
                update_batch ();
            });
        }
    }
}
