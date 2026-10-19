// Shared command surface: hosts forward here so path checks and edit
// serialization have one implementation.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::compile::CompileManager;
use crate::paths::fold_case;
use crate::projects;
use crate::settings::{self, AppSettings};
use crate::synctex;
use crate::tex::{self, TexStatus};
use crate::texpresso::{self, Preview};
use crate::{CoreError, import, lock, paths, wordmatch, zipexport};

const SEARCH_LIMIT: usize = 100;
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
    pub texpresso: Arc<texpresso::Manager>,
    /// One lock per project name, case-folded where the volume ignores case:
    /// a project's edits, settings read/modify/write, renames and deletes run
    /// one at a time, while other projects' go on. Unicode normalisation is
    /// not folded: ids are the names list_projects read from the folder, so
    /// every client spells a project as its folder is stored.
    edits: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    /// Whether the last look for TeX (`status`) found it: sessions build by themselves only
    /// then, and one waiting builds once it is. None found before the first look.
    pub(crate) tex_found: tokio::sync::watch::Sender<bool>,
}

impl Service {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::default(),
            texpresso: Arc::default(),
            edits: Mutex::default(),
            tex_found: tokio::sync::watch::Sender::new(false),
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
        let app = AppSettings::read(&self.data_dir);
        let (tex_path, texpresso_path) = tex::tool_paths(&app);
        let shown = |dir: Option<PathBuf>| dir.map(|d| d.to_string_lossy().into_owned());
        let mut found = tex::tex_available(&tex_path).await;
        found.texpresso = shown(texpresso::discover(&texpresso_path));
        found.tex_dir = shown(app.tex_dir);
        found.texpresso_dir = shown(app.texpresso_dir);
        self.tex_found.send_replace(found.available);
        found.into()
    }

    /// Whether the last `status` found TeX.
    pub(crate) fn tex_found(&self) -> bool {
        *self.tex_found.borrow()
    }

    // ---------- TeX folder ----------

    /// The PATH for TeX's tools, and for TeXpresso's, with the folders chosen.
    pub(crate) fn tool_paths(&self) -> (String, String) {
        tex::tool_paths(&AppSettings::read(&self.data_dir))
    }

    /// Choose TeXpresso's folder; None or empty goes back to the TeX path.
    pub async fn set_texpresso_dir(&self, dir: Option<&str>) -> Result<Status, CoreError> {
        let chosen = dir.map(str::trim).filter(|d| !d.is_empty()).map(Path::new);
        if let Some(dir) = chosen
            && tex::program_at(&dir.join("texpresso")).is_none()
        {
            return Err(CoreError::bad_request(NO_TEXPRESSO));
        }
        AppSettings::choose(&self.data_dir, "texpressoDir", chosen)?;
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
                Some(tex::tex_bin_dir(dir).ok_or_else(|| CoreError::bad_request(NO_LATEXMK))?)
            }
        };
        AppSettings::choose(&self.data_dir, "texDir", chosen.as_deref())?;
        Ok(self.status().await)
    }

    // ---------- dispatch ----------

    /// The JSON command table the hosts call through the FFI, but for the
    /// sessions' (`session_*`).
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
            // numbered past. It is made with its engine or not at all.
            "create_project" => {
                let template = arg::<Option<String>>(args, "template")?;
                let engine = arg::<Option<String>>(args, "engine")?;
                out(projects::create_project_with_engine(
                    &self.data_dir,
                    s("name")?,
                    template.as_deref().unwrap_or("article"),
                    engine.as_deref(),
                )?)
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
            "file_tree" => out(projects::file_tree(&root()?)?),
            "search_project" => out(projects::search_groups(projects::search_project(
                &root()?,
                s("query")?,
                SEARCH_LIMIT,
            )?)),
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
                &arg::<Vec<wordmatch::PdfPage>>(args, "pages")?,
            )?),
            // An absolute path in the library as {id, path}; null outside every project.
            "locate" => out(projects::locate(&self.data_dir, Path::new(s("path")?))?),
            // The compiled PDF's location; it may not exist yet.
            "pdf_path" => {
                let root = root()?;
                let pdf = settings::read_settings(&root).output(&root, "pdf")?;
                Ok(json!(pdf.to_string_lossy()))
            }
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
mod tests;
