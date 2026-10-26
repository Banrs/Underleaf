//! Tests across the projects module's parts: renames under the settings' and the paths' rules,
//! search, the symbol scan, and links.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::json;

use crate::CoreError;
use crate::analyze::Files;
use crate::paths::Project;
use crate::projects::search::SearchHit;
use crate::projects::testing::{names_in, project};
use crate::projects::{
    Query, Symbols, create_free, create_project, is_text, rename_entry, rename_project,
    scan_symbols, search_project,
};
use crate::settings::{read_settings, write_settings};

/// In any case and in part of a word, with nothing open, as the service searches.
fn search(root: &Path, query: &str, limit: usize) -> Result<Vec<SearchHit>, CoreError> {
    let found = |_: &str, text: &str| Query::new(query, false, false).places(text);
    search_project(root, &HashMap::new(), &is_text, &found, limit)
}

/// With nothing open and nothing read before.
fn scan(root: &Path) -> Result<Symbols, CoreError> {
    scan_symbols(root, &Files::default(), &HashMap::new())
}

fn labels(found: Symbols) -> Vec<String> {
    found.labels.into_iter().map(|l| l.name).collect()
}

#[test]
fn a_rename_that_cannot_write_the_settings_is_undone_and_leaves_them_as_they_were() {
    let (_dir, root) = project();
    let project = Project::in_folder(&root);
    let file = root.join(".texlocal.json");
    let broken = "{ \"mainFile\": \"paper.tex\", \"engine\": \"xelatex\", }";
    fs::write(&file, broken).unwrap();
    let refused = rename_entry(&project, "main.tex", "a.tex").unwrap_err();
    assert_eq!(refused.kind, crate::ErrorKind::Conflict);
    assert!(root.join("main.tex").is_file() && !root.join("a.tex").exists());
    create_free(&root, "b.tex", false).unwrap();
    rename_entry(&project, "b.tex", "c.tex").unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), broken);
}

