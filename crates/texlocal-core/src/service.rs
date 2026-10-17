// Shared command surface: hosts forward here so path checks and edit
// serialization have one implementation.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::atomic::Stamp;
use crate::compile::{self, CompileManager};
use crate::{CoreError, atomic, import, lock, paths, projects, settings, synctex, zipexport};

const SEARCH_LIMIT: usize = 100;
/// Shared TeX folder choice, stored beside projects as a file so it never
/// appears in the project list.
const APP_SETTINGS_FILE: &str = ".texlocal-app.json";
const TEX_DIR: &str = "texDir";
const TEXPRESSO_DIR: &str = "texpressoDir";
const NO_LATEXMK: &str = "That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as /Library/TeX/texbin.";
const NO_TEXPRESSO: &str =
    "That folder doesn't contain the texpresso program. Choose the folder it's in.";

pub struct Service {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    pub texpresso: crate::texpresso::Manager,
    /// One lock per project name, case-folded where the volume ignores case:
    /// a project's edits, settings read/modify/write, renames and deletes run
    /// one at a time, while other projects' go on. Unicode normalisation is
    /// not folded: ids are the names list_projects read from the folder, so
    /// every client spells a project as its folder is stored.
    edits: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    /// Whether the last look for TeX (`status`) found it: sessions build by
    /// themselves only then.
    pub(crate) tex_found: AtomicBool,
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: crate::texpresso::Manager::default(),
            edits: Mutex::default(),
            tex_found: AtomicBool::new(false),
        }
    }

    /// Stop every compile and live preview, as a host does when it quits.
    /// Compiles run in their own process groups, so nothing else stops them.
    pub fn kill_all(&self) {
        self.compile.kill_all();
        self.texpresso.kill_all();
    }

    pub fn project_root(&self, id: &str) -> Result<PathBuf, CoreError> {
        paths::project_root(&self.data_dir, id)
    }

    /// Run `work` holding the locks of the projects named `names`, taken in
    /// one order so that two callers wanting the same two can't deadlock.
    /// Locks no one holds are dropped on the way.
    fn locked<T>(&self, names: &[&str], work: impl FnOnce() -> T) -> T {
        let held: Vec<_> = {
            let mut locks = lock(&self.edits);
            locks.retain(|_, held| Arc::strong_count(held) > 1);
            let keys: BTreeSet<_> = names.iter().map(|name| paths::fold_case(name)).collect();
            let held = keys
                .into_iter()
                .map(|key| Arc::clone(locks.entry(key).or_default()));
            held.collect()
        };
        let _guards: Vec<_> = held.iter().map(|project| lock(project)).collect();
        work()
    }

    /// Run `use_project` holding the project's lock, finding the project
    /// once it is held, so a rename or delete that held it first is seen.
    pub(crate) fn with_project<T>(
        &self,
        id: &str,
        use_project: impl FnOnce(&Path) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        self.locked(&[paths::project_name(id)?], || {
            use_project(&self.project_root(id)?)
        })
    }

    /// Writes a project file's text under the project's lock; the file's
    /// stamp as written, for the session to know its own write's change.
    pub(crate) fn write_text(&self, id: &str, rel: &str, text: &str) -> Result<Stamp, CoreError> {
        self.with_project(id, |root| {
            projects::write_creating(&paths::safe_write_path(root, rel)?, text.as_bytes())
        })
    }

    /// Whether the last `status` found TeX.
    pub(crate) fn tex_found(&self) -> bool {
        self.tex_found.load(Ordering::Relaxed)
    }

    /// The TeX programs folder the user chose, or None to find TeX
    /// automatically. Read per use, so a choice made in another host applies.
    pub fn tex_dir(&self) -> Option<PathBuf> {
        self.app_folder(TEX_DIR)
    }

    fn app_folder(&self, key: &str) -> Option<PathBuf> {
        let settings = settings::read_object(&self.data_dir.join(APP_SETTINGS_FILE));
        let dir = settings.get(key)?.as_str()?;
        (!dir.is_empty()).then(|| PathBuf::from(dir))
    }

    /// The PATH for TeX's tools, and for TeXpresso's, with its chosen folder first.
    pub(crate) fn tool_paths(&self) -> (String, String) {
        let tex = compile::tex_path(self.tex_dir().as_deref());
        let texpresso = self.app_folder(TEXPRESSO_DIR).map_or_else(
            || tex.clone(),
            |dir| compile::join_path(std::iter::once(dir).chain(std::env::split_paths(&tex))),
        );
        (tex, texpresso)
    }

    /// Probe the current TeX choice, including installs made while the app is
    /// open. `latexmkVersion` is the number latexmk's version line names
    /// ("4.86"), as Settings shows it.
    async fn status(&self) -> Result<Value, CoreError> {
        let shown = |dir: Option<PathBuf>| dir.map(|d| d.to_string_lossy().into_owned());
        let (tex_path, texpresso_path) = self.tool_paths();
        let mut found = compile::tex_available(&tex_path).await;
        found.texpresso = shown(crate::texpresso::discover(&texpresso_path));
        found.tex_dir = shown(self.tex_dir());
        found.texpresso_dir = shown(self.app_folder(TEXPRESSO_DIR));
        self.tex_found.store(found.available, Ordering::Relaxed);
        let version = found.version.as_deref().and_then(latexmk_version);
        let mut status = out(found)?;
        status["latexmkVersion"] = json!(version);
        Ok(status)
    }

    /// Choose the TeX folder (`texDir`) or TeXpresso's; None or empty goes
    /// back to finding TeX automatically, or TeXpresso on TeX's path. A TeX
    /// Live root is accepted and saved as its bin folder.
    async fn choose_folder(&self, key: &str, dir: Option<&str>) -> Result<Value, CoreError> {
        let no_latexmk = || CoreError::bad_request(NO_LATEXMK);
        let chosen = match dir.map(str::trim).filter(|d| !d.is_empty()).map(Path::new) {
            None => None,
            Some(dir) if key == TEX_DIR && !dir.is_absolute() => return Err(no_latexmk()),
            Some(dir) if key == TEX_DIR => Some(compile::tex_bin_dir(dir).ok_or_else(no_latexmk)?),
            Some(dir) => {
                compile::program_at(&dir.join("texpresso"))
                    .ok_or_else(|| CoreError::bad_request(NO_TEXPRESSO))?;
                Some(dir.to_path_buf())
            }
        };
        let file = self.data_dir.join(APP_SETTINGS_FILE);
        let mut folders = settings::read_object(&file);
        let chosen = chosen.map(|dir| dir.to_string_lossy().into_owned());
        folders.insert(key.into(), chosen.into());
        atomic::write(&file, Value::Object(folders).to_string().as_bytes())?;
        self.status().await
    }

    /// With `live`, the live preview of the client's project session
    /// (`session`) syncs, not the build: its PDF is the one shown.
    fn live_pdf(&self, args: &Value) -> Result<Option<PathBuf>, CoreError> {
        if !arg::<Option<bool>>(args, "live")?.unwrap_or(false) {
            return Ok(None);
        }
        let session = arg::<Option<u64>>(args, "session")?
            .ok_or_else(|| CoreError::bad_request("Live sync needs the project session"))?;
        self.texpresso.live_pdf(session).map(Some)
    }

    /// The JSON command table the hosts call through the FFI, but for the
    /// sessions' (`session_*`). Raw bytes stay in direct methods outside it.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key| string_arg(args, key);
        let id = || s("id");
        let root = || self.project_root(id()?);
        let dir = || arg::<Option<String>>(args, "dir");
        match command {
            "status" => self.status().await,
            "set_tex_dir" => self.choose_folder(TEX_DIR, dir()?.as_deref()).await,
            "set_texpresso_dir" => self.choose_folder(TEXPRESSO_DIR, dir()?.as_deref()).await,
            "list_projects" => out(projects::list_projects(&self.data_dir)?),
            // The project made is answered, so its `id` is the name it got: a name taken is
            // numbered past. Its engine is checked first, so the project is made with it or
            // not at all.
            "create_project" => {
                let template = arg::<Option<String>>(args, "template")?;
                let engine = arg::<Option<String>>(args, "engine")?;
                if let Some(engine) = &engine
                    && compile::engine_flags(engine).is_none()
                {
                    return Err(CoreError::bad_request(format!("Unknown engine: {engine}")));
                }
                let template = template.as_deref().unwrap_or("article");
                let made = projects::create_project(&self.data_dir, s("name")?, template)?;
                if let Some(engine) = engine {
                    let patch = json!({ "engine": engine });
                    self.with_project(&made.id, |root| settings::write_settings(root, &patch))?;
                }
                out(made)
            }
            "free_project_name" => {
                let name = arg::<Option<String>>(args, "name")?;
                let name = projects::free_project_name(&self.data_dir, name.as_deref())?;
                Ok(json!({ "name": name }))
            }
            // The new name's lock too: of two renames to one name, the second
            // waits and finds it taken.
            "rename_project" => {
                let (id, name) = (id()?, s("name")?);
                let names = [paths::project_name(id)?, &paths::sanitize_name(name)?];
                out(self.locked(&names, || {
                    // A build or live preview would go on in the moved folder, and report back
                    // from the old path.
                    let stop = |root: &Path| {
                        self.compile.stop(root);
                        self.texpresso.stop(root)
                    };
                    projects::rename_project(&self.data_dir, id, name, stop)
                })?)
            }
            "get_settings" => out(settings::read_settings(&root()?)),
            "file_tree" => out(projects::file_tree(&root()?)?),
            "search_project" => {
                let hits = projects::search_project(&root()?, s("query")?, SEARCH_LIMIT)?;
                out(projects::search_groups(hits))
            }
            "read_file" => {
                let bytes = fs::read(paths::safe_path(&root()?, s("path")?)?)?;
                Ok(json!({ "text": crate::lossy_string(bytes) }))
            }
            // `text` is required: a call that lost it must fail, not empty
            // the file. A session saves its documents itself; the Mac app's
            // tests write their files with it.
            "write_file" => {
                let (path, text) = (s("path")?, s("text")?);
                out(self.write_text(id()?, path, text)?)
            }
            // With `free`, a taken name is numbered past ("untitled 2.tex") rather than refused.
            "create_entry" => {
                let path = s("path")?;
                let is_dir = arg::<Option<bool>>(args, "dir")?.unwrap_or(false);
                let free = arg::<Option<bool>>(args, "free")?.unwrap_or(false);
                let made = self.with_project(id()?, |root| match free {
                    true => projects::create_free(root, path, is_dir),
                    false => projects::create_file(root, path, is_dir).map(|()| path.to_owned()),
                })?;
                Ok(json!({ "path": made }))
            }
            // A session builds and cleans; this stops a project's build from outside it, as
            // before the project goes to the Trash.
            "stop_compile" => out(self.compile.stop(&root()?)),
            "synctex_forward" => out(synctex::synctex_forward_at(
                &root()?,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                self.live_pdf(args)?.as_deref(),
                &self.tool_paths().0,
            )
            .await?),
            "synctex_inverse" => {
                // `text`, the clicked page's text, and `at`, the clicked character's UTF-16
                // index in it.
                let click =
                    arg::<Option<String>>(args, "text")?.zip(arg::<Option<usize>>(args, "at")?);
                out(synctex::synctex_inverse(
                    &root()?,
                    arg(args, "page")?,
                    arg(args, "x")?,
                    arg(args, "y")?,
                    click.as_ref().map(|(text, at)| (text.as_str(), *at)),
                    self.live_pdf(args)?.as_deref(),
                    &self.tool_paths().0,
                )
                .await?)
            }
            "synctex_match" => out(synctex::match_forward(
                &root()?,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                &arg::<Vec<synctex::PdfPage>>(args, "pages")?,
            )?),
            "locate" => out(projects::locate(&self.data_dir, Path::new(s("path")?))?),
            // The compiled PDF's location; it may not exist yet.
            "pdf_path" => Ok(json!(
                settings::compiled_pdf_path(&root()?)?.to_string_lossy()
            )),
            "project_root" => Ok(json!(root()?.to_string_lossy())),
            "export_zip" => out(zipexport::export_zip(&root()?, Path::new(s("dest")?))?),
            // On quit, while a compile call may still be in flight — which rules
            // out tl_close — stop the latexmk trees that would otherwise outlive
            // the app.
            "kill_all" => {
                self.kill_all();
                Ok(Value::Null)
            }
            "import_files" => out(import::import_files(
                self,
                id()?,
                &dir()?.unwrap_or_default(),
                &arg::<Option<Vec<PathBuf>>>(args, "paths")?.unwrap_or_default(),
                arg(args, "conflict")?,
            )?),
            "import_project" => out(import::import_project(self, Path::new(s("src")?))?),
            "set_ui_state" => {
                out(self.with_project(id()?, |root| settings::write_ui(root, arg(args, "patch")?))?)
            }
            _ => Err(CoreError::not_found(format!("Unknown command: {command}"))),
        }
    }
}

