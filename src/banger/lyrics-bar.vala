/*
 * banger — karaoke lyrics: the current line plus the upcoming lines, smoothly
 * scrolling, with a smooth word-by-word fill.
 *
 * Every lyric line gets its own label stacked in a non-scrolling (clipped)
 * ScrolledWindow. As the song advances the scroll position is animated so the new
 * current line glides up to the top (current + upcoming always in view, never the
 * previous). On the current line each word brightens *smoothly* as it's sung: a
 * per-frame tick interpolates the playback position between the player's 100ms
 * updates and fades each word from dim to full across its own duration, so it reads
 * like a karaoke fill rather than words snapping on. It fills the vertical space it's
 * given (minimum the original 3-line block) and clips the rest.
 */
namespace G4 {

    public class LyricsBar : Gtk.Box {

        private class LyricLine {
            public double time;
            public double[] wtimes;
            public string[] words;
            public string text;
        }

        private Gtk.ScrolledWindow _scroll = new Gtk.ScrolledWindow ();
        private Gtk.Box _box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        private GenericArray<LyricLine> _lines = new GenericArray<LyricLine> ();
        private GenericArray<Gtk.Label> _line_labels = new GenericArray<Gtk.Label> ();
        private int _active = -2;
        private Adw.TimedAnimation? _scroll_anim = null;
        private double _anchor_pos = 0;          // last known playback position (s)
        private int64 _anchor_mono = 0;          // monotonic time when it was set
        private bool _playing = false;
        private uint _tick_id = 0;
        private string _fill_cache = "";

        construct {
            orientation = Gtk.Orientation.VERTICAL;
            hexpand = true;
            vexpand = true;
            // EXTERNAL hides the scrollbar but still CLIPS to the viewport (NEVER would
            // instead grow the viewport to fit every line and push the buttons offscreen).
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vscrollbar_policy = Gtk.PolicyType.EXTERNAL;
            _scroll.propagate_natural_height = false;
            _scroll.vexpand = true;
            _scroll.min_content_height = 84;     // minimum the original 3-line block
            _box.valign = Gtk.Align.START;
            _box.hexpand = true;
            _box.margin_top = 2;
            _box.margin_bottom = 2;
            _scroll.child = _box;
            append (_scroll);

            ensure_css ();

            var app = (Application) GLib.Application.get_default ();
            _playing = app.player.state == Gst.State.PLAYING;
            app.player.state_changed.connect ((state) => {
                _playing = (state == Gst.State.PLAYING);
                update_tick ();
            });
        }

        // Load the lyrics for `music` from its sibling .lrc sidecar (same basename).
        // Library copies may lack the sidecar, so fall back to the audition folder.
        public void load_for (Music? music) {
            _scroll_anim?.pause ();
            _scroll_anim = null;
            _lines = new GenericArray<LyricLine> ();
            _line_labels = new GenericArray<Gtk.Label> ();
            _active = -2;
            _fill_cache = "";
            clear_box ();
            if (music == null) {
                add_placeholder ();
                update_tick ();
                return;
            }
            var path = File.new_for_uri (((!) music).uri).get_path ();
            string? contents = (path != null) ? read_embedded_lyrics ((!) path) : null;
            if (contents == null) {
                add_placeholder ();
                update_tick ();
                return;
            }
            parse ((!) contents);
            if (_lines.length == 0) {
                add_placeholder ();
                update_tick ();
                return;
            }
            for (int i = 0; i < _lines.length; i++) {
                var l = make_label ();
                l.set_text (_lines.get (i).text);
                l.opacity = 0.35;
                _box.append (l);
                _line_labels.add (l);
            }
            _scroll.vadjustment.value = 0;
            update_tick ();
        }

        private void clear_box () {
            var c = _box.get_first_child ();
            while (c != null) {
                _box.remove ((!) c);
                c = _box.get_first_child ();
            }
        }