#[test]
fn a_rename_takes_the_main_file_along_only_when_it_holds_it_and_keeps_to_the_rules() {
    let (_dir, root) = project();
    let project = Project::in_folder(&root);
    let settings = &project.settings;
    create_free(&root, "chapters/main.tex", false).unwrap();
    create_free(&root, "chapters2/other.tex", false).unwrap();
    write_settings(settings, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
    let result = rename_entry(&project, "chapters", "content").unwrap();
    assert_eq!(result.main_file, "content/main.tex");
    assert_eq!(read_settings(settings).main_file, "content/main.tex");
    create_free(&root, "chapters/x.tex", false).unwrap();
    write_settings(settings, &json!({ "mainFile": "chapters2/other.tex" })).unwrap();
    rename_entry(&project, "chapters", "moved").unwrap();
    assert_eq!(read_settings(settings).main_file, "chapters2/other.tex");
    let err = rename_entry(&project, "moved", "moved/old/moved").unwrap_err();
    assert_eq!(err.kind, crate::ErrorKind::Invalid, "{}", err.message);
    assert_eq!(names_in(&root.join("moved")), ["x.tex"]);
    // create_entry and uploads accept a leading "-"; only the main file, which reaches
    // latexmk's command line, may not start with one.
    create_free(&root, "-draft.tex", false).unwrap();
    let result = rename_entry(&project, "-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(result.to, "-notes/-draft.tex");
    assert!(root.join("-notes/-draft.tex").is_file());
}

/// On case-insensitive volumes too; and one stopped before the move leaves no folder of the new
/// name.
#[test]
fn a_case_only_rename_works_and_one_onto_another_entry_or_stopped_does_nothing() {
    let (_dir, root) = project();
    let project = Project::in_folder(&root);
    let data = root.parent().unwrap();
    create_free(&root, "Figures/plot.tex", false).unwrap();

    let result = rename_entry(&project, "main.tex", "Main.tex").unwrap();
    assert_eq!(result.main_file, "Main.tex");
    assert_eq!(read_settings(&project.settings).main_file, "Main.tex");
    rename_entry(&project, "Figures", "figures").unwrap();
    assert_eq!(names_in(&root), [".texlocal.json", "Main.tex", "figures"]);
    create_free(&root, "other.tex", false).unwrap();
    let err = rename_entry(&project, "other.tex", "Main.tex").unwrap_err();
    assert_eq!(err.kind, crate::ErrorKind::Conflict);

    rename_project(data, "P", "p", |_| Ok(())).unwrap();
    assert_eq!(names_in(data), ["p"]);
    create_project(data, "second", "blank", None).unwrap();
    let err = rename_project(data, "second", "p", |_| panic!("moved")).unwrap_err();
    assert_eq!(err.kind, crate::ErrorKind::Conflict);
    let stopped = rename_project(data, "p", "S", |_| Err(CoreError::conflict("no")));
    assert_eq!(stopped.unwrap_err().kind, crate::ErrorKind::Conflict);
    assert_eq!(names_in(data), ["p", "second"]);
}

#[test]
fn a_project_created_after_the_rename_check_is_not_replaced() {
    let (_dir, root) = project();
    let data = root.parent().unwrap();
    let dest = data.join("Taken");
    let err = rename_project(data, "P", "Taken", |_| {
        fs::create_dir(&dest)?;
        Ok(())
    })
    .unwrap_err();
    assert_eq!(err.kind, crate::ErrorKind::Conflict);
    assert!(root.join("main.tex").is_file());
    assert!(dest.is_dir() && names_in(&dest).is_empty());
}

#[test]
fn search_cuts_its_snippet_at_the_match_passes_over_other_files_and_stops_at_the_limit() {
    let (_dir, root) = project();
    for (file, text) in [
        ("ascii.tex", "One\nThe THEOREM holds\n"),
        ("figure.svg", "<text>theorem</text>\n"),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    let hits = search(&root, "theorem", 50).unwrap();
    let cut = |hit: &SearchHit| {
        let (file, line) = (&hit.file, hit.line);
        format!("{file}:{line} {}[{}]{}", hit.before, hit.matched, hit.after)
    };
    assert_eq!(
        hits.iter().map(cut).collect::<Vec<_>>(),
        ["ascii.tex:2 The [THEOREM] holds"]
    );
    fs::write(root.join("many.tex"), "needle\n".repeat(20)).unwrap();
    let hits = search(&root, "needle", 5).unwrap();
    assert_eq!(hits.len(), 5);
    assert!(hits.iter().all(|h| h.file == "many.tex"));
}

/// A Latin-1 .bib read as bytes by a Unicode-mode pattern loses the whole entry, so it is
/// decoded first; and a non-breaking space before the brace isn't swallowed into the key by an
/// ASCII-only `\s`.
#[test]
fn symbol_scan_survives_both_a_bad_byte_and_a_unicode_space() {
    let (_dir, root) = project();
    // 0xFC is "ü" in ISO-8859-1, and not UTF-8 alone.
    let bib = b"@article{m\xFCller2020,\n  title={x}\n}\n@article{ok2021,\n  title={y}\n}\n";
    fs::write(root.join("refs.bib"), bib).unwrap();
    fs::write(
        root.join("ch.tex"),
        b"\\label{fig:m\xFCller}\n\\label{fig:ok}\n",
    )
    .unwrap();
    let pasted = "@article{Smith2020\u{A0},\n  title={x}\n}\n@article\u{A0}{Jones2021,\n}\n";
    fs::write(root.join("pasted.bib"), pasted).unwrap();

    let Symbols {
        citations, labels, ..
    } = scan(&root).unwrap();
    let citations: Vec<String> = citations.into_iter().map(|c| c.name).collect();
    let labels: Vec<String> = labels.into_iter().map(|l| l.name).collect();
    assert_eq!(citations.len(), 4, "{citations:?}");
    assert_eq!(citations[..2], ["Smith2020", "Jones2021"]);
    assert!(citations[2].contains("ller2020") && citations[3] == "ok2021");
    assert_eq!(labels.len(), 2, "{labels:?}");
    assert!(labels[0].contains("ller") && labels[1] == "fig:ok");
}

#[test]
fn symbol_scan_reads_bibitems_skips_comments_and_keeps_file_order() {
    let (_dir, root) = project();
    let main = "\\label{kept} % \\label{old}\n% \\bibitem{gone}\n\
        50\\% \\label{after-percent} \\label{fig:}\n\
        \\begin{verbatim}\\label{literal}\\end{verbatim} \\label {spaced}\n\
        \\begin{equation} x \\label{eq:one} \\end{equation}\n\
        \\begin{thebibliography}{9}\n\\bibitem[K]{knuth} Knuth.\n\\bibitem {lamport} Lamport.\n";
    fs::write(root.join("main.tex"), main).unwrap();
    let keys = |found: &Symbols| -> Vec<String> {
        found.citations.iter().map(|c| c.name.clone()).collect()
    };
    let found = scan(&root).unwrap();
    assert_eq!(keys(&found), ["knuth", "lamport"]);
    assert_eq!(labels(found), ["kept", "after-percent", "spaced", "eq:one"]);

    fs::remove_file(root.join("main.tex")).unwrap();
    let bib = "@article{one,}\n@string{s=\"x\",}\n@Comment{gone,}\n@preamble{p,}\n@misc(three,)";
    for (file, text) in [
        ("z.tex", "\\label{shared}\\label{last}\\bibitem{two}"),
        ("a.tex", "\\label{first}\\label{shared}\\bibitem{one}"),
        ("refs.bib", bib),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    let found = scan(&root).unwrap();
    assert_eq!(keys(&found), ["one", "three", "two"]);
    assert_eq!(labels(found), ["first", "shared", "last"]);
}

#[test]
fn the_symbol_scan_reads_the_commands_and_environments_a_project_defines() {
    let (_dir, root) = project();
    let main = "\\newcommand{\\R}{\\mathbb{R}}\n\\newcommand*\\pair[2]{(#1, #2)}\n\
        \\newcommand{\\opt}[2][x]{#1#2} \\DeclareMathOperator*{\\argmax}{arg\\,max}\n\
        \\newenvironment{thm}[1]{}{} % \\newcommand{\\gone}{}\n\
        \\newenvironment{\\bad}{}{} \\newcommand{}{} \\newcommand{\\R}[1]{}\n\
        \\renewcommand{\\epsilon}{\\varepsilon} \\providecommand\\half{\\frac12} \\def\\d{\\mathrm{d}}\n\
        \\def\\pt#1{} \\newcommand{\\typing}";
    fs::write(root.join("main.tex"), main).unwrap();
    let found = scan(&root).unwrap();
    let commands = found
        .commands
        .iter()
        .map(|c| (c.name.as_str(), c.arguments, c.tex.as_deref()));
    assert_eq!(
        commands.collect::<Vec<_>>(),
        [
            ("\\R", 0, Some("\\def\\R{\\mathbb{R}}")),
            ("\\pair", 2, Some("\\def\\pair#1#2{(#1, #2)}")),
            (
                "\\opt",
                1,
                Some("\\def\\opt{\\texlocal@optional\\opt@{x}}\\def\\opt@#1#2{#1#2}")
            ),
            (
                "\\argmax",
                0,
                Some("\\def\\argmax{\\operatorname*{arg\\,max}}")
            ),
            ("\\epsilon", 0, Some("\\def\\epsilon{\\varepsilon}")),
            ("\\half", 0, Some("\\def\\half{\\frac12}")),
            ("\\d", 0, Some("\\def\\d{\\mathrm{d}}")),
            ("\\typing", 0, None),
        ]
    );
    assert_eq!(found.environments, ["thm"]);
}

#[test]
fn the_symbol_scan_reads_a_file_again_only_once_its_stamp_changes() {
    let (_dir, root) = project();
    let file = root.join("main.tex");
    fs::write(&file, "\\label{one}").unwrap();
    let facts = Files::default();
    let scanned = || labels(scan_symbols(&root, &facts, &HashMap::new()).unwrap());
    assert_eq!(scanned(), ["one"]);
    let modified = fs::metadata(&file).unwrap().modified().unwrap();
    // Written in place at the same length and dated back, it stamps as before.
    fs::write(&file, "\\label{two}").unwrap();
    let written = fs::File::options().write(true).open(&file).unwrap();
    written.set_modified(modified).unwrap();
    assert_eq!(scanned(), ["one"]);
    fs::write(&file, "\\label{three}").unwrap();
    assert_eq!(scanned(), ["three"]);
}

/// The walk the tree, search, the scans, history and export share: links followed to files
/// only, inside or out (a shared .bib), as one to a folder may loop; an entry unreadable read
/// as empty, but by a copy refused; and, with the tree's rule, no dotfiles and no top-level build folder in any case,
/// though a build deeper in is the author's.
#[test]
fn the_walk_follows_links_to_files_only_and_passes_over_what_it_cant_read_unless_copying() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use crate::projects::{listed, walk};
    let (_dir, root) = project();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("shared.bib"), "").unwrap();
    for file in [
        "Build/main.log",
        "chapters/build/notes.tex",
        "figures/a.png",
        "locked/a.tex",
    ] {
        fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
        fs::write(root.join(file), "").unwrap();
    }
    for (target, name) in [
        (outside.path().join("shared.bib"), "shared.bib"),
        (root.join("figures"), "linked-dir"),
        (root.clone(), "loop"),
        (root.join("gone.tex"), "broken.tex"),
    ] {
        symlink(target, root.join(name)).unwrap();
    }
    let lock = |mode| fs::set_permissions(root.join("locked"), fs::Permissions::from_mode(mode));
    lock(0o000).unwrap();
    // Running as root, permissions lock nothing.
    let locked = fs::read_dir(root.join("locked")).is_err();
    let whole = walk(&root, &listed, true, &mut |_| Ok(true)).map_err(|err| err.kind);
    let mut walked = Vec::new();
    let walk = walk(&root, &listed, false, &mut |entry| {
        walked.push(entry.rel.clone());
        Ok(true)
    });
    lock(0o755).unwrap();
    walk.unwrap();
    assert_eq!(
        whole,
        if locked {
            Err(crate::ErrorKind::Denied)
        } else {
            Ok(())
        }
    );
    let mut listed = vec![
        "chapters",
        "chapters/build",
        "chapters/build/notes.tex",
        "figures",
    ];
    listed.extend([
        "figures/a.png",
        "locked",
        "locked/a.tex",
        "main.tex",
        "shared.bib",
    ]);
    listed.retain(|rel| !locked || *rel != "locked/a.tex");
    assert_eq!(walked, listed);
}
