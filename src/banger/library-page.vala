/*
 * banger — the Library tab.
 *
 * A self-scanning list of your liked tracks (~/Music/library). Sortable via the
 * app's normal sort control (the "sort-mode" setting), just like the Playing tab.
 */
namespace G4 {

    public class LibraryPage : FolderList {
        public LibraryPage (Application app) {
            base (app, File.new_build_filename (Environment.get_home_dir (), "Music", "library"));
            // follow the shared sort setting (driven by the header sort button)
            app.settings.bind ("sort-mode", this, "library-sort", SettingsBindFlags.GET);
            set_sort_order (app.settings.get_uint ("sort-mode"));
        }

        public uint library_sort {
            get { return sort_order; }
            set { set_sort_order (value); }
        }
    }
}
