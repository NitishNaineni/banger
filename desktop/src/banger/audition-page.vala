/*
 * banger — the Audition tab.
 *
 * A clean, self-scanning list of the current batch (~/Music/audition). Refresh
 * lives in the top bar (added by the store-panel); while a batch downloads, a
 * status block sized exactly like a song row appears at the top of the list with
 * a spinner, the current track, a progress bar and ETA.
 */
namespace G4 {

    public class AuditionPage : FolderList {
        private Gtk.Box _status = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        private Gtk.Spinner _spinner = new Gtk.Spinner ();
        private Gtk.Label _title = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private int64 _start = 0;
        private bool _refreshing = false;

        public bool refreshing { get { return _refreshing; } }
        public signal void refreshing_changed (bool running);

        public AuditionPage (Application app) {
            base (app, File.new_build_filename (Environment.get_home_dir (), "Music", "audition"), "audition-sort");

            // A status block matching a song row: [48px spinner] [title + progress].
            _spinner.set_size_request (48, 48);
            _spinner.margin_top = _spinner.margin_bottom = 4;
            _spinner.margin_start = 4;
            _status.append (_spinner);
            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
            vbox.margin_start = 12;
            vbox.margin_end = 12;
            vbox.hexpand = true;
            vbox.valign = Gtk.Align.CENTER;
            _title.halign = Gtk.Align.START;
            _title.ellipsize = Pango.EllipsizeMode.END;
            _title.add_css_class ("heading");
            vbox.append (_title);
            _progress.show_text = true;
            _progress.ellipsize = Pango.EllipsizeMode.END;
            vbox.append (_progress);
            _status.append (vbox);
            _status.visible = false;
            prepend (_status);
        }

        private string format_eta (double seconds) {
            var s = (int) (seconds + 0.5);
            if (s >= 3600)
                return _("~%dh %dm left").printf (s / 3600, (s % 3600) / 60);
            if (s >= 60)
                return _("~%dm %ds left").printf (s / 60, s % 60);
            return _("~%ds left").printf (int.max (s, 1));
        }

        // Download the next batch (driven from the top-bar Refresh button).
        public void refresh () {
            var banger = BangerService.instance;
            if (_refreshing || !banger.available)
                return;
            _refreshing = true;
            refreshing_changed (true);   // owner stops audition playback + clears the queue
            // Empty the list AND ignore rescans until the new batch starts landing, so
            // the old (not-yet-deleted) files can't repopulate during make_batch/clear.
            suppress_updates = true;
            data_store.remove_all ();
            _spinner.start ();
            _status.visible = true;
            _progress.fraction = 0;
            _title.label = _("Refreshing batch…");
            _progress.text = _("Starting…");
            _start = GLib.get_monotonic_time ();

            var id = banger.refresh_progress.connect ((msg, done, total) => {
                _title.label = msg;
                if (total > 0) {
                    suppress_updates = false;   // download phase: old files are gone, show new ones live
                    _progress.fraction = (double) done / total;
                    var eta = "";
                    if (done > 0) {
                        var elapsed = (GLib.get_monotonic_time () - _start) / 1e6;
                        eta = "   ·   " + format_eta (elapsed * (total - done) / done);
                    }
                    _progress.text = @"$done / $total$eta";
                    reload ();   // surface downloaded tracks live
                } else {
                    _progress.pulse ();
                    _progress.text = "";
                }
            });
            banger.refresh.begin ((obj, res) => {
                banger.refresh.end (res);
                banger.disconnect (id);
                _spinner.stop ();
                _status.visible = false;
                _refreshing = false;
                refreshing_changed (false);
                suppress_updates = false;   // done — let the final state show
                reload ();
            });
        }
    }
}
