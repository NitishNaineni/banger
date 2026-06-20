/*
 * banger — discovery-loop integration for G4Music.
 *
 * BangerService drives the bundled Python pipeline (banger/scripts/banger_api.py)
 * via `uv run` and exposes its tab-separated output to the rest of the app. All
 * banger logic lives here (and in the Python sidecar); upstream files only call in.
 *
 * Like  = copy the audition track into ~/Music/library (it now lives in both).
 * Unlike/Dislike = remove the library copy (audition copy is never touched).
 * Only Refresh ever clears the audition folder.
 */
namespace G4 {

    public enum Rating {
        NONE, LIKE, DISLIKE
    }

    public class BangerStatus : Object {
        public bool configured = false;
        public int batch_number = 0;
        public bool downloaded = false;
        public int total_seen = 0;
        public int audition_count = 0;
        public int library_count = 0;
        public int liked = 0;
        public int disliked = 0;
        public int pending = 0;
        public string taste = "";
    }

    public class BangerService : Object {
        private static BangerService? _instance = null;
        public static unowned BangerService instance {
            get {
                if (_instance == null)
                    _instance = new BangerService ();
                return (!) _instance;
            }
        }

        private string _home;
        private string _uv;
        private string _script;
        private HashTable<string, string> _labels = new HashTable<string, string> (str_hash, str_equal);

        private File _library = File.new_build_filename (Environment.get_home_dir (), "Music", "library");

        // basename -> rating cache changed; play-bar re-syncs its toggles.
        public signal void labels_changed ();
        // progress during refresh (): a message and a fraction in [0,1], or
        // fraction < 0 for an indeterminate phase.
        public signal void refresh_progress (string message, double fraction);

        construct {
            _home = resolve_home ();
            _script = Path.build_filename (_home, "scripts", "banger_api.py");
            var uv = Environment.find_program_in_path ("uv");
            _uv = uv ?? Path.build_filename (Environment.get_home_dir (), ".local", "bin", "uv");
        }

        public bool available {
            get {
                return FileUtils.test (_script, FileTest.EXISTS)
                    && FileUtils.test (_uv, FileTest.IS_EXECUTABLE);
            }
        }

        private string resolve_home () {
            var env = Environment.get_variable ("BANGER_HOME");
            if (env != null && FileUtils.test ((!) env, FileTest.IS_DIR))
                return (!) env;
            string[] candidates = {
                Path.build_filename (Environment.get_user_data_dir (), "g4music", "banger"),
                "/usr/local/share/g4music/banger",
                "/usr/share/g4music/banger",
            };
            foreach (unowned var c in candidates) {
                if (FileUtils.test (c, FileTest.IS_DIR))
                    return c;
            }
            return candidates[0];
        }

        private string[] api_argv (string[] cmd) {
            string[] argv = { _uv, "run", "--project", _home, "python", _script };
            foreach (unowned var a in cmd)
                argv += a;
            return argv;
        }

