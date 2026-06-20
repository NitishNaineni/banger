/*
 * banger — the Discover/Audition page.
 *
 * Shows the current batch status (counts + taste) and a single Refresh button:
 * "I'm done with this batch" clears the audition folder and downloads the next
 * one, streaming progress. All work is delegated to BangerService.
 */
namespace G4 {

    public class DiscoverPage : Gtk.Box {
        private Application _app;
        private Gtk.Label _batch = new Gtk.Label ("");
        private Gtk.Label _counts = new Gtk.Label ("");
        private Gtk.Label _taste = new Gtk.Label ("");
        private Gtk.Button _refresh = new Gtk.Button ();
        private Gtk.Spinner _spinner = new Gtk.Spinner ();
        private Gtk.Label _progress = new Gtk.Label ("");
        private Gtk.Box _progress_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        private Gtk.Label _notice = new Gtk.Label ("");

        public DiscoverPage (Application app) {
            _app = app;
            orientation = Gtk.Orientation.VERTICAL;
            spacing = 14;
            halign = Gtk.Align.CENTER;
            valign = Gtk.Align.CENTER;
            margin_top = 24;
            margin_bottom = 24;
            margin_start = 24;
            margin_end = 24;

            var title = new Gtk.Label (_("Discover"));
            title.add_css_class ("title-1");
            append (title);

            _batch.add_css_class ("dim-label");
            append (_batch);

            _counts.add_css_class ("title-4");
            append (_counts);

            _taste.wrap = true;
            _taste.justify = Gtk.Justification.CENTER;
            _taste.max_width_chars = 42;
            _taste.add_css_class ("dim-label");
            append (_taste);

            _refresh.label = _("Refresh Batch");
            _refresh.halign = Gtk.Align.CENTER;
            _refresh.margin_top = 6;
            _refresh.add_css_class ("suggested-action");
            _refresh.add_css_class ("pill");
            _refresh.tooltip_text = _("Clear this batch and download the next one");
            _refresh.clicked.connect (on_refresh_clicked);
            append (_refresh);

            _spinner.valign = Gtk.Align.CENTER;
            _progress.add_css_class ("dim-label");
            _progress_box.halign = Gtk.Align.CENTER;
            _progress_box.append (_spinner);
            _progress_box.append (_progress);
            _progress_box.visible = false;
            append (_progress_box);

            _notice.wrap = true;
            _notice.justify = Gtk.Justification.CENTER;
            _notice.max_width_chars = 46;
            _notice.add_css_class ("dim-label");
            _notice.visible = false;
            append (_notice);

            map.connect (refresh_status);
        }

        private void set_busy (bool busy) {
            _refresh.sensitive = !busy;
            _progress_box.visible = busy;
            if (busy)
                _spinner.start ();
            else
                _spinner.stop ();
        }

        private void on_refresh_clicked () {
            set_busy (true);
            _progress.label = _("Starting…");
            var banger = BangerService.instance;
            var id = banger.refresh_progress.connect ((msg) => _progress.label = msg);
            banger.refresh.begin ((obj, res) => {
                banger.refresh.end (res);
                banger.disconnect (id);
                set_busy (false);
                _app.reload_library ();
                refresh_status ();
            });
        }

        private void refresh_status () {
            BangerService.instance.get_status.begin ((obj, res) => {
                update (BangerService.instance.get_status.end (res));
            });
        }

        private void update (BangerStatus s) {
            _batch.label = s.batch_number > 0
                ? _("Batch #%d · %d in audition").printf (s.batch_number, s.audition_count)
                : _("No batch yet");
            _counts.label = _("%d liked · %d disliked").printf (s.liked, s.disliked);
            _taste.visible = s.taste.length > 0;
            _taste.label = s.taste.length > 0 ? _("Your taste: %s").printf (s.taste) : "";

            if (!BangerService.instance.available) {
                _notice.visible = true;
                _notice.label = _("The banger sidecar wasn't found. Set BANGER_HOME or install it.");
                _refresh.sensitive = false;
            } else if (!s.configured) {
                _notice.visible = true;
                _notice.label = _("Add your ListenBrainz token (and Deezer ARL) to ~/.config/banger/config.toml.");
            } else {
                _notice.visible = false;
            }
        }
    }
}
