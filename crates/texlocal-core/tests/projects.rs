mod common;

use std::fs;
use std::io::Read;

use common::{Library, kind, write};
use serde_json::{Value, json};
use texlocal_core::ErrorKind;

fn ids(list: &Value) -> Vec<&str> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap())
        .collect()
}

fn zip_names(path: &std::path::Path) -> Vec<String> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    let mut names: Vec<String> = archive.file_names().map(str::to_owned).collect();
    names.sort();
    let _ = archive.by_index(0).unwrap().read(&mut [0; 1]);
    names
}

#[tokio::test]
async fn a_new_project_is_listed_with_its_template() {
    let library = Library::new();
    let made = library
        .call(
            "create_project",
            json!({ "name": "Paper", "template": "report" }),
        )
        .await;
    assert_eq!(made["name"], "Paper");
    assert_eq!(made["mainFile"], "main.tex");
    assert_eq!(made["opened"], false);
    let root = library.project_root("Paper");
    assert!(root.join("main.tex").is_file() && root.join("references.bib").is_file());
    assert_eq!(
        ids(&library.call("list_projects", json!({})).await),
        ["Paper"]
    );
}

#[tokio::test]
async fn a_taken_name_is_numbered() {
    let library = Library::new();
    library.create("Paper", "blank").await;
    assert_eq!(library.create("Paper", "blank").await, "Paper 2");
}

#[tokio::test]
async fn the_free_name_is_the_next_untitled() {
    let library = Library::new();
    let free = library.call("free_project_name", json!({})).await;
    assert_eq!(free["name"], "Untitled");
    library.create("Untitled", "blank").await;
    let free = library.call("free_project_name", json!({})).await;
    assert_eq!(free["name"], "Untitled 2");
}

#[tokio::test]
async fn bad_names_and_engines_are_refused() {
    let library = Library::new();
    for name in [".hidden", "   "] {
        let refused = library
            .service
            .call("create_project", json!({ "name": name }))
            .await;
        assert_eq!(kind(refused), ErrorKind::Invalid, "{name:?}");
    }
    let refused = library
        .service
        .call("create_project", json!({ "name": "E", "engine": "word" }))
        .await;
    assert_eq!(kind(refused), ErrorKind::Invalid);
    assert_eq!(
        ids(&library.call("list_projects", json!({})).await),
        Vec::<&str>::new()
    );
}

#[tokio::test]
async fn a_project_is_renamed_unless_the_name_is_taken() {
    let library = Library::new();
    library.create("A", "blank").await;
    library.create("B", "blank").await;
    let taken = library
        .refuse("rename_project", json!({ "id": "B", "name": "A" }))
        .await;
    assert_eq!(taken.kind, ErrorKind::Conflict);
    let renamed = library
        .call("rename_project", json!({ "id": "B", "name": "C" }))
        .await;
    assert_eq!(renamed["id"], "C");
    assert!(library.path("data/C/main.tex").is_file());
    assert!(!library.path("data/B").exists());
}

#[tokio::test]
async fn a_duplicate_copies_the_sources_but_not_the_build() {
    let library = Library::new();
    library.create("Paper", "article").await;
    write(
        &library.project_root("Paper"),
        &[("build/main.pdf", "pdf"), ("ch/one.tex", "x")],
    );
    let copy = library
        .call(
            "duplicate_project",
            json!({ "id": "Paper", "name": "Paper copy" }),
        )
        .await;
    let root = library.project_root(copy["id"].as_str().unwrap());
    assert!(root.join("main.tex").is_file() && root.join("ch/one.tex").is_file());
    assert!(!root.join("build").exists());
}

#[tokio::test]
async fn the_tree_marks_the_main_file_and_hides_dotfiles() {
    let library = Library::new();
    library.create("Paper", "article").await;
    write(
        &library.project_root("Paper"),
        &[(".latexmkrc", ""), ("figs/a.png", "png")],
    );
    let tree = library.call("file_tree", json!({ "id": "Paper" })).await;
    let names: Vec<&str> = tree
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"figs") && names.contains(&"main.tex"));
    assert!(!names.iter().any(|n| n.starts_with('.')));
    let main = tree
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["name"] == "main.tex")
        .unwrap();
    assert_eq!(main["main"], true);
    assert_eq!(main["kind"], "tex");
}

