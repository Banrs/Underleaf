//! tlmgr and osascript as stub scripts, on a PATH that reaches neither the real ones nor the
//! system's dialog.

use std::path::Path;

use tempfile::TempDir;

use super::install_package;
use crate::compile::stubs::stub;

const REPOSITORY: &str = "tlmgr: package repository https://mirror.aarnet.edu.au/pub/CTAN/systems/texlive/tlnet (verified)\n";

/// A tlmgr that answers `search` with `search` and `install` with `install`, as a shell
/// script's lines, and writes down each call's arguments.
fn tlmgr(dir: &Path, search: &str, install: &str) {
    let answer = |text: &str| match text.rsplit_once("\nexit ") {
        Some((text, code)) => format!("cat <<'END'\n{text}\nEND\nexit {code}"),
        None => format!("cat <<'END'\n{text}END\n"),
    };
    let script = format!(
        "echo \"$@\" >> \"$0.calls\"\ncase $1 in\nsearch) {};;\ninstall) {};;\nesac\n",
        answer(search),
        answer(install)
    );
    stub(dir, "tlmgr", &script);
}

async fn installed(dir: &TempDir, file: &str) -> Result<String, crate::ErrorKind> {
    let path = format!("{}:/bin", dir.path().join("bin").display());
    install_package(file, &path).await.map_err(|err| err.kind)
}

fn calls(dir: &TempDir, program: &str) -> String {
    std::fs::read_to_string(dir.path().join("bin").join(format!("{program}.calls")))
        .unwrap_or_default()
}

#[tokio::test]
async fn the_package_with_the_file_itself_is_installed_and_tlmgrs_failures_are_named() {
    let fixltx2e = format!(
        "{REPOSITORY}latex:\n\ttexmf-dist/tex/latex/base/fixltx2e.sty\n\
         latex-base-dev:\n\ttexmf-dist/tex/latex-dev/base/fixltx2e.sty\n"
    );
    let minted = format!(
        "{REPOSITORY}minted:\n\ttexmf-dist/tex/latex/minted/minted.sty\n\
         tex4ht:\n\ttexmf-dist/tex/generic/tex4ht/minted-sty-hooks.4ht\n"
    );
    let older = "tlmgr: Local TeX Live (2025) is older than remote repository (2026).\nexit 1";
    let offline = "tlmgr: TLPDB::from_file could not get texlive.tlpdb from: https://x/tlnet/tlpkg/texlive.tlpdb\nexit 1";
    let cases: [(&str, &str, &str, Result<&str, crate::ErrorKind>); 8] = [
        ("fixltx2e.sty", &fixltx2e, "", Ok("latex")),
        ("minted.sty", &minted, "", Ok("minted")),
        ("hooks.4ht", &minted, "", Err(crate::ErrorKind::NotFound)),
        ("x.sty", older, "", Err(crate::ErrorKind::Conflict)),
        ("x.sty", offline, "", Err(crate::ErrorKind::Unavailable)),
        (
            "minted.sty",
            &minted,
            "tlmgr: package minted failed to install\nexit 1",
            Err(crate::ErrorKind::Internal),
        ),
        ("-x.sty", &minted, "", Err(crate::ErrorKind::Invalid)),
        ("a/minted.sty", &minted, "", Err(crate::ErrorKind::Invalid)),
    ];
    for (file, search, install, expected) in cases {
        let dir = TempDir::new().unwrap();
        tlmgr(dir.path(), search, install);
        let result = installed(&dir, file).await;
        assert_eq!(result, expected.map(str::to_owned), "{file}: {search}");
        if let Ok(package) = expected {
            let search = format!("search --global --file /{file}\n");
            assert_eq!(calls(&dir, "tlmgr"), format!("{search}install {package}\n"));
        }
    }

    let dir = TempDir::new().unwrap();
    assert_eq!(
        installed(&dir, "x.sty").await,
        Err(crate::ErrorKind::Unavailable)
    );
}

#[tokio::test]
async fn a_tree_only_an_administrator_may_change_is_installed_through_the_systems_dialog() {
    let refused = "You don't have permission to change the installation in any way,\nexit 2";
    let found = format!("{REPOSITORY}url:\n\ttexmf-dist/tex/latex/url/url.sty\n");
    for (answer, expected) in [
        ("exit 0", Ok("url".to_owned())),
        (
            "echo '0:1: execution error: User canceled. (-128)' >&2\nexit 1",
            Err(crate::ErrorKind::Denied),
        ),
    ] {
        let dir = TempDir::new().unwrap();
        tlmgr(dir.path(), &found, refused);
        stub(
            dir.path(),
            "osascript",
            &format!("echo \"$1 $3 $4\" >> \"$0.calls\"\n{answer}\n"),
        );
        assert_eq!(installed(&dir, "url.sty").await, expected);
        let tlmgr = dir.path().join("bin/tlmgr");
        assert_eq!(
            calls(&dir, "osascript"),
            format!("-e {} url\n", tlmgr.display())
        );
    }
}
