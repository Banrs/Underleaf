//! TeX in the app's own process, where the system starts none (iPadOS): the engines the app
//! links (TeXpresso's, `tools/texpresso-ios`), registered once with `tl_set_engine`, run Live
//! Preview and each program of a build. The app sets the TeX tree's variables in its
//! environment before it opens the core.

use std::ffi::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::CoreError;
use crate::tex::TexStatus;

/// Where TeX runs only inside the app.
pub(crate) const IN_PROCESS: bool = cfg!(target_os = "ios");
#[cfg(unix)]
const UNAVAILABLE: &str = "TeX isn’t part of this copy of TeXLocal.";

/// `tl_engine`: the library's `txp_live_start`, `txp_session_wait` and `txp_run`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Engine {
    pub live_start: unsafe extern "C" fn(
        argc: c_int,
        argv: *const *const c_char,
        pdf_output: *const c_char,
        commands: *mut c_int,
        messages: *mut c_int,
        log: *mut c_int,
    ) -> *mut c_void,
    pub session_wait: unsafe extern "C" fn(session: *mut c_void) -> c_int,
    pub run: unsafe extern "C" fn(
        engine: *const c_char,
        argc: c_int,
        argv: *const *const c_char,
        cwd: *const c_char,
        output: c_int,
        env: *const *const c_char,
        cancel: *const c_int,
    ) -> c_int,
}

static ENGINE: OnceLock<Engine> = OnceLock::new();

/// The first registration stands: sessions may already be running on it.
pub fn set_engine(engine: Engine) {
    // The engine is spoken to over pipes: a write to one whose end has gone must fail, as it
    // does in a Rust program, not end the app.
    // SAFETY: setting a signal's disposition.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    let _ = ENGINE.set(engine);
}

#[cfg(unix)]
pub(crate) fn engine() -> Result<&'static Engine, CoreError> {
    ENGINE.get().ok_or_else(|| CoreError::new(501, UNAVAILABLE))
}

/// The tree's folder, from the app's environment, as TeX would read it.
fn var(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// Where builds keep the formats they make, one per engine: TEXPRESSO_CACHE is writable and
/// the app's own, and TeXpresso keeps Live Preview's there too.
#[cfg(unix)]
pub(crate) fn formats() -> Result<PathBuf, CoreError> {
    var("TEXPRESSO_CACHE")
        .map(|cache| cache.join("formats"))
        .ok_or_else(|| CoreError::new(501, UNAVAILABLE))
}

/// TeX is there with an engine and LaTeX in its tree; both are what Live Preview runs.
pub(crate) fn status() -> TexStatus {
    let tree = var("TEXMFDIST").filter(|dist| dist.join("tex/latex/base/latex.ltx").is_file());
    let found = tree
        .filter(|_| ENGINE.get().is_some())
        .map(|dist| dist.to_string_lossy().into_owned());
    TexStatus {
        available: found.is_some(),
        texpresso: found.clone(),
        found,
        ..TexStatus::default()
    }
}

pub(crate) fn no_installs() -> CoreError {
    CoreError::new(
        501,
        "TeX comes with TeXLocal on this device, and nothing more can be installed into it.",
    )
}

#[cfg(unix)]
mod unix {
    use std::ffi::{CString, OsStr, c_int};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;
    use std::sync::atomic::AtomicI32;

    use super::Engine;

    /// A NUL can't be in a path or an argument: one that has one is given empty.
    fn c_string(text: impl AsRef<OsStr>) -> CString {
        CString::new(text.as_ref().as_bytes()).unwrap_or_default()
    }

    /// Pointers to `strings`, NULL-terminated, valid while they are.
    fn pointers(strings: &[CString]) -> Vec<*const std::ffi::c_char> {
        strings
            .iter()
            .map(|s| s.as_ptr())
            .chain([std::ptr::null()])
            .collect()
    }

    /// A Live Preview session the engine runs, until `wait` ends it.
    pub(crate) struct Live(*mut std::ffi::c_void);

    // SAFETY: the library's session is waited for and freed from any one thread.
    unsafe impl Send for Live {}

    impl Engine {
        /// `program` ("pdftex", "bibtex"...) as `args[0]` names it, to the end, on this thread,
        /// in `cwd`, its terminal output to `output`; 130 once `cancel` is set, -1 if there is
        /// no such program.
        pub(crate) fn run(
            &self,
            program: &str,
            args: &[impl AsRef<OsStr>],
            cwd: &Path,
            output: &impl AsRawFd,
            env: &[String],
            cancel: &AtomicI32,
        ) -> i32 {
            let args: Vec<CString> = args.iter().map(c_string).collect();
            let env: Vec<CString> = env.iter().map(c_string).collect();
            let (argv, envp) = (pointers(&args), pointers(&env));
            // SAFETY: the strings outlive the call, and the flag is an int the engine only reads.
            unsafe {
                (self.run)(
                    c_string(program).as_ptr(),
                    args.len() as c_int,
                    argv.as_ptr(),
                    c_string(cwd).as_ptr(),
                    output.as_raw_fd(),
                    envp.as_ptr(),
                    cancel.as_ptr().cast_const(),
                )
            }
        }

        /// Live Preview with `args` as TeXpresso's command line, writing its pages by `pdf`:
        /// the session, then the pipes of its commands, protocol lines and log.
        pub(crate) fn live_start(
            &self,
            args: &[impl AsRef<OsStr>],
            pdf: &Path,
        ) -> Option<(Live, [OwnedFd; 3])> {
            let args: Vec<CString> = args.iter().map(c_string).collect();
            let argv = pointers(&args);
            let mut fds = [-1; 3];
            let [commands, messages, log] = &mut fds;
            // SAFETY: the strings outlive the call; the library hands over the three pipes.
            let session = unsafe {
                (self.live_start)(
                    args.len() as c_int,
                    argv.as_ptr(),
                    c_string(pdf).as_ptr(),
                    commands,
                    messages,
                    log,
                )
            };
            (!session.is_null()).then(|| {
                (
                    Live(session),
                    fds.map(|fd| unsafe { OwnedFd::from_raw_fd(fd) }),
                )
            })
        }

        /// Blocks until the session has ended, once its commands are closed.
        pub(crate) fn wait(&self, live: Live) -> i32 {
            // SAFETY: the session came from `live_start` and is waited for once.
            unsafe { (self.session_wait)(live.0) }
        }
    }
}