#[tokio::test]
async fn a_folder_opens_where_it_is() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("thesis.tex", "\\documentclass{article}")]);
    let opened = library.call("open_path", json!({ "path": folder })).await;
    assert_eq!(opened["file"], Value::Null);
    assert_eq!(opened["project"]["opened"], true);
    assert_eq!(opened["project"]["mainFile"], "thesis.tex");
    assert_eq!(
        fs::canonicalize(opened["project"]["path"].as_str().unwrap()).unwrap(),
        fs::canonicalize(&folder).unwrap()
    );
    assert!(!folder.join(".texlocal.json").exists());
}

#[tokio::test]
async fn a_tex_file_opens_its_folder_at_that_file() {
    let library = Library::new();
    let folder = library.path("Notes");
    write(&folder, &[("a.tex", "x"), ("b.tex", "y")]);
    let opened = library
        .call("open_path", json!({ "path": folder.join("b.tex") }))
        .await;
    assert_eq!(opened["file"], "b.tex");
    let again = library.call("open_path", json!({ "path": folder })).await;
    assert_eq!(again["project"]["id"], opened["project"]["id"]);
}

#[tokio::test]
async fn opening_what_is_not_there_or_not_tex_is_refused() {
    let library = Library::new();
    let gone = library
        .service
        .call("open_path", json!({ "path": library.path("gone") }))
        .await;
    assert_eq!(kind(gone), ErrorKind::NotFound);
    let photo = library.path("photo.jpg");
    fs::write(&photo, "jpg").unwrap();
    let refused = library
        .service
        .call("open_path", json!({ "path": photo }))
        .await;
    assert_eq!(kind(refused), ErrorKind::Invalid);
}

#[tokio::test]
async fn forgetting_a_folder_leaves_it_on_disk() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("main.tex", "x")]);
    let opened = library.call("open_path", json!({ "path": folder })).await;
    let id = opened["project"]["id"].clone();
    library.call("forget_folder", json!({ "id": id })).await;
    assert_eq!(
        ids(&library.call("list_projects", json!({})).await),
        Vec::<&str>::new()
    );
    assert!(folder.join("main.tex").is_file());
    library.create("Library", "blank").await;
    let refused = library
        .service
        .call("forget_folder", json!({ "id": "Library" }))
        .await;
    assert_eq!(kind(refused), ErrorKind::Invalid);
}

#[tokio::test]
async fn a_folder_no_longer_where_it_was_is_missing() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("main.tex", "x")]);
    library.call("open_path", json!({ "path": folder })).await;
    assert_eq!(
        library.call("list_projects", json!({})).await[0]["missing"],
        false
    );
    fs::rename(&folder, library.path("Moved")).unwrap();
    let list = library.call("list_projects", json!({})).await;
    assert_eq!(list[0]["missing"], true);
    assert_eq!(list[0]["mtime"], 0);
}

#[tokio::test]
async fn the_ui_state_keeps_what_it_is_given() {
    let library = Library::new();
    library.create("Paper", "blank").await;
    let state = library
        .call(
            "set_ui_state",
            json!({ "id": "Paper", "patch": { "openFile": "main.tex", "line": 12 } }),
        )
        .await;
    assert_eq!(state["openFile"], "main.tex");
    assert_eq!(state["line"], 12);
    let again = library
        .call(
            "set_ui_state",
            json!({ "id": "Paper", "patch": { "zoom": 1.5 } }),
        )
        .await;
    assert_eq!(again["line"], 12);
    assert_eq!(again["zoom"], 1.5);
}

#[tokio::test]
async fn an_export_holds_the_sources_without_build_or_settings() {
    let library = Library::new();
    library.create("Paper", "article").await;
    write(
        &library.project_root("Paper"),
        &[("build/main.pdf", "pdf"), (".git/HEAD", "x")],
    );
    let dest = library.path("out.zip");
    library
        .call("export_zip", json!({ "id": "Paper", "dest": dest }))
        .await;
    assert_eq!(zip_names(&dest), ["main.tex", "references.bib"]);
}