        private static bool _css_done = false;
        private static void ensure_css () {
            if (_css_done)
                return;
            _css_done = true;
            var css = new Gtk.CssProvider ();
            css.load_from_string (".lyrics-line { font-size: 1.15em; font-weight: bold; }");
            Gtk.StyleContext.add_provider_for_display ((!) Gdk.Display.get_default (),
                css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private Gtk.Label make_label () {
            var l = new Gtk.Label ("");
            l.halign = Gtk.Align.FILL;
            l.hexpand = true;
            l.xalign = 0.5f;
            l.justify = Gtk.Justification.CENTER;
            l.wrap = true;
            l.wrap_mode = Pango.WrapMode.WORD_CHAR;
            l.lines = 2;
            l.ellipsize = Pango.EllipsizeMode.END;
            l.margin_start = 12;
            l.margin_end = 12;
            l.add_css_class ("lyrics-line");   // size between heading and title-4
            return l;
        }

        private void add_placeholder () {
            clear_box ();
            var l = make_label ();
            l.set_markup ("<span alpha=\"35%\">♪</span>");
            _box.append (l);
        }

        // Re-anchor the playback position from the player's (100ms) updates. Both the
        // line switch and the word fill are driven by `update`, off the interpolated time
        // in the tick — so a new line's first words light on time instead of waiting up to
        // 100ms for the next player update.
        public void set_position (double t) {
            if (_lines.length == 0)
                return;
            _anchor_pos = t;
            _anchor_mono = get_monotonic_time ();
            update (t);
            update_tick ();
        }

        private void update (double t) {
            if (_lines.length == 0)
                return;
            int active = -1;
            for (int i = 0; i < _lines.length; i++) {
                if (_lines.get (i).time <= t)
                    active = i;
                else
                    break;
            }
            if (active < 0)
                active = 0;
            if (active != _active) {
                if (_active >= 0 && _active < _line_labels.length) {
                    _line_labels.get (_active).set_text (_lines.get (_active).text);
                    _line_labels.get (_active).opacity = 0.35;
                }
                bool fresh = (_active == -2);
                _active = active;
                _fill_cache = "";
                scroll_to (active, !fresh);
            }
            render_fill (t);
        }

        // Smoothly fill the current line: each word fades dim -> full across its own
        // span (its start time to the next word's start time).
        private void render_fill (double t) {
            if (_active < 0 || _active >= _line_labels.length)
                return;
            const double FADE = 0.2;   // every word eases in over the same 0.2s
            var line = _lines.get (_active);
            var sb = new StringBuilder ();
            for (int i = 0; i < line.words.length; i++) {
                double s = line.wtimes[i];
                int alpha;
                if (t < s) {
                    alpha = 45;
                } else {
                    double p = ((t - s) / FADE).clamp (0, 1);
                    p = p * p * (3 - 2 * p);   // smoothstep ease
                    alpha = 45 + (int) (55 * p);
                }
                sb.append ("<span alpha=\"").append (alpha.to_string ()).append ("%\">");
                sb.append (Markup.escape_text (line.words[i]));
                sb.append ("</span>");
            }
            var markup = sb.str;
            if (markup != _fill_cache) {
                _fill_cache = markup;
                var cur = _line_labels.get (_active);
                cur.set_markup (markup);
                cur.opacity = 1.0;
            }
        }

        // Run the per-frame interpolation only while it can matter (playing + lyrics).
        private void update_tick () {
            bool want = _playing && _lines.length > 0;
            if (want && _tick_id == 0) {
                _tick_id = add_tick_callback (on_tick);
            } else if (!want && _tick_id != 0) {
                remove_tick_callback (_tick_id);
                _tick_id = 0;
            }
        }

        private bool on_tick (Gtk.Widget widget, Gdk.FrameClock clock) {
            double t = _anchor_pos;
            if (_playing)
                t += (get_monotonic_time () - _anchor_mono) / 1e6;
            update (t);
            return Source.CONTINUE;
        }

        // Soft-fade the top and bottom edges so lines scroll in/out gently. We mask the
        // content with a vertical alpha gradient (transparent at the very edges) — it's
        // background-independent, unlike painting the bg colour over the content.
        public override void snapshot (Gtk.Snapshot snapshot) {
            int h = get_height ();
            int w = get_width ();
            if (h <= 0 || w <= 0) {
                base.snapshot (snapshot);
                return;
            }
            // Fade only as much as there is content scrolled off each edge, so the very
            // first line (nothing above) and the last line (nothing below) aren't dimmed.
            // Cap the fade smaller on short blocks so a wrapped 2-row line isn't eaten.
            var adj = _scroll.vadjustment;
            float above = (float) adj.value;
            float below = (float) double.max (adj.upper - adj.page_size - adj.value, 0);
            float ft_max = h * 0.15f < 22f ? h * 0.15f : 22f;
            float fb_max = h * 0.18f < 30f ? h * 0.18f : 30f;
            float ft = above < ft_max ? above : ft_max;
            float fb = below < fb_max ? below : fb_max;
            if (ft < 1f && fb < 1f) {
                base.snapshot (snapshot);
                return;
            }
            var clear = Gdk.RGBA () { red = 1f, green = 1f, blue = 1f, alpha = 0f };
            var solid = Gdk.RGBA () { red = 1f, green = 1f, blue = 1f, alpha = 1f };
            float ft_off = (ft >= 1f ? ft : 1f) / h;
            float fb_off = (fb >= 1f ? fb : 1f) / h;
            Gsk.ColorStop[] stops = {
                Gsk.ColorStop () { offset = 0f, color = ft >= 1f ? clear : solid },
                Gsk.ColorStop () { offset = ft_off, color = solid },
                Gsk.ColorStop () { offset = 1f - fb_off, color = solid },
                Gsk.ColorStop () { offset = 1f, color = fb >= 1f ? clear : solid }
            };
            var rect = Graphene.Rect ();
            rect.init (0, 0, (float) w, (float) h);
            var p0 = Graphene.Point ();
            p0.init (0, 0);
            var p1 = Graphene.Point ();
            p1.init (0, (float) h);
            snapshot.push_mask (Gsk.MaskMode.ALPHA);
            snapshot.append_linear_gradient (rect, p0, p1, stops);
            snapshot.pop ();
            base.snapshot (snapshot);
            snapshot.pop ();
        }

        // Animate the scroll so line `index` sits at the top of the viewport.
        private void scroll_to (int index, bool animate) {
            if (index < 0 || index >= _line_labels.length)
                return;
            var label = _line_labels.get (index);
            var origin = Graphene.Point ();
            origin.init (0, 0);
            Graphene.Point pt;
            if (!label.compute_point (_box, origin, out pt))
                return;
            var adj = _scroll.vadjustment;
            // sit the current line just below the top fade so it stays fully bright (the
            // line above fades out in the masked zone).
            double target = ((double) pt.y - 24).clamp (0, double.max (adj.upper - adj.page_size, 0));
            _scroll_anim?.pause ();
            if (!animate) {
                adj.value = target;
                return;
            }
            var tgt = new Adw.CallbackAnimationTarget ((v) => adj.value = v);
            _scroll_anim = new Adw.TimedAnimation (this, adj.value, target, 450, tgt);
            ((!) _scroll_anim).easing = Adw.Easing.EASE_OUT_CUBIC;
            ((!) _scroll_anim).play ();
        }

        // Read the enhanced-LRC lyrics straight from the FLAC's LYRICS vorbis comment —
        // no sidecar files. Parses the metadata blocks directly so a big PICTURE block is
        // skipped (seeked past) rather than read.
        private string? read_embedded_lyrics (string path) {
            if (!path.down ().has_suffix (".flac"))
                return null;
            try {
                var stream = new DataInputStream (File.new_for_path (path).read ());
                var magic = new uint8[4];
                size_t got;
                stream.read_all (magic, out got);
                if (got < 4 || magic[0] != 'f' || magic[1] != 'L' || magic[2] != 'a' || magic[3] != 'C')
                    return null;
                bool last = false;
                while (!last) {
                    var hdr = new uint8[4];
                    stream.read_all (hdr, out got);
                    if (got < 4)
                        break;
                    last = (hdr[0] & 0x80) != 0;
                    int type = hdr[0] & 0x7f;
                    uint32 size = ((uint32) hdr[1] << 16) | ((uint32) hdr[2] << 8) | hdr[3];
                    if (type == 4) {   // VORBIS_COMMENT
                        var block = new uint8[size];
                        stream.read_all (block, out got);
                        return got < size ? null : extract_vorbis_lyrics (block);
                    }
                    stream.skip (size);
                }
            } catch (Error e) {
            }
            return null;
        }

        private static string? extract_vorbis_lyrics (uint8[] b) {
            int pos = 0;
            if (b.length < 8)
                return null;
            uint32 vlen = le32 (b, 0);
            pos = 4 + (int) vlen;
            if (pos + 4 > b.length)
                return null;
            uint32 count = le32 (b, pos);
            pos += 4;
            for (uint32 i = 0; i < count; i++) {
                if (pos + 4 > b.length)
                    break;
                int clen = (int) le32 (b, pos);
                pos += 4;
                if (clen < 0 || pos + clen > b.length)
                    break;
                var cb = b[pos : pos + clen];
                cb += 0;   // null-terminate
                unowned string comment = (string) cb;
                var eq = comment.index_of_char ('=');
                if (eq == 6 && comment.substring (0, 6).up () == "LYRICS")
                    return comment.substring (7);
                pos += clen;
            }
            return null;
        }

        private static uint32 le32 (uint8[] b, int p) {
            return b[p] | ((uint32) b[p + 1] << 8) | ((uint32) b[p + 2] << 16) | ((uint32) b[p + 3] << 24);
        }

        private void parse (string contents) {
            foreach (unowned var raw in contents.split ("\n")) {
                var line = raw.chomp ();
                if (!line.has_prefix ("["))
                    continue;
                var close = line.index_of ("]");
                if (close < 1)
                    continue;
                var ts = line.substring (1, close - 1);
                if (ts.length == 0 || !ts[0].isdigit ())
                    continue;
                double lt = parse_ts (ts);
                if (lt < 0)
                    continue;
                var rest = line.substring (close + 1);

                var entry = new LyricLine ();
                entry.time = lt;
                double[] wt = {};
                string[] wd = {};
                if (rest.index_of ("<") >= 0) {
                    foreach (unowned var part in rest.split ("<")) {
                        var gt = part.index_of (">");
                        if (gt < 0)
                            continue;
                        double w = parse_ts (part.substring (0, gt));
                        if (w < 0)
                            continue;
                        wt += w;
                        wd += part.substring (gt + 1);
                    }
                } else {
                    var text = rest.strip ();
                    if (text.length == 0)
                        continue;
                    wt += lt;
                    wd += text;
                }
                if (wd.length == 0)
                    continue;
                entry.wtimes = wt;
                entry.words = wd;
                entry.text = string.joinv ("", wd).strip ();
                _lines.add (entry);
            }
        }

        // "mm:ss.xx" / "mm:ss.xxx" / "mm:ss" -> seconds. -1 if malformed.
        private static double parse_ts (string s) {
            var colon = s.index_of (":");
            if (colon < 1)
                return -1;
            int mm = int.parse (s.substring (0, colon));
            var rest = s.substring (colon + 1);
            var dot = rest.index_of (".");
            if (dot < 0)
                return mm * 60.0 + int.parse (rest);
            int sec = int.parse (rest.substring (0, dot));
            var fp = rest.substring (dot + 1);
            double frac = fp.length > 0 ? int.parse (fp) / Math.pow (10, fp.length) : 0;
            return mm * 60.0 + sec + frac;
        }
    }
}
