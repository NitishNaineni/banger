/*
 * banger — the Library tab.
 *
 * A self-scanning list of your liked tracks (~/Music/library). Sortable via the
 * app's normal sort control (the "sort-mode" setting), just like the Playing tab.
 */
namespace G4 {

    public class LibraryPage : FolderList {
        public LibraryPage (Application app) {
            base (app, File.new_build_filename (Environment.get_home_dir (), "Music", "library"), "library-sort");
        }
    }
}
