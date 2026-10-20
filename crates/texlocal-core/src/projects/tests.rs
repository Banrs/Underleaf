//! Tests across the projects module's parts: renames under the settings' and
//! the paths' rules, the library, search, the symbol scan, and links.

use std::fs;

use serde_json::json;

use crate::CoreError;
use crate::analyze::Files;
use crate::projects::testing::{fails_with, library, names_in, project};
use crate::projects::{
    Symbols, create_free, create_project, file_tree, list_projects, rename_entry, rename_project,
    scan_symbols, search_project,
};
use crate::settings::{read_settings, write_settings};

#[test]
fn a_rename_that_cannot_write_the_settings_is_undone_and_leaves_them_as_they_were() {
    let (_dir, root) = project();
    let file = root.join(".texlocal.json");
    let broken = "{ \"mainFile\": \"paper.tex\", \"engine\": \"xelatex\", }";
    fs::write(&file, broken).unwrap();
    assert_eq!(
        rename_entry(&root, "main.tex", "a.tex").unwrap_err().status,
        409
    );
    assert!(root.join("main.tex").is_file() && !root.join("a.tex").exists());
    create_free(&root, "b.tex", false).unwrap();
    rename_entry(&root, "b.tex", "c.tex").unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), broken);
}

#[test]
fn a_rename_takes_the_main_file_along_only_when_it_holds_it_and_keeps_to_the_rules() {
    let (_dir, root) = project();
    create_free(&root, "chapters/main.tex", false).unwrap();
    create_free(&root, "chapters2/other.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
    let result = rename_entry(&root, "chapters", "content").unwrap();
    assert_eq!(result.main_file, "content/main.tex");
    assert_eq!(read_settings(&root).main_file, "content/main.tex");
    create_free(&root, "chapters/x.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters2/other.tex" })).unwrap();
    rename_entry(&root, "chapters", "moved").unwrap();
    assert_eq!(read_settings(&root).main_file, "chapters2/other.tex");
    let err = rename_entry(&root, "moved", "moved/old/moved").unwrap_err();
    assert_eq!(err.status, 400, "{}", err.message);
    assert_eq!(names_in(&root.join("moved")), ["x.tex"]);
    // create_entry and uploads accept a leading "-"; only the main file, which
    // reaches latexmk's command line, may not start with one.
    create_free(&root, "-draft.tex", false).unwrap();
    let result = rename_entry(&root, "-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(result.to, "-notes/-draft.tex");
    assert!(root.join("-notes/-draft.tex").is_file());
}

#[test]
fn a_case_only_rename_works_on_case_insensitive_volumes_too() {
    let (_dir, root) = project();
    let data = root.parent().unwrap();
    create_free(&root, "Figures/plot.tex", false).unwrap();

    let result = rename_entry(&root, "main.tex", "Main.tex").unwrap();
    assert_eq!(result.main_file, "Main.tex");
    assert_eq!(read_settings(&root).main_file, "Main.tex");
    rename_entry(&root, "Figures", "figures").unwrap();
    assert_eq!(names_in(&root), [".texlocal.json", "Main.tex", "figures"]);

    create_free(&root, "other.tex", false).unwrap();
    let err = rename_entry(&root, "other.tex", "Main.tex").unwrap_err();
    assert_eq!(err.status, 409);

    rename_project(data, "P", "p", |_| Ok(())).unwrap();
    assert_eq!(names_in(data), ["p"]);
    create_project(data, "second", "blank", None).unwrap();
    let err = rename_project(data, "second", "p", |_| panic!("moved")).unwrap_err();
    assert_eq!(err.status, 409);
}

#[test]
fn a_rename_that_doesnt_go_ahead_leaves_no_folder_of_the_new_name() {
    let (_dir, root) = project();
    let data = root.parent().unwrap();
    let stopped = rename_project(data, "P", "S", |_| Err(CoreError::conflict("no")));
    assert_eq!(stopped.unwrap_err().status, 409);
    assert_eq!(names_in(data), ["P"]);
}