        // Run the sidecar once and return its full stdout.
        private async string run_api (string[] cmd) throws Error {
            var proc = new Subprocess.newv (api_argv (cmd),
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? sout = null;
            yield proc.communicate_utf8_async (null, null, out sout, null);
            return sout ?? "";
        }

        private string basename_of (string uri) {
            var name = File.new_for_uri (uri).get_basename ();
            return name ?? uri;
        }

        public Rating rating_for (string uri) {
            unowned string? r = _labels.get (basename_of (uri));
            if (r == "like") return Rating.LIKE;
            if (r == "dislike") return Rating.DISLIKE;
            return Rating.NONE;
        }

        public async void load_labels () {
            try {
                var outp = yield run_api ({ "labels" });
                _labels.remove_all ();
                foreach (unowned var line in outp.split ("\n")) {
                    if (line.length == 0)
                        continue;
                    var f = line.split ("\t", 2);
                    if (f.length == 2)
                        _labels.set (f[0], f[1]);
                }
                labels_changed ();
            } catch (Error e) {
                warning ("banger labels: %s", e.message);
            }
        }

        // Record the rating in the DB + send ListenBrainz feedback (sidecar);
        // the cache is updated optimistically so the UI is instant.
        public async void set_label (string uri, Rating rating) {
            var name = basename_of (uri);
            unowned var r = rating == Rating.LIKE ? "like"
                          : (rating == Rating.DISLIKE ? "dislike" : "none");
            if (rating == Rating.NONE)
                _labels.remove (name);
            else
                _labels.set (name, r);
            labels_changed ();
            try {
                yield run_api ({ "label", "--file", uri, "--rating", r });
            } catch (Error e) {
                warning ("banger label: %s", e.message);
            }
        }

        public async void like (Music music) {
            var dst = _library.get_child (basename_of (music.uri));
            try {
                if (!_library.query_exists ())
                    _library.make_directory_with_parents ();
                if (!dst.query_exists ()) {
                    var src = File.new_for_uri (music.uri);
                    yield src.copy_async (dst, FileCopyFlags.NONE);
                }
                yield notify_added (dst);
            } catch (Error e) {
                toast (e.message);
            }
            yield set_label (music.uri, Rating.LIKE);
        }

        public async void unlike (Music music) {
            yield remove_library_copy (music);
            yield set_label (music.uri, Rating.NONE);
        }

        public async void dislike (Music music) {
            yield remove_library_copy (music);
            yield set_label (music.uri, Rating.DISLIKE);
        }

        private async void remove_library_copy (Music music) {
            var dst = _library.get_child (basename_of (music.uri));
            if (dst.query_exists ()) {
                try {
                    yield dst.delete_async ();
                    yield notify_removed (dst);
                } catch (Error e) {
                    toast (e.message);
                }
            }
        }

        public async BangerStatus get_status () {
            var s = new BangerStatus ();
            var taste = new StringBuilder ();
            try {
                var outp = yield run_api ({ "status" });
                foreach (unowned var line in outp.split ("\n")) {
                    if (line.length == 0)
                        continue;
                    var f = line.split ("\t");
                    unowned var k = f[0];
                    if (k == "configured")
                        s.configured = f.length > 1 && f[1] == "true";
                    else if (k == "batch_number")
                        s.batch_number = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "downloaded")
                        s.downloaded = f.length > 1 && f[1] == "true";
                    else if (k == "total_seen")
                        s.total_seen = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "audition_count")
                        s.audition_count = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "library_count")
                        s.library_count = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "liked")
                        s.liked = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "disliked")
                        s.disliked = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "pending")
                        s.pending = f.length > 1 ? int.parse (f[1]) : 0;
                    else if (k == "taste" && f.length >= 3) {
                        if (taste.len > 0)
                            taste.append ("   ");
                        taste.append_printf ("%s %s", f[1], f[2]);
                    }
                }
            } catch (Error e) {
                warning ("banger status: %s", e.message);
            }
            s.taste = taste.str;
            return s;
        }

        // Clear the audition batch + generate and download the next one.
        // Emits refresh_progress () per phase; returns true on success.
        public async bool refresh () {
            bool ok = false;
            try {
                var proc = new Subprocess.newv (api_argv ({ "refresh" }),
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                var stream = new DataInputStream ((!) proc.get_stdout_pipe ());
                string? line = null;
                while ((line = yield stream.read_line_async ()) != null) {
                    var f = ((!) line).split ("\t");
                    if (f[0] == "progress" && f.length >= 2) {
                        double frac = -1;
                        if (f.length >= 4) {
                            var total = double.parse (f[3]);
                            if (total > 0)
                                frac = double.parse (f[2]) / total;
                        }
                        refresh_progress (f[1], frac);
                    } else if (f[0] == "ok") {
                        ok = f.length > 1 && f[1] == "true";
                    } else if (f[0] == "error" && f.length > 1) {
                        toast (f[1]);
                    }
                }
                yield proc.wait_async ();
            } catch (Error e) {
                warning ("banger refresh: %s", e.message);
                toast (e.message);
            }
            yield load_labels ();
            return ok;
        }

        private async void notify_added (File f) {
            var app = GLib.Application.get_default () as Application;
            if (app != null)
                yield ((!) app).loader.on_file_added (f);
        }

        private async void notify_removed (File f) {
            var app = GLib.Application.get_default () as Application;
            if (app != null)
                yield ((!) app).loader.on_file_removed (f);
        }

        private void toast (string message) {
            Window.get_default ()?.show_toast (message);
        }
    }
}