#[tokio::test]
async fn an_arxiv_export_adds_its_readme_and_refuses_lualatex() {
    let library = Library::new();
    library.create("Paper", "article").await;
    let dest = library.path("arxiv.zip");
    library
        .call(
            "export_zip",
            json!({ "id": "Paper", "dest": dest, "forArxiv": true }),
        )
        .await;
    assert!(zip_names(&dest).contains(&"00README.json".to_owned()));
    let root = library.project_root("Paper");
    fs::write(root.join(".texlocal.json"), r#"{"engine": "lualatex"}"#).unwrap();
    let refused = library
        .service
        .call(
            "export_zip",
            json!({ "id": "Paper", "dest": library.path("b.zip"), "forArxiv": true }),
        )
        .await;
    assert_eq!(kind(refused), ErrorKind::Conflict);
}

#[tokio::test]
async fn a_zip_opens_as_a_new_project() {
    let library = Library::new();
    library.create("Paper", "article").await;
    let dest = library.path("Shared.zip");
    library
        .call("export_zip", json!({ "id": "Paper", "dest": dest }))
        .await;
    let opened = library.call("open_path", json!({ "path": dest })).await;
    assert_eq!(opened["project"]["name"], "Shared");
    assert_eq!(opened["project"]["opened"], false);
    assert!(library.project_root("Shared").join("main.tex").is_file());
}

#[tokio::test]
async fn files_are_imported_and_a_name_taken_is_asked_about() {
    let library = Library::new();
    library.create("Paper", "blank").await;
    let image = library.path("plot.png");
    fs::write(&image, "png").unwrap();
    let args = json!({ "id": "Paper", "dir": "figs", "paths": [image] });
    let first = library.call("import_files", args.clone()).await;
    assert_eq!(first["existing"], json!([]));
    let root = library.project_root("Paper");
    assert_eq!(fs::read(root.join("figs/plot.png")).unwrap(), b"png");
    let second = library.call("import_files", args.clone()).await;
    assert_eq!(
        second["existing"],
        json!([{ "path": "plot.png", "keepBoth": "plot 2.png" }])
    );
    let mut keep = args;
    keep["conflict"] = json!("keepBoth");
    library.call("import_files", keep).await;
    assert!(root.join("figs/plot 2.png").is_file());
}

#[tokio::test]
async fn unknown_commands_and_bad_arguments_are_refused() {
    let library = Library::new();
    assert_eq!(
        kind(library.service.call("no_such_command", json!({})).await),
        ErrorKind::NotFound
    );
    assert_eq!(
        kind(library.service.call("file_tree", json!({})).await),
        ErrorKind::Invalid
    );
    assert_eq!(
        kind(library.service.call("file_tree", json!([])).await),
        ErrorKind::Invalid
    );
    assert_eq!(
        kind(
            library
                .service
                .call("file_tree", json!({ "id": "Nope" }))
                .await
        ),
        ErrorKind::NotFound
    );
}

#[tokio::test]
async fn a_tex_folder_without_latexmk_is_refused() {
    let library = Library::new();
    let empty = library.path("empty");
    fs::create_dir(&empty).unwrap();
    let refused = library
        .service
        .call("set_tex_dir", json!({ "dir": empty }))
        .await;
    assert_eq!(kind(refused), ErrorKind::Invalid);
    let refused = library
        .service
        .call("set_texpresso_dir", json!({ "dir": empty }))
        .await;
    assert_eq!(kind(refused), ErrorKind::Invalid);
}

#[tokio::test]
async fn a_zip_cannot_write_outside_its_project() {
    use std::io::Write;
    let library = Library::new();
    let path = library.path("evil.zip");
    let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
    let options = zip::write::SimpleFileOptions::default();
    zip.start_file("main.tex", options).unwrap();
    zip.write_all(b"\\documentclass{article}").unwrap();
    zip.start_file("../escape.tex", options).unwrap();
    zip.write_all(b"x").unwrap();
    zip.finish().unwrap();
    let opened = library
        .service
        .call("open_path", json!({ "path": path }))
        .await;
    assert!(!library.path("escape.tex").exists());
    assert!(!library.path("data/escape.tex").exists());
    if let Ok(opened) = opened {
        let root = library.project_root(opened["project"]["id"].as_str().unwrap());
        assert!(root.join("main.tex").is_file());
    }
}
