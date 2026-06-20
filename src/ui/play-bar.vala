namespace G4 {

    public class PlayBar : Gtk.Box {
        private Gtk.Scale _seek = new Gtk.Scale (Gtk.Orientation.HORIZONTAL, null);
        private PeakBar _peak = new PeakBar ();
        private Gtk.Label _positive = new Gtk.Label ("0:00");
        private Gtk.Label _negative = new Gtk.Label ("0:00");
        private Gtk.ToggleButton _repeat = new Gtk.ToggleButton ();
        private Gtk.Button _prev = new Gtk.Button ();
        private Gtk.Button _play = new Gtk.Button ();
        private Gtk.Button _next = new Gtk.Button ();
        private VolumeButton _volume = new VolumeButton ();
        private Gtk.ToggleButton _like = new Gtk.ToggleButton ();
        private Gtk.ToggleButton _dislike = new Gtk.ToggleButton ();
        private int _duration = 0;
        private int _position = 0;
        private bool _remain_progress = false;
        private bool _seeking = false;
        private bool _syncing_rating = false;

        public signal void position_seeked (double position);

        construct {
            orientation = Gtk.Orientation.VERTICAL;

            var app = (Application) GLib.Application.get_default ();
            var player = app.player;

            _seek.set_range (0, _duration);
            _seek.halign = Gtk.Align.FILL;
            append (_seek);
            setup_seek_bar (player);

            var times = new Gtk.CenterBox ();
            times.baseline_position = Gtk.BaselinePosition.CENTER;
            times.halign = Gtk.Align.FILL;
            times.set_start_widget (_positive);
            times.set_end_widget (_negative);

            var overlay = new Gtk.Overlay ();
            overlay.child = times;
            overlay.add_overlay (_peak);
            append (overlay);

            _peak.align = Pango.Alignment.CENTER;
            _peak.halign = Gtk.Align.CENTER;
            _peak.width_request = 168;
            _peak.add_css_class ("dim-label");

            _positive.halign = Gtk.Align.START;
            _positive.margin_start = 12;
            _positive.add_css_class ("dim-label");
            _positive.add_css_class ("numeric");

            _negative.halign = Gtk.Align.END;
            _negative.margin_end = 12;
            _negative.add_css_class ("dim-label");
            _negative.add_css_class ("numeric");

            make_widget_clickable (_negative).pressed.connect (() => remain_progress = !remain_progress);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
            buttons.halign = Gtk.Align.CENTER;
            buttons.margin_top = 16;
            buttons.append (_dislike);
            buttons.append (_repeat);
            buttons.append (_prev);
            buttons.append (_play);
            buttons.append (_next);
            buttons.append (_volume);
            buttons.append (_like);
            append (buttons);

            _repeat.icon_name = "media-playlist-repeat-symbolic";
            _repeat.valign = Gtk.Align.CENTER;
            /* Translators: single loop the current music */
            _repeat.tooltip_text = _("Single Loop");
            _repeat.add_css_class ("flat");
            _repeat.toggled.connect (() => {
                _repeat.icon_name = _repeat.active ? "media-playlist-repeat-song-symbolic" : "media-playlist-repeat-symbolic";
                app.single_loop = ! app.single_loop;
            });

            // banger: Like (👍) / Dislike (👎) the current track. Like copies it to
            // the library; dislike just records it. Mutually exclusive toggles.
            var banger = BangerService.instance;
            _dislike.icon_name = "thumbs-down-symbolic";
            _dislike.valign = Gtk.Align.CENTER;
            _dislike.tooltip_text = _("Dislike");
            _dislike.add_css_class ("flat");
            _dislike.toggled.connect (on_dislike_toggled);

            _like.icon_name = "thumbs-up-symbolic";
            _like.valign = Gtk.Align.CENTER;
            _like.tooltip_text = _("Like");
            _like.add_css_class ("flat");
            _like.toggled.connect (on_like_toggled);

            if (!banger.available) {
                _like.visible = false;
                _dislike.visible = false;
            } else {
                app.music_changed.connect (sync_rating);
                banger.labels_changed.connect (() => sync_rating (app.current_music));
                banger.load_labels.begin ((obj, res) => banger.load_labels.end (res));
                banger.flush_feedback.begin ((obj, res) => banger.flush_feedback.end (res));
            }

            _prev.valign = Gtk.Align.CENTER;
            _prev.action_name = ACTION_APP + ACTION_PREV;
            _prev.icon_name = "media-skip-backward-symbolic";
            _prev.tooltip_text = _("Play Previous");
            _prev.add_css_class ("circular");

            _play.valign = Gtk.Align.CENTER;
            _play.action_name = ACTION_APP + ACTION_PLAY_PAUSE;
            _play.icon_name = "media-playback-start-symbolic"; // media-playback-pause-symbolic
            _play.tooltip_text = _("Play/Pause");
            _play.add_css_class ("circular");
            _play.set_size_request (48, 48);

            _next.valign = Gtk.Align.CENTER;
            _next.action_name = ACTION_APP + ACTION_NEXT;
            _next.icon_name = "media-skip-forward-symbolic";
            _next.tooltip_text = _("Play Next");
            _next.add_css_class ("circular");

            _volume.valign = Gtk.Align.CENTER;
            player.bind_property ("volume", _volume, "value", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

            player.duration_changed.connect (on_duration_changed);
            player.position_updated.connect (on_position_changed);
            player.state_changed.connect (on_state_changed);

            var settings = app.settings;
            settings.bind ("show-peak", _peak, "visible", SettingsBindFlags.DEFAULT);
            settings.bind ("peak-characters", _peak, "characters", SettingsBindFlags.DEFAULT);
            settings.bind ("remain-progress", this, "remain-progress", SettingsBindFlags.DEFAULT);
        }

        public double peak {
            set {
                _peak.peak = value;
            }
        }

        public double position {
            get {
                return _seek.get_value ();
            }
        }

        public bool remain_progress {
            get {
                return _remain_progress;
            }
            set {
                _remain_progress = value;
                update_negative_label ();
            }
        }

        public void on_size_changed (int bar_width, int bar_spacing) {
            var text_width = int.max (_positive.get_width (), _negative.get_width ());
            _peak.width_request = bar_width - (text_width + _positive.margin_start + _negative.margin_end) * 2;
            get_last_child ()?.set_margin_top (bar_spacing);
        }

        private void on_duration_changed (Gst.ClockTime duration) {
            var value = GstPlayer.to_second (duration);
            _duration = (int) (value + 0.5);
            _seek.set_range (0, _duration);
            update_negative_label ();
        }

        private void on_position_changed (Gst.ClockTime position) {
            if (!_seeking) {
                update_position (position);
            }
        }

        private void on_state_changed (Gst.State state) {
            var playing = state == Gst.State.PLAYING;
            _play.icon_name = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
        }

        private void on_like_toggled () {
            if (_syncing_rating)
                return;
            var music = ((Application) GLib.Application.get_default ()).current_music;
            if (music == null)
                return;
            var banger = BangerService.instance;
            if (_like.active) {
                _syncing_rating = true;
                _dislike.active = false;
                _syncing_rating = false;
                banger.like.begin ((!) music, (obj, res) => banger.like.end (res));
            } else {
                banger.unlike.begin ((!) music, (obj, res) => banger.unlike.end (res));
            }
        }

        private void on_dislike_toggled () {
            if (_syncing_rating)
                return;
            var music = ((Application) GLib.Application.get_default ()).current_music;
            if (music == null)
                return;
            var banger = BangerService.instance;
            if (_dislike.active) {
                _syncing_rating = true;
                _like.active = false;
                _syncing_rating = false;
                banger.dislike.begin ((!) music, (obj, res) => banger.dislike.end (res));
            } else {
                banger.set_label.begin (((!) music).uri, Rating.NONE, (obj, res) => banger.set_label.end (res));
            }
        }

        // Reflect the current track's stored rating on the toggles (without firing
        // the toggled handlers).
        private void sync_rating (Music? music) {
            _syncing_rating = true;
            if (music != null) {
                var r = BangerService.instance.rating_for (((!) music).uri);
                _like.active = (r == Rating.LIKE);
                _dislike.active = (r == Rating.DISLIKE);
            } else {
                _like.active = false;
                _dislike.active = false;
            }
            _syncing_rating = false;
        }

        private void setup_seek_bar (GstPlayer player) {
            _seek.change_value.connect ((type, value) => {
                if (_seeking) {
                    position_seeked (value);
                    update_position (GstPlayer.from_second (value));
                    return true;
                }
                return false;
            });

            // Hack that grabs the click gesture controller as mouse released event doesn't work otherwise
            // Bug: https://gitlab.gnome.org/GNOME/gtk/-/issues/4939
            Gtk.GestureClick? click_gesture = null;
            var controllers = _seek.observe_controllers ();
            for (var i = 0; i < controllers.get_n_items (); i++) {
                var controller = controllers.get_item (i);
                if (controller is Gtk.GestureClick) {
                    click_gesture = (Gtk.GestureClick) controller;
                    break;
                }
            }
            if (click_gesture == null) {
                click_gesture = new Gtk.GestureClick ();
                _seek.add_controller ((!)click_gesture);
            }
            var gesture = (!)click_gesture;
            gesture.set_button (0);
            gesture.pressed.connect(() => _seeking = true);
            gesture.released.connect(() => {
                _seeking = false;
                player.seek(GstPlayer.from_second (_seek.get_value ()));
            });
        }

        private void update_negative_label () {
            if (_remain_progress)
                _negative.label = "-" + format_time (_duration - _position);
            else
                _negative.label = format_time (_duration);
        }

        private void update_position (Gst.ClockTime position) {
            var value = GstPlayer.to_second (position);
            if (_position != (int) value) {
                _position = (int) value;
                _positive.label = format_time (_position);
                if (_remain_progress)
                    _negative.label = "-" + format_time (_duration - _position);
            }
            _seek.set_value (value);
        }
    }

    public static string format_time (int seconds) {
        var sb = new StringBuilder ();
        var hours = seconds / 3600;
        var minutes = seconds / 60;
        seconds -= minutes * 60;
        if (hours > 0) {
            minutes -= hours * 60;
            sb.printf ("%d:%02d:%02d", hours, minutes, seconds);
        } else {
            sb.printf ("%d:%02d", minutes, seconds);
        }
        return sb.str;
    }

    public static Gtk.GestureClick make_widget_clickable (Gtk.Widget label) {
        var controller = new Gtk.GestureClick ();
        controller.button = Gdk.BUTTON_PRIMARY;
        label.add_controller (controller);
        label.set_cursor_from_name ("pointer");
        return controller;
    }
}
