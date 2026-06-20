/*
 * banger — the Audition page.
 *
 * Deliberately simple: the batch number and a single Refresh button, plus a
 * progress bar (with the current track) while a batch downloads. The actual
 * tracks live in the "Audition" playlist; each one is loaded into the app the
 * moment it finishes downloading, so you can watch them appear.
 */
namespace G4 {

    public class AuditionPage : Gtk.Box {
        private Application _app;
        private Gtk.Button _refresh = new Gtk.Button.with_label (_("Refresh Batch"));
        private Gtk.Label _status = new Gtk.Label ("");
        private Gtk.ProgressBar _progress = new Gtk.ProgressBar ();

        public AuditionPage (Application app) {
            _app = app;
            orientation = Gtk.Orientation.VERTICAL;
            spacing = 18;
            halign = Gtk.Align.CENTER;
            valign = Gtk.Align.CENTER;
            margin_top = 24;
            margin_bottom = 24;
            margin_start = 24;
            margin_end = 24;
            width_request = 380;

            var title = new Gtk.Label (_("Audition"));
            title.add_css_class ("title-1");
            append (title);

            _status.add_css_class ("dim-label");
            append (_status);

            _refresh.halign = Gtk.Align.CENTER;
            _refresh.add_css_class ("suggested-action");
            _refresh.add_css_class ("pill");
            _refresh.tooltip_text = _("Clear this batch and download the next one");
            _refresh.clicked.connect (on_refresh);
            if (!BangerService.instance.available)
                _refresh.sensitive = false;
            append (_refresh);

            _progress.ellipsize = Pango.EllipsizeMode.END;
            _progress.show_text = true;
            _progress.visible = false;
            append (_progress);

            map.connect (update_status);
        }

        private void update_status () {
            BangerService.instance.get_status.begin ((obj, res) => {
                var s = BangerService.instance.get_status.end (res);
                if (s.batch_number > 0)
                    _status.label = _("Batch #%d   ·   %d songs").printf (s.batch_number, s.audition_count);
                else
                    _status.label = _("No batch yet");
                if (!s.configured)
                    _status.label += _("   ·   add your token to ~/.config/banger/config.toml");
            });
        }

        private void on_refresh () {
            _refresh.sensitive = false;
            _progress.visible = true;
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
                _refresh.sensitive = true;
                _app.reload_library ();   // load the Audition / Library playlists
                update_status ();
            });
        }
    }
}