static LATEXMK_VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Version (\d[\w.]*)").unwrap());

fn latexmk_version(line: &str) -> Option<String> {
    Some(LATEXMK_VERSION.captures(line)?[1].to_owned())
}

/// Argument `key` of a JSON command, which a missing key reads as null.
pub(crate) fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, CoreError> {
    // Straight from the borrowed Value, with no intermediate clone of it.
    T::deserialize(args.get(key).unwrap_or(&Value::Null))
        .map_err(|err| CoreError::bad_request(format!("Invalid argument `{key}`: {err}")))
}

/// A required string, borrowed (a document's text is not copied), with
/// `arg`'s errors.
pub(crate) fn string_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, CoreError> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| arg::<String>(args, key).unwrap_err())
}

pub(crate) fn out<T: Serialize>(value: T) -> Result<Value, CoreError> {
    serde_json::to_value(value).map_err(|err| CoreError::internal(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn service() -> (tempfile::TempDir, Service) {
        let data = tempfile::tempdir().unwrap();
        for name in ["P", "Q"] {
            projects::create_project(data.path(), name, "blank").unwrap();
        }
        let service = Service::new(data.path().to_path_buf());
        (data, service)
    }

    #[test]
    fn the_latexmk_version_is_the_number_its_version_line_names() {
        let line = "Latexmk, John Collins, 1 Jan 2025. Version 4.86a";
        assert_eq!(latexmk_version(line).as_deref(), Some("4.86a"));
        assert_eq!(latexmk_version("Latexmk, stub 1.0"), None);
    }

    #[tokio::test]
    async fn a_panic_during_an_edit_does_not_stop_later_edits() {
        let (data, service) = service();
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            service.with_project("P", |_| -> Result<(), CoreError> { panic!("a bug") })
        }));
        assert!(panicked.is_err());
        let args = json!({ "id": "P", "path": "main.tex", "text": "saved" });
        service.call("write_file", &args).await.unwrap();
        let saved = fs::read_to_string(data.path().join("P/main.tex")).unwrap();
        assert_eq!(saved, "saved");
    }

    #[test]
    fn an_edit_waits_for_its_own_project_only() {
        let (data, service) = service();
        let write = |id, file: &'static str| {
            service.with_project(id, |root| projects::write_creating(&root.join(file), b"x"))
        };
        std::thread::scope(|scope| {
            let edit = service.locked(&["P"], || {
                // Another project's edit goes ahead; this one's waits, however its id is spelled.
                write("Q", "q.tex").unwrap();
                let edit = scope.spawn(|| write("./P", "p.tex"));
                std::thread::sleep(Duration::from_millis(100));
                assert!(!data.path().join("P/p.tex").exists());
                edit
            });
            edit.join().unwrap().unwrap();
        });
        assert!(data.path().join("P/p.tex").is_file());
    }

    /// Two commands at once, each on a thread of its own, let go together.
    fn race(service: &Service, calls: [(&str, Value); 2]) -> [Result<Value, u16>; 2] {
        let start = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            let calls = calls.map(|(command, args)| {
                let start = &start;
                scope.spawn(move || {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .build()
                        .unwrap();
                    start.wait();
                    runtime.block_on(service.call(command, &args))
                })
            });
            calls.map(|call| call.join().unwrap().map_err(|e| e.status))
        })
    }

    /// A rename of P to "R" races a rename of Q, or a new project, to the same
    /// name: one rename finds it taken, a new project is always made (numbered
    /// past a taken name), and P's files stay wherever P ends up.
    #[test]
    fn two_claims_on_one_name_lose_no_project_s_files() {
        for round in 0..160 {
            let (data, service) = service();
            fs::write(data.path().join("P/main.tex"), "the user's").unwrap();
            let renaming = round % 2 == 0;
            let other = if renaming {
                ("rename_project", json!({ "id": "Q", "name": "R" }))
            } else {
                (
                    "create_project",
                    json!({ "name": "R", "template": "blank" }),
                )
            };
            let first = ("rename_project", json!({ "id": "P", "name": "R" }));
            let [renamed, other] = race(&service, [first, other]);
            let kept = match renamed {
                Ok(_) => "R",
                Err(409) => "P",
                Err(status) => panic!("round {round}: rename {status}"),
            };
            let expected = if renaming && kept == "R" {
                Err(409)
            } else {
                Ok(200)
            };
            assert_eq!(other.map(|_| 200), expected, "round {round}");
            let text = fs::read_to_string(data.path().join(kept).join("main.tex")).unwrap();
            assert_eq!(text, "the user's", "round {round}");
            let projects = fs::read_dir(data.path()).unwrap().count();
            assert_eq!(projects, if renaming { 2 } else { 3 }, "round {round}");
        }
    }
}
