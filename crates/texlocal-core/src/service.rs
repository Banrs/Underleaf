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
use crate::compile::{self, CompileManager, TexStatus, engine_flags};
use crate::paths::fold_case;
use crate::projects;
use crate::settings;
use crate::synctex;
use crate::{CoreError, atomic, import, lock, paths, zipexport};

const SEARCH_LIMIT: usize = 100;
/// Shared TeX folder choice, stored beside projects as a file so it never
/// appears in the project list.
const APP_SETTINGS_FILE: &str = ".texlocal-app.json";
const NO_LATEXMK: &str = "That folder doesn't contain latexmk. Choose the folder with TeX's programs, such as /Library/TeX/texbin.";
const NO_TEXPRESSO: &str =
    "That folder doesn't contain the texpresso program. Choose the folder it's in.";

/// `status`'s answer: what the look for TeX found, and latexmk's version
/// number from its version line ("4.86"), as Settings shows it.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    #[serde(flatten)]
    pub tex: TexStatus,
    pub latexmk_version: Option<String>,
}

static LATEXMK_VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Version (\d[\w.]*)").unwrap());

impl From<TexStatus> for Status {
    fn from(tex: TexStatus) -> Self {
        let version = tex
            .version
            .as_deref()
            .and_then(|line| LATEXMK_VERSION.captures(line));
        let latexmk_version = version.map(|found| found[1].to_owned());
        Self {
            tex,
            latexmk_version,
        }
    }
}

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
    /// Held to read, change and write the app's settings, so two changes keep both.
    app_writes: Mutex<()>,
    /// Whether the last look for TeX (`status`) found it: sessions build by themselves only
    /// then. None found before the first look.
    pub(crate) tex_found: AtomicBool,
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: crate::texpresso::Manager::default(),
            edits: Mutex::default(),
            app_writes: Mutex::default(),
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

    /// With `live`, the live preview of the client's project session (`session`) syncs, not
    /// the build: its PDF is the one shown.
    fn live_pdf(&self, args: &Value) -> Result<Option<PathBuf>, CoreError> {
        if !arg::<Option<bool>>(args, "live")?.unwrap_or(false) {
            return Ok(None);
        }
        let session = arg::<Option<u64>>(args, "session")?
            .ok_or_else(|| CoreError::bad_request("Live sync needs the project session"))?;
        self.texpresso.live_pdf(session).map(Some)
    }

    /// Run `work` holding the locks of the projects named `names`, taken in
    /// one order so that two callers wanting the same two can't deadlock.
    /// Locks no one holds are dropped on the way.
    fn locked<T>(&self, names: &[&str], work: impl FnOnce() -> T) -> T {
        let held: Vec<_> = {
            let mut locks = lock(&self.edits);
            locks.retain(|_, held| Arc::strong_count(held) > 1);
            let keys: BTreeSet<_> = names.iter().map(|name| fold_case(name)).collect();
            let mut held = |key| Arc::clone(locks.entry(key).or_default());
            keys.into_iter().map(&mut held).collect()
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

    // ---------- status ----------

    /// Probe the current TeX choice, including installs made while the app is open.
    pub async fn status(&self) -> Status {
        let ((tex_path, texpresso_path), (tex_dir, texpresso_dir)) =
            (self.tool_paths(), self.app_folders());
        let shown = |dir: Option<PathBuf>| dir.map(|d| d.to_string_lossy().into_owned());
        let mut found = compile::tex_available(&tex_path).await;
        found.texpresso = shown(crate::texpresso::discover(&texpresso_path));
        found.tex_dir = shown(tex_dir);
        found.texpresso_dir = shown(texpresso_dir);
        self.tex_found.store(found.available, Ordering::Relaxed);
        found.into()
    }

    /// Whether the last `status` found TeX.
    pub(crate) fn tex_found(&self) -> bool {
        self.tex_found.load(Ordering::Relaxed)
    }

    // ---------- TeX folder ----------

    /// The TeX programs folder the user chose, or None to find TeX
    /// automatically. Read per use, so a choice made in another host applies.
    pub fn tex_dir(&self) -> Option<PathBuf> {
        self.app_folders().0
    }

    fn app_settings(&self) -> serde_json::Map<String, Value> {
        settings::read_object(&self.data_dir.join(APP_SETTINGS_FILE))
    }

    /// The TeX and TeXpresso folders chosen, from one read of the settings.
    fn app_folders(&self) -> (Option<PathBuf>, Option<PathBuf>) {
        let settings = self.app_settings();
        let folder = |key| {
            let dir = settings.get(key)?.as_str()?;
            (!dir.is_empty()).then(|| PathBuf::from(dir))
        };
        (folder("texDir"), folder("texpressoDir"))
    }

    /// The PATH for TeX's tools, and for TeXpresso's, with its chosen folder first.
    pub(crate) fn tool_paths(&self) -> (String, String) {
        let (tex_dir, texpresso_dir) = self.app_folders();
        let tex = compile::tex_path(tex_dir.as_deref());
        let texpresso = match texpresso_dir {
            Some(dir) => {
                compile::join_path(std::iter::once(dir).chain(std::env::split_paths(&tex)))
            }
            None => tex.clone(),
        };
        (tex, texpresso)
    }

    /// Writes one folder, keeping the other settings.
    fn set_app_folder(&self, key: &str, dir: Option<&Path>) -> Result<(), CoreError> {
        let _writing = lock(&self.app_writes);
        let mut settings = self.app_settings();
        settings.insert(key.into(), json!(dir.map(|d| d.to_string_lossy())));
        atomic::write(
            &self.data_dir.join(APP_SETTINGS_FILE),
            Value::Object(settings).to_string().as_bytes(),
        )?;
        Ok(())
    }

    /// Choose TeXpresso's folder; None or empty goes back to the TeX path.
    pub async fn set_texpresso_dir(&self, dir: Option<&str>) -> Result<Status, CoreError> {
        let chosen = dir.map(str::trim).filter(|d| !d.is_empty()).map(Path::new);
        if let Some(dir) = chosen
            && compile::program_at(&dir.join("texpresso")).is_none()
        {
            return Err(CoreError::bad_request(NO_TEXPRESSO));
        }
        self.set_app_folder("texpressoDir", chosen)?;
        Ok(self.status().await)
    }

    /// Choose the TeX folder; None or empty goes back to automatic. A TeX Live
    /// root is accepted and saved as its bin folder.
    pub async fn set_tex_dir(&self, dir: Option<&str>) -> Result<Status, CoreError> {
        let chosen = match dir.map(str::trim).filter(|d| !d.is_empty()) {
            None => None,
            Some(dir) => {
                let dir = Path::new(dir);
                if !dir.is_absolute() {
                    return Err(CoreError::bad_request(NO_LATEXMK));
                }
                Some(compile::tex_bin_dir(dir).ok_or_else(|| CoreError::bad_request(NO_LATEXMK))?)
            }
        };
        self.set_app_folder("texDir", chosen.as_deref())?;
        Ok(self.status().await)
    }

    // ---------- project sessions (session/) ----------

    /// Writes a project file's text under the project's lock; the file's
    /// stamp as written, for the session to know its own write's change.
    pub(crate) fn write_text(&self, id: &str, rel: &str, text: &str) -> Result<Stamp, CoreError> {
        self.with_project(id, |root| {
            projects::write_creating(&paths::safe_write_path(root, rel)?, text.as_bytes())
        })
    }

    // ---------- dispatch ----------

    /// The JSON command table the hosts call through the FFI, but for the
    /// sessions' (`session_*`). Raw bytes stay in direct methods outside it.
    pub async fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let s = |key: &str| string_arg(args, key);
        let root = || self.project_root(s("id")?);
        let folder = || arg::<Option<String>>(args, "dir");
        match command {
            "status" => out(self.status().await),
            "set_texpresso_dir" => out(self.set_texpresso_dir(folder()?.as_deref()).await?),
            "set_tex_dir" => out(self.set_tex_dir(folder()?.as_deref()).await?),
            "list_projects" => out(projects::list_projects(&self.data_dir)?),
            // The project made is answered, so its `id` is the name it got: a name taken is
            // numbered past. Its engine is checked first, so the project is made with it or
            // not at all.
            "create_project" => {
                let template = arg::<Option<String>>(args, "template")?;
                let engine = arg::<Option<String>>(args, "engine")?;
                if let Some(engine) = &engine
                    && engine_flags(engine).is_none()
                {
                    return Err(CoreError::bad_request(format!("Unknown engine: {engine}")));
                }
                let made = projects::create_project(
                    &self.data_dir,
                    s("name")?,
                    template.as_deref().unwrap_or("article"),
                )?;
                if let Some(engine) = engine {
                    let patch = json!({ "engine": engine });
                    self.with_project(&made.id, |root| settings::write_settings(root, &patch))?;
                }
                out(made)
            }
            // The first free name of the series "Untitled", "Untitled 2", …, creating nothing:
            // for a host to offer in its New Project field.
            "free_project_name" => Ok(json!({
                "name": projects::free_project_name(
                    &self.data_dir,
                    arg::<Option<String>>(args, "name")?.as_deref(),
                )?
            })),
            // The new name's lock too: of two renames to one name, the second
            // waits and finds it taken.
            "rename_project" => {
                let (id, name) = (s("id")?, s("name")?);
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
            // A rename also rewrites mainFile; serialize read/modify/write. An open project's
            // session changes its settings itself (`session_set_settings`), to follow a new
            // main file.
            "set_settings" => out(self.with_project(s("id")?, |root| {
                settings::write_settings(root, &arg(args, "patch")?)
            })?),
            "file_tree" => out(projects::file_tree(&root()?)?),
            "search_project" => out(projects::search_groups(projects::search_project(
                &root()?,
                s("query")?,
                SEARCH_LIMIT,
            )?)),
            // Already a Value: out() would serialize it again, copying the
            // whole document.
            "read_file" => {
                let bytes = fs::read(paths::safe_path(&root()?, s("path")?)?)?;
                Ok(json!({ "text": crate::lossy_string(bytes) }))
            }
            // `text` is required: a call that lost it must fail, not empty
            // the file. The answer is the file's stamp. A session saves its
            // documents itself; the Mac app's tests write their files with it.
            "write_file" => {
                let (path, text) = (s("path")?, s("text")?);
                out(self.write_text(s("id")?, path, text)?)
            }
            // With `free`, a taken name is numbered past ("untitled 2.tex") rather than refused.
            "create_entry" => {
                let path = s("path")?;
                let dir = arg::<Option<bool>>(args, "dir")?.unwrap_or(false);
                let free = arg::<Option<bool>>(args, "free")?.unwrap_or(false);
                out(self.with_project(s("id")?, |root| {
                    let made = if free {
                        projects::create_free(root, path, dir)?
                    } else {
                        projects::create_file(root, path, dir)?;
                        path.to_owned()
                    };
                    Ok(json!({ "path": made }))
                })?)
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
                let root = root()?;
                // `text`, the clicked page's text, and `at`, the clicked character's UTF-16 index in it.
                let click =
                    arg::<Option<String>>(args, "text")?.zip(arg::<Option<usize>>(args, "at")?);
                out(synctex::synctex_inverse(
                    &root,
                    arg(args, "page")?,
                    arg(args, "x")?,
                    arg(args, "y")?,
                    click.as_ref().map(|(text, at)| (text.as_str(), *at)),
                    self.live_pdf(args)?.as_deref(),
                    &self.tool_paths().0,
                )
                .await?)
            }
            // The word at `column` of a source line, in the `pages` ([{page, text, near}]) of a forward sync.
            "synctex_match" => out(synctex::match_forward(
                &root()?,
                s("file")?,
                arg(args, "line")?,
                arg(args, "column")?,
                &arg::<Vec<synctex::PdfPage>>(args, "pages")?,
            )?),
            // An absolute path in the library as {id, path}; null outside every project.
            "locate" => out(projects::locate(&self.data_dir, Path::new(s("path")?))?),
            // The compiled PDF's location; it may not exist yet.
            "pdf_path" => Ok(json!(
                settings::compiled_pdf_path(&root()?)?.to_string_lossy()
            )),
            "project_root" => Ok(json!(root()?.to_string_lossy())),
            "export_zip" => {
                zipexport::export_zip(&root()?, Path::new(s("dest")?))?;
                Ok(Value::Null)
            }
            // On quit, while a compile call may still be in flight — which rules
            // out tl_close — stop the latexmk trees that would otherwise outlive
            // the app.
            "kill_all" => {
                self.kill_all();
                Ok(Value::Null)
            }
            "import_files" => out(import::import_files(
                self,
                s("id")?,
                &folder()?.unwrap_or_default(),
                &arg::<Option<Vec<PathBuf>>>(args, "paths")?.unwrap_or_default(),
                arg(args, "conflict")?,
            )?),
            "import_project" => out(import::import_project(self, Path::new(s("src")?))?),
            "get_ui_state" => out(settings::read_ui(&root()?)),
            "set_ui_state" => out(self.with_project(s("id")?, |root| {
                settings::write_ui(root, arg(args, "patch")?)
            })?),
            _ => Err(CoreError::not_found(format!("Unknown command: {command}"))),
        }
    }
}

/// Argument `key` of a JSON command, which a missing key reads as null.
pub(crate) fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T, CoreError> {
    // Straight from the borrowed Value, with no intermediate clone of it.
    T::deserialize(args.get(key).unwrap_or(&Value::Null))
        .map_err(|err| CoreError::bad_request(format!("Invalid argument `{key}`: {err}")))
}

/// Borrow a required string while keeping the typed argument errors.
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
        let service = Service::new(data.path().to_path_buf());
        for name in ["P", "Q"] {
            projects::create_project(data.path(), name, "blank").unwrap();
        }
        (data, service)
    }

    #[test]
    fn the_latexmk_version_is_the_number_its_version_line_names() {
        let version = |line: Option<&str>| {
            let tex = TexStatus {
                available: line.is_some(),
                version: line.map(str::to_owned),
                ..TexStatus::default()
            };
            Status::from(tex).latexmk_version
        };
        let line = "Latexmk, John Collins, 1 Jan 2025. Version 4.86a";
        assert_eq!(version(Some(line)).as_deref(), Some("4.86a"));
        assert_eq!(version(Some("Latexmk, stub 1.0")), None);
        assert_eq!(version(None), None);
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn settings_patches_and_main_file_renames_preserve_both_changes() {
        let (_data, service) = service();
        let service = Arc::new(service);
        for index in 0..16 {
            let (from, to, engine) = if index % 2 == 0 {
                ("main.tex", "paper.tex", "xelatex")
            } else {
                ("paper.tex", "main.tex", "pdflatex")
            };
            let start = Arc::new(tokio::sync::Barrier::new(2));
            let patch = tokio::spawn({
                let (service, start) = (Arc::clone(&service), Arc::clone(&start));
                async move {
                    start.wait().await;
                    let args = json!({ "id": "P", "patch": { "engine": engine } });
                    service.call("set_settings", &args).await.unwrap();
                }
            });
            start.wait().await;
            // As a session renames.
            service
                .with_project("P", |root| projects::rename_entry(root, from, to))
                .unwrap();
            patch.await.unwrap();
            let settings = settings::read_settings(&service.project_root("P").unwrap());
            assert_eq!(
                (settings.main_file.as_str(), settings.engine.as_str()),
                (to, engine)
            );
        }
    }

    #[test]
    fn an_edit_waits_for_its_own_project_only() {
        let (data, service) = service();
        std::thread::scope(|scope| {
            let edit = service.locked(&["P"], || {
                // Another project's edit goes ahead.
                service
                    .with_project("Q", |root| {
                        projects::write_creating(&root.join("q.tex"), b"q")
                    })
                    .unwrap();
                // This project's waits, however its id is spelled.
                let edit = scope.spawn(|| {
                    service.with_project("./P", |root| {
                        projects::write_creating(&root.join("p.tex"), b"p")
                    })
                });
                std::thread::sleep(Duration::from_millis(100));
                assert!(!data.path().join("P/p.tex").exists());
                edit
            });
            edit.join().unwrap().unwrap();
        });
        assert!(data.path().join("P/p.tex").is_file());
    }

    /// Two commands at once, each on a thread of its own, let go together.
    fn race(service: &Service, calls: [(&str, Value); 2]) -> [Result<Value, CoreError>; 2] {
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
            calls.map(|call| call.join().unwrap())
        })
    }

    #[test]
    fn of_two_renames_to_one_name_the_second_finds_it_taken() {
        for _ in 0..50 {
            let (data, service) = service();
            let rename = |id| ("rename_project", json!({ "id": id, "name": "R" }));
            let renamed = race(&service, [rename("P"), rename("Q")]);
            let mut statuses = renamed.map(|result| result.map_or_else(|e| e.status, |_| 200));
            statuses.sort_unstable();
            assert_eq!(statuses, [200, 409]);
            let left = fs::read_dir(data.path()).unwrap().count();
            assert_eq!(left, 2, "one project renamed, one left as it was");
        }
    }

    #[test]
    fn a_rename_and_a_new_project_of_one_name_keep_the_renamed_project_s_files() {
        for round in 0..120 {
            let (data, service) = service();
            fs::write(data.path().join("P/main.tex"), "the user's").unwrap();
            let [renamed, made] = race(
                &service,
                [
                    ("rename_project", json!({ "id": "P", "name": "R" })),
                    (
                        "create_project",
                        json!({ "name": "R", "template": "blank" }),
                    ),
                ],
            );
            let renamed = renamed.map_err(|e| (e.status, e.message));
            // The new project is always made; the rename goes ahead or finds
            // the name taken.
            assert!(made.is_ok(), "round {round}: create {made:?}");
            let kept = match renamed {
                Ok(_) => "R",
                Err((409, _)) => "P",
                Err(other) => panic!("round {round}: rename {other:?}"),
            };
            let text = fs::read_to_string(data.path().join(kept).join("main.tex")).unwrap();
            assert_eq!(text, "the user's", "round {round}");
            assert_eq!(
                fs::read_dir(data.path()).unwrap().count(),
                3,
                "round {round}"
            );
        }
    }
}
