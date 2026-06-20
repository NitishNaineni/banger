/*
 * banger — the Audition tab.
 *
 * A self-scanning list of the current batch (~/Music/audition) with a header:
 * a Refresh icon, the batch number + song count, and (while a batch downloads)
 * an inline progress bar with n/total · ETA · current track.
 */
namespace G4 {

    public class AuditionPage : FolderList {
        private Gtk.Button _refresh = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        private Gtk.Label _info = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();
        private int _batch = 0;
        private int64 _start = 0;

        public AuditionPage (Application app) {
            base (app, File.new_build_filename (Environment.get_home_dir (), "Music", "audition"));
            sort_order = SortMode.TITLE;

            var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
            header.add_css_class ("toolbar");
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            _refresh.add_css_class ("flat");
            _refresh.tooltip_text = _("Refresh batch — download the next one");
            _refresh.clicked.connect (on_refresh);
            row.append (_refresh);
            _info.add_css_class ("dim-label");
            _info.halign = Gtk.Align.START;
            _info.hexpand = true;
            _info.ellipsize = Pango.EllipsizeMode.END;
            row.append (_info);
            header.append (row);
            _progress.show_text = true;
            _progress.ellipsize = Pango.EllipsizeMode.END;
            _progress.visible = false;
            header.append (_progress);
            prepend (header);

            if (!BangerService.instance.available)
                _refresh.sensitive = false;
            reloaded.connect ((n) => set_info (n));
            map.connect (update_info);
        }

        private void update_info () {
            BangerService.instance.get_status.begin ((obj, res) => {
                var s = BangerService.instance.get_status.end (res);
                _batch = s.batch_number;
                set_info (data_store.get_n_items ());
            });
        }

        private void set_info (uint count) {
            _info.label = _batch > 0
                ? _("Batch #%d   ·   %u songs").printf (_batch, count)
                : _("No batch yet");
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
            _info.visible = false;
            _progress.visible = true;
            _progress.fraction = 0;
            _progress.text = _("Starting…");
            _start = GLib.get_monotonic_time ();
            var banger = BangerService.instance;
            var id = banger.refresh_progress.connect ((msg, done, total) => {
                if (total > 0) {
                    _progress.fraction = (double) done / total;
                    var eta = "";
                    if (done > 0) {
                        var elapsed = (GLib.get_monotonic_time () - _start) / 1e6;
                        eta = "   ·   " + format_eta (elapsed * (total - done) / done);
                    }
                    _progress.text = @"$done/$total$eta   ·   $msg";
                } else {
                    _progress.pulse ();
                    _progress.text = msg;
                }
            });
            banger.refresh.begin ((obj, res) => {
                banger.refresh.end (res);
                banger.disconnect (id);
                _progress.visible = false;
                _info.visible = true;
                _refresh.sensitive = true;
                reload ();
                update_info ();
            });
        }
    }
}