#[cfg(unix)]
#[test]
fn an_unreadable_folder_or_file_does_not_fail_the_scans() {
    use std::os::unix::fs::PermissionsExt;
    let (_dir, root) = project();
    fs::write(root.join("main.tex"), "\\label{sec:open} needle\n").unwrap();
    create_free(&root, "locked/inside.tex", false).unwrap();
    fs::write(root.join("secret.tex"), "needle").unwrap();
    let lock =
        |path: &std::path::Path, mode| fs::set_permissions(path, fs::Permissions::from_mode(mode));
    lock(&root.join("locked"), 0o000).unwrap();
    lock(&root.join("secret.tex"), 0o000).unwrap();
    if fs::read_dir(root.join("locked")).is_ok() {
        // Running as root, where permissions don't lock anything.
        lock(&root.join("locked"), 0o755).unwrap();
        return;
    }

    let tree = file_tree(&root);
    let hits = search_project(&root, "needle", 100);
    let symbols = scan_symbols(&root, &Files::default());
    lock(&root.join("locked"), 0o755).unwrap();

    let tree = tree.unwrap();
    let locked = tree.iter().find(|n| n.name == "locked").unwrap();
    assert!(locked.children.as_ref().unwrap().is_empty());
    let hits = hits.unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].file, "main.tex");
    assert_eq!(symbols.unwrap().labels, ["sec:open"]);
}

