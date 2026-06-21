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
        private File _audition = File.new_build_filename (Environment.get_home_dir (), "Music", "audition");

        private FileMonitor? _lib_monitor = null;
        private uint _sync_timer = 0;
        private bool _syncing = false;

        // basename -> rating cache changed; play-bar re-syncs its toggles.
        public signal void labels_changed ();
        // the audition/library folders changed; the custom tabs re-scan.
        public signal void lists_changed ();
        // progress during refresh (): a message plus done/total (both 0 for an
        // indeterminate phase like "Clearing audition…").
        public signal void refresh_progress (string message, int done, int total);

        construct {
            _home = resolve_home ();
            _script = Path.build_filename (_home, "scripts", "banger_api.py");
            var uv = Environment.find_program_in_path ("uv");
            _uv = uv ?? Path.build_filename (Environment.get_home_dir (), ".local", "bin", "uv");
            // retry any cached (offline/failed) feedback whenever the network comes
            // back — and once now on startup, so a rating made offline last session
            // (or one that failed) is guaranteed to reach ListenBrainz at some point.
            NetworkMonitor.get_default ().network_changed.connect ((available) => {
                if (available)
                    flush_feedback.begin ((obj, res) => flush_feedback.end (res));
            });
            flush_feedback.begin ((obj, res) => flush_feedback.end (res));

            // Watch the library folder so FLACs copied/synced straight into it (file
            // manager, or Syncthing from the phone) get officially imported in place —
            // lyrics fetched + recorded as liked — with no explicit action.
            try {
                _lib_monitor = _library.monitor_directory (FileMonitorFlags.WATCH_MOVES);
                ((!) _lib_monitor).changed.connect ((file, other, ev) => {
                    if (ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.MOVED_IN
                        || ev == FileMonitorEvent.RENAMED || ev == FileMonitorEvent.CHANGES_DONE_HINT)
                        schedule_sync ();
                });
            } catch (Error e) {
            }
            schedule_sync ();   // reconcile anything added while the app was closed
        }

        // Coalesce a burst of file events (a multi-file copy / Syncthing batch) into one
        // reconcile a moment after the last change.
        private void schedule_sync () {
            if (_sync_timer != 0)
                Source.remove (_sync_timer);
            _sync_timer = Timeout.add (1500, () => {
                _sync_timer = 0;
                sync_library.begin ((o, r) => sync_library.end (r));
                return Source.REMOVE;
            });
        }

        // Officially import any library FLAC not yet a known liked track (lyrics + DB),
        // in place — then refresh the library views.
        public async void sync_library () {
            if (!available || _syncing)
                return;
            _syncing = true;
            bool ok = false;
            int imported = 0;
            var added = new GenericArray<string> ();
            try {
                yield stream_api ({ "sync" }, false, (f) => {
                    if (f[0] == "ok")
                        ok = f.length > 1 && f[1] == "true";
                    else if (f[0] == "imported" && f.length > 1)
                        imported = int.parse (f[1]);
                    else if (f[0] == "path" && f.length > 1)
                        added.add (f[1]);
                });
            } catch (Error e) {
                warning ("banger sync: %s", e.message);
            }
            _syncing = false;
            if (!ok || imported == 0)
                return;
            var app = GLib.Application.get_default () as Application;
            if (app != null && added.length > 0) {
                File[] files = {};
                foreach (unowned var p in added)
                    files += File.new_for_path (p);
                var arr = new GenericArray<Music> ();
                yield ((!) app).loader.load_files_async (files, arr, true, false, -1);
                ((!) app).notify_library_changed ();
            }
            yield load_labels ();
            lists_changed ();
            toast (imported == 1 ? _("Imported 1 new track into your library")
                                 : _("Imported %d new tracks into your library").printf (imported));
        }

        // Ship any like/dislike feedback that couldn't reach ListenBrainz earlier
        // (offline). The label is already saved locally; this just syncs it.
        public async void flush_feedback () {
            if (!available)
                return;
            try {
                yield run_api ({ "flush" });
            } catch (Error e) {
                warning ("banger flush: %s", e.message);
            }
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

        private delegate void LineFunc (string[] fields);

        // Spawn the sidecar and stream its tab-separated stdout line by line through
        // `handler`, then wait for exit. With `setsid_wrap` the sidecar runs as its own
        // process group (kept in _refresh_proc) so cancel_refresh () can tear the whole
        // uv/python/rip tree down. Shared by sync_library/refresh/add_from_link.
        private async void stream_api (string[] cmd, bool setsid_wrap,
                                       owned LineFunc handler) throws Error {
            string[] argv = {};
            if (setsid_wrap)
                argv += "setsid";
            foreach (unowned var a in api_argv (cmd))
                argv += a;
            var proc = new Subprocess.newv (argv,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            if (setsid_wrap)
                _refresh_proc = proc;
            var stream = new DataInputStream ((!) proc.get_stdout_pipe ());
            string? line = null;
            while ((line = yield stream.read_line_async ()) != null)
                handler (((!) line).split ("\t"));
            yield proc.wait_async ();
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
            var name = basename_of (music.uri);
            var dst = _library.get_child (name);
            try {
                if (!_library.query_exists ())
                    _library.make_directory_with_parents ();
                if (!dst.query_exists ()) {
                    // Copy from the audition source — it persists even when you're
                    // playing (and just deleted) the library copy. Fall back to the
                    // currently playing file if the audition copy is gone.
                    File src = _audition.get_child (name);
                    if (!src.query_exists ())
                        src = File.new_for_uri (music.uri);
                    if (!src.query_exists () || src.get_path () == dst.get_path ()) {
                        warning ("banger like: no source for %s", name);
                        toast (_("Can't like — the audition file is gone"));
                        return;
                    }
                    yield src.copy_async (dst, FileCopyFlags.OVERWRITE);
                }
                // (lyrics ride inside the FLAC's LYRICS tag, so the copy carries them)
                // Load the library copy into the library model (Artists/Albums)
                // WITHOUT splicing into the play queue, then refresh those views.
                var app = GLib.Application.get_default () as Application;
                if (app != null) {
                    var arr = new GenericArray<Music> ();
                    yield ((!) app).loader.load_files_async ({ dst }, arr, true, false, -1);
                    ((!) app).notify_library_changed ();
                }
            } catch (Error e) {
                warning ("banger like: copy failed: %s", e.message);
                toast (_("Couldn't add to library: %s").printf (e.message));
                return;
            }
            yield set_label (music.uri, Rating.LIKE);
            lists_changed ();
        }

        public async void unlike (Music music) {
            yield remove_library_copy (music);
            yield set_label (music.uri, Rating.NONE);
            lists_changed ();
        }

        public async void dislike (Music music) {
            yield remove_library_copy (music);
            yield set_label (music.uri, Rating.DISLIKE);
            lists_changed ();
        }

        // Drop the library copy when un-liking/disliking. If the song is still in
        // the current audition we just delete the copy; if it's from an old batch
        // (library is the only copy) we MOVE it back to audition so a mistaken
        // un-like is never destructive and stays re-likeable.
        //
        // We update only the library MODEL (Artists/Albums) and the folders — never
        // the play queue — so the song you're playing stays current_music and can be
        // re-liked.
        private async void remove_library_copy (Music music) {
            var name = basename_of (music.uri);
            var lib = _library.get_child (name);
            if (!lib.query_exists ())
                return;
            var aud = _audition.get_child (name);
            var aud_existed = aud.query_exists ();
            var app = GLib.Application.get_default () as Application;
            if (app != null) {
                var track = ((!) app).loader.find_cache (lib.get_uri ());
                if (track != null)
                    ((!) app).loader.library.remove_music ((!) track);
            }
            try {
                if (aud_existed)
                    yield lib.delete_async ();
                else
                    lib.move (aud, FileCopyFlags.NONE);   // old batch -> back to audition
            } catch (Error e) {
                toast (e.message);
            }
            if (app != null)
                ((!) app).notify_library_changed ();
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

        private Subprocess? _refresh_proc = null;

        // Clear the audition batch + generate and download the next one.
        // Emits refresh_progress () per phase; returns true on success. The Audition
        // tab shows the new tracks itself (its own folder re-scan on each progress) —
        // we deliberately do NOT load them into the library model or the queue here.
        public async bool refresh () {
            bool ok = false;
            kill_stray_downloads ();   // clear an orphan from a previous app run
            try {
                // setsid_wrap: run as its own process group so cancel_refresh() can tear
                // the whole uv/python/rip tree down (e.g. on app exit).
                yield stream_api ({ "refresh" }, true, (f) => {
                    if (f[0] == "progress" && f.length >= 2) {
                        int done = f.length >= 3 ? int.parse (f[2]) : 0;
                        int total = f.length >= 4 ? int.parse (f[3]) : 0;
                        refresh_progress (f[1], done, total);
                    } else if (f[0] == "ok") {
                        ok = f.length > 1 && f[1] == "true";
                    } else if (f[0] == "error" && f.length > 1) {
                        toast (f[1]);
                    }
                });
            } catch (Error e) {
                warning ("banger refresh: %s", e.message);
            }
            _refresh_proc = null;
            yield load_labels ();
            return ok;
        }

        // Download a track from a (possibly shortened) Deezer link straight into the
        // library as a liked track, with its lyrics; then refresh the library views.
        public async void add_from_link (string url) {
            if (!available) {
                toast (_("Music discovery isn't set up"));
                return;
            }
            bool ok = false;
            string name = "";
            var paths = new GenericArray<string> ();
            try {
                yield stream_api ({ "add", "--url", url }, false, (f) => {
                    if (f[0] == "ok")
                        ok = f.length > 1 && f[1] == "true";
                    else if (f[0] == "error" && f.length > 1)
                        toast (f[1]);
                    else if (f[0] == "name" && f.length > 1)
                        name = f[1];
                    else if (f[0] == "path" && f.length > 1)
                        paths.add (f[1]);
                });
            } catch (Error e) {
                warning ("banger add: %s", e.message);
            }
            if (!ok)
                return;
            var app = GLib.Application.get_default () as Application;
            if (app != null && paths.length > 0) {
                File[] files = {};
                foreach (unowned var p in paths)
                    files += File.new_for_path (p);
                var arr = new GenericArray<Music> ();
                yield ((!) app).loader.load_files_async (files, arr, true, false, -1);
                ((!) app).notify_library_changed ();
            }
            yield load_labels ();
            lists_changed ();
            toast (name.length > 0 ? _("Added “%s” to your library").printf (name)
                                   : _("Added to your library"));
        }

        // Kill any running download tree — call on a new refresh or on app shutdown.
        public void cancel_refresh () {
            if (_refresh_proc != null) {
                var pid = ((!) _refresh_proc).get_identifier ();
                if (pid != null) {
                    // setsid made the sidecar pid its own group leader; kill the group.
                    try {
                        new Subprocess.newv ({ "kill", "-KILL", "-" + (!) pid },
                            SubprocessFlags.STDERR_SILENCE);
                    } catch (Error e) {
                    }
                }
                ((!) _refresh_proc).force_exit ();
                _refresh_proc = null;
            }
            kill_stray_downloads ();
        }

        private void kill_stray_downloads () {
            try {
                new Subprocess.newv ({ "pkill", "-KILL", "-f", "scripts/download_batch.py" },
                    SubprocessFlags.STDERR_SILENCE);
            } catch (Error e) {
            }
        }

        private void toast (string message) {
            Window.get_default ()?.show_toast (message);
        }
    }
}