#[test]
fn search_folds_case_cuts_its_snippet_at_the_match_and_stops_at_the_limit() {
    let (_dir, root) = project();
    for (file, text) in [
        ("ascii.tex", "One\nThe THEOREM holds\n"),
        ("accents.tex", "L'ÉCOLE Normale\nStraße\n"),
        ("figure.svg", "<text>theorem</text>\n"),
        ("mixed.tex", "Café\nsee Lemma 3\n"),
        ("wide.tex", "Çà İstanbul, GRÖSSE und Größe\n"),
        ("quick.tex", "the quick brown fox jumps\n"),
        ("kelvin.tex", "measured 5 \u{212A} today\n"),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    let hit = |query: &str| {
        let hits = search_project(&root, query, 50).unwrap();
        assert_eq!(hits.len(), 1, "{query}");
        let hit = &hits[0];
        let (file, line) = (&hit.file, hit.line);
        format!("{file}:{line} {}[{}]{}", hit.before, hit.matched, hit.after)
    };
    assert_eq!(hit("theorem"), "ascii.tex:2 The [THEOREM] holds");
    assert_eq!(hit("école"), "accents.tex:1 L'[ÉCOLE] Normale");
    assert!(search_project(&root, "zzz", 50).unwrap().is_empty());
    assert_eq!(hit("lemma"), "mixed.tex:2 see [Lemma] 3");
    assert_eq!(hit("größe"), "wide.tex:1 Çà İstanbul, GRÖSSE und [Größe]");
    assert_eq!(hit("brown"), "quick.tex:1 the quick [brown] fox jumps");
    let files = |query: &str| -> Vec<String> {
        let hits = search_project(&root, query, 50).unwrap();
        hits.into_iter().map(|hit| hit.file).collect()
    };
    assert!(files("istanbul").contains(&"wide.tex".to_string()));
    assert!(files("k").contains(&"kelvin.tex".to_string()));
    fs::write(root.join("many.tex"), "needle\n".repeat(20)).unwrap();
    let hits = search_project(&root, "needle", 5).unwrap();
    assert_eq!(hits.len(), 5);
    assert!(hits.iter().all(|h| h.file == "many.tex"));
}

/// An editor host selects the match itself, so a hit places it in UTF-16
/// units of the line as written, not of its lowercased copy.
#[test]
fn a_hit_places_its_match_in_utf16_units_of_the_line() {
    let (_dir, root) = project();
    let hit = |text: &str, query: &str| {
        fs::write(root.join("main.tex"), text).unwrap();
        let mut hits = search_project(&root, query, 50).unwrap();
        assert_eq!(hits.len(), 1, "{text:?}");
        let hit = hits.remove(0);
        (hit.line, hit.column, hit.length, hit.matched)
    };
    let place = hit("intro\nthe brown, brown fox\n", "brown");
    assert_eq!(place, (2, 4, 5, "brown".into()));
    let place = hit("\u{1F600} see a\u{1D538}b\n", "a\u{1D538}b");
    assert_eq!(place, (1, 7, 4, "a\u{1D538}b".into()));
    let place = hit("İ \u{212A} \u{1F600} GRÖẞE und\n", "größe");
    assert_eq!(place, (1, 7, 5, "GRÖẞE".into()));
}

/// Only the project's own top-level build/ is compile output, in any case: no
/// file of the author's takes its name, and the tree and the scans leave it
/// out. A `build` deeper in is the author's: the tree lists it and the export
/// archives it, so search and the symbol scan see it too.
#[test]
fn only_the_top_level_build_folder_is_the_compile_outputs() {
    let (_dir, root) = project();
    fails_with(create_free(&root, "build", true), "compiled PDF");
    fails_with(create_free(&root, "BUILD/x.tex", false), "compiled PDF");
    create_free(&root, "figs/a.png", false).unwrap();
    fails_with(rename_entry(&root, "figs", "Build"), "compiled PDF");
    fs::create_dir(root.join("Build")).unwrap();
    fs::write(root.join("Build/main.tex"), "needle \\label{gen:one}\n").unwrap();
    fs::write(root.join("Build/main.log"), "needle in the build dir").unwrap();
    create_free(&root, "chapters/build/notes.tex", false).unwrap();
    let notes = "a needle and \\label{deep:one}\n";
    fs::write(root.join("chapters/build/notes.tex"), notes).unwrap();

    assert!(file_tree(&root).unwrap().iter().all(|n| n.name != "Build"));
    let hits = search_project(&root, "needle", 10).unwrap();
    let files: Vec<_> = hits.iter().map(|h| h.file.as_str()).collect();
    assert_eq!(files, ["chapters/build/notes.tex"]);
    assert_eq!(
        scan_symbols(&root, &Files::default()).unwrap().labels,
        ["deep:one"]
    );
}

#[test]
fn a_project_is_dated_by_its_newest_file() {
    let (_dir, root) = project();
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    let main = fs::File::options().write(true).open(root.join("main.tex"));
    main.unwrap().set_modified(later).unwrap();
    let since = later.duration_since(std::time::UNIX_EPOCH).unwrap();
    let mtime = list_projects(root.parent().unwrap()).unwrap()[0].mtime;
    assert_eq!(mtime, since.as_millis() as u64);
}

#[test]
fn symbol_scan_survives_both_a_bad_byte_and_a_unicode_space() {
    // Latin-1 .bib files: a Unicode-mode pattern over raw bytes drops the whole entry; decoding first keeps it.
    let (_dir, root) = project();
    let mut bib = b"@article{m".to_vec();
    bib.push(0xFC); // 'u-umlaut' in ISO-8859-1; invalid on its own as UTF-8
    bib.extend_from_slice(b"ller2020,\n  title={x}\n}\n@article{ok2021,\n  title={y}\n}\n");
    fs::write(root.join("refs.bib"), &bib).unwrap();

    let mut tex = b"\\label{fig:m".to_vec();
    tex.push(0xFC);
    tex.extend_from_slice(b"ller}\n\\label{fig:ok}\n");
    fs::write(root.join("ch.tex"), &tex).unwrap();

    // A non-breaking space before the brace mustn't be swallowed into the key by an ASCII-only `\s`.
    fs::write(
        root.join("pasted.bib"),
        "@article{Smith2020\u{00A0},\n  title={x}\n}\n@article\u{00A0}{Jones2021,\n  title={y}\n}\n",
    )
    .unwrap();

    let Symbols {
        citations, labels, ..
    } = scan_symbols(&root, &Files::default()).unwrap();
    assert_eq!(citations.len(), 4, "{citations:?}");
    assert_eq!(citations[..2], ["Smith2020", "Jones2021"]);
    assert!(citations[2].contains("ller2020") && citations[3] == "ok2021");
    assert_eq!(labels.len(), 2, "{labels:?}");
    assert!(labels[0].contains("ller") && labels[1] == "fig:ok");
}

#[test]
fn symbol_scan_reads_bibitems_skips_comments_and_keeps_file_order() {
    let (_dir, root) = project();
    fs::write(
        root.join("main.tex"),
        "\\label{kept} % \\label{old}\n% \\bibitem{gone}\n50\\% \\label{after-percent} \\label{fig:}\n\
         \\begin{verbatim}\\label{literal}\\end{verbatim} \\label {spaced}\n\
         \\begin{equation} x \\label{eq:one} \\end{equation}\n\
         \\begin{thebibliography}{9}\n\\bibitem[K]{knuth} Knuth.\n\\bibitem {lamport} Lamport.\n",
    )
    .unwrap();
    let found = scan_symbols(&root, &Files::default()).unwrap();
    assert_eq!(found.labels, ["kept", "after-percent", "spaced", "eq:one"]);
    assert_eq!(found.citations, ["knuth", "lamport"]);

    fs::remove_file(root.join("main.tex")).unwrap();
    for (file, text) in [
        ("z.tex", "\\label{shared}\\label{last}\\bibitem{two}"),
        ("a.tex", "\\label{first}\\label{shared}\\bibitem{one}"),
        (
            "refs.bib",
            "@article{one,}\n@string{s=\"x\",}\n@Comment{gone,}\n@preamble{p,}\n@misc(three,)",
        ),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    let found = scan_symbols(&root, &Files::default()).unwrap();
    assert_eq!(found.labels, ["first", "shared", "last"]);
    assert_eq!(found.citations, ["one", "three", "two"]);
}

#[test]
fn the_symbol_scan_reads_a_file_again_only_once_its_stamp_changes() {
    let (_dir, root) = project();
    let file = root.join("main.tex");
    fs::write(&file, "\\label{one}").unwrap();
    let facts = Files::default();
    assert_eq!(scan_symbols(&root, &facts).unwrap().labels, ["one"]);
    let modified = fs::metadata(&file).unwrap().modified().unwrap();
    // Written in place at the same length and dated back, it stamps as before.
    fs::write(&file, "\\label{two}").unwrap();
    let written = fs::File::options().write(true).open(&file).unwrap();
    written.set_modified(modified).unwrap();
    assert_eq!(scan_symbols(&root, &facts).unwrap().labels, ["one"]);
    fs::write(&file, "\\label{three}").unwrap();
    assert_eq!(scan_symbols(&root, &facts).unwrap().labels, ["three"]);
}

#[test]
fn new_projects_are_named_sanitized_and_stocked_with_a_template() {
    let (_dir, service) = library();
    let data = &service.data_dir;
    fails_with(create_project(data, "   ", "blank", None), "Invalid name");
    let info = create_project(data, "  Thesis  ", "report", None).unwrap();
    assert_eq!((info.id.as_str(), info.name.as_str()), ("Thesis", "Thesis"));
    assert_eq!(info.main_file, "main.tex");
    let root = data.join("Thesis");
    assert_eq!(
        names_in(&root),
        [".texlocal.json", "main.tex", "references.bib"]
    );
    let main = fs::read_to_string(root.join("main.tex")).unwrap();
    assert!(main.contains("{report}"));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(data.join("gone"), data.join("linked")).unwrap();
        assert_eq!(
            create_project(data, "linked", "blank", None).unwrap().id,
            "linked 2"
        );
        assert!(!data.join("gone").exists());
    }
}

#[cfg(unix)]
#[test]
fn the_tree_scans_and_zip_follow_links_to_files_only() {
    // A link to a file, inside or out (a shared .bib), is content. One to a
    // folder, broken or in a loop is not, and is no error.
    use crate::{projects::testing::zip_names, zipexport::export_zip};
    let (_dir, root) = project();
    let outside = tempfile::tempdir().unwrap();
    let shared = outside.path().join("shared.tex");
    fs::write(&shared, "\\label{shared}\n").unwrap();
    fs::write(root.join("source.txt"), "needle \\label{linked}").unwrap();
    fs::create_dir(root.join("figures")).unwrap();
    fs::write(root.join("figures/a.txt"), "figure").unwrap();
    let link = |target: &std::path::Path, name: &str| {
        std::os::unix::fs::symlink(target, root.join(name)).unwrap();
    };
    link(&root.join("source.txt"), "linked.tex");
    link(&shared, "external.tex");
    link(&root.join("figures"), "linked-dir");
    link(&root, "loop");
    link(&root.join("gone.tex"), "broken.tex");
    link(&root.join("b.tex"), "a.tex");
    link(&root.join("a.tex"), "b.tex");
    let alias = root.with_file_name("alias");
    std::os::unix::fs::symlink(&root, &alias).unwrap();

    let tree = file_tree(&root).unwrap();
    let top: Vec<_> = tree.iter().map(|n| n.path.as_str()).collect();
    assert_eq!(
        top,
        [
            "figures",
            "external.tex",
            "linked.tex",
            "main.tex",
            "source.txt"
        ]
    );
    let hits = search_project(&root, "needle", 10).unwrap();
    let mut hits: Vec<_> = hits.into_iter().map(|hit| hit.file).collect();
    hits.sort();
    assert_eq!(hits, ["linked.tex", "source.txt"]);
    let mut labels = scan_symbols(&root, &Files::default()).unwrap().labels;
    labels.sort();
    assert_eq!(labels, ["linked", "shared"]);
    let dest = root.with_file_name("out.zip");
    export_zip(&root, &dest).unwrap();
    assert_eq!(
        zip_names(&dest),
        [
            "external.tex",
            "figures/",
            "figures/a.txt",
            "linked.tex",
            "main.tex",
            "source.txt"
        ]
    );
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let mut body = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("linked.tex").unwrap(), &mut body).unwrap();
    assert_eq!(body, "needle \\label{linked}");

    // The destination spelled through a link into the project, as when a Save
    // panel hands back /private/var for a data folder under /var: a lexical
    // comparison would archive the ZIP's own half-written temporary file.
    export_zip(&root, &alias.join("again.zip")).unwrap();
    assert_eq!(zip_names(&root.join("again.zip")), zip_names(&dest));
}
