mod common;

use std::fs;
use std::sync::Arc;

use common::{Library, names, write};
use serde_json::{Value, json};
use texlocal_core::ErrorKind;
use texlocal_core::service::Service;

#[tokio::test]
async fn a_new_project_is_listed_with_its_template() {
    let library = Library::new();
    let made = library
        .call(
            "CreateProject",
            json!({ "name": "Paper", "template": "report" }),
        )
        .await;
    assert_eq!(made["name"], "Paper");
    assert_eq!(made["mainFile"], "main.tex");
    assert_eq!(made["opened"], false);
    let root = library.project_root("Paper");
    assert!(root.join("main.tex").is_file() && root.join("references.bib").is_file());
    assert_eq!(names(&library.projects(), "id"), ["Paper"]);
}

#[tokio::test]
async fn a_built_project_lists_its_pdf() {
    let library = Library::new();
    library.create("Paper", "blank").await;
    assert_eq!(library.projects()[0]["pdf"], Value::Null);
    let root = library.project_root("Paper");
    write(&root, &[("build/main.pdf", "%PDF")]);
    assert_eq!(
        library.projects()[0]["pdf"],
        json!(root.join("build/main.pdf"))
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
    let free = library.call("FreeProjectName", json!({})).await;
    assert_eq!(free, "Untitled");
    library.create("Untitled", "blank").await;
    let free = library.call("FreeProjectName", json!({})).await;
    assert_eq!(free, "Untitled 2");
}

#[tokio::test]
async fn bad_names_are_refused() {
    let library = Library::new();
    for name in [".hidden", "   "] {
        let refused = library
            .refuse(
                "CreateProject",
                json!({ "name": name, "template": "blank" }),
            )
            .await;
        assert_eq!(refused, ErrorKind::Invalid, "{name:?}");
    }
    assert_eq!(names(&library.projects(), "id"), Vec::<&str>::new());
}

#[tokio::test]
async fn a_project_is_renamed_unless_the_name_is_taken() {
    let library = Library::new();
    library.create("A", "blank").await;
    library.create("B", "blank").await;
    let taken = library
        .refuse("RenameProject", json!({ "id": "B", "name": "A" }))
        .await;
    assert_eq!(taken, ErrorKind::Conflict);
    write(&library.path("state"), &[(".ui/C.json", "{}")]);
    let renamed = library
        .call("RenameProject", json!({ "id": "B", "name": "C" }))
        .await;
    assert_eq!(renamed["id"], "C");
    assert!(library.path("data/C/main.tex").is_file());
    assert!(!library.path("data/B").exists() && !library.path("state/.ui/C.json").exists());
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
            "DuplicateProject",
            json!({ "id": "Paper", "name": "Paper copy" }),
        )
        .await;
    let root = library.project_root(copy["id"].as_str().unwrap());
    assert!(root.join("main.tex").is_file() && root.join("ch/one.tex").is_file());
    assert!(!root.join("build").exists());
}

#[tokio::test]
async fn a_folder_opens_where_it_is() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("thesis.tex", "\\documentclass{article}")]);
    let opened = library.call("OpenPath", json!({ "path": folder })).await;
    assert_eq!(opened["file"], Value::Null);
    assert_eq!(opened["project"]["opened"], true);
    assert_eq!(opened["project"]["mainFile"], "thesis.tex");
    assert_eq!(
        fs::canonicalize(opened["project"]["path"].as_str().unwrap()).unwrap(),
        fs::canonicalize(&folder).unwrap()
    );
    assert!(!folder.join(".texlocal.json").exists());
    assert!(fs::read_dir(library.path("data")).unwrap().next().is_none());
    let nested = library.path("Nested");
    let thesis = [
        ("figures/plots/plot.tex", "\\documentclass{standalone}"),
        ("src/a.tex", "x"),
        ("src/thesis.tex", "\\documentclass{book}"),
    ];
    write(&nested, &thesis);
    let opened = library.call("OpenPath", json!({ "path": nested })).await;
    assert_eq!(opened["project"]["mainFile"], "src/thesis.tex");
}

#[tokio::test]
async fn device_state_left_in_the_library_moves_to_the_state_folder_once() {
    let library = Library::new();
    let (data, state) = (library.path("data"), library.path("state"));
    let old = Arc::new(Service::new(data.clone(), data.clone(), None));
    let folder = library.path("Thesis");
    write(&folder, &[("main.tex", "x")]);
    let path = json!({ "path": folder });
    let opened = old.call("OpenPath", path).await.unwrap();
    let tex = r#"{"texDir":"/tex"}"#;
    write(&data, &[(".texlocal-app.json", tex)]);
    let moved = Service::new(data.clone(), state.clone(), None);
    for name in [".opened", ".texlocal-app.json"] {
        let (left, landed) = (data.join(name).exists(), state.join(name).exists());
        assert!(!left && landed, "{name}");
    }
    let listed = json!(moved.projects().unwrap());
    assert_eq!(listed[0]["id"], opened["project"]["id"]);
    let read = |name| fs::read_to_string(state.join(name)).unwrap();
    write(&data, &[(".texlocal-app.json", "{}")]);
    Service::new(data.clone(), state.clone(), None);
    assert_eq!(read(".texlocal-app.json"), tex);
    assert!(data.join(".texlocal-app.json").exists());
}

#[tokio::test]
async fn a_folder_whose_settings_file_is_a_link_gets_the_guessed_main_file() {
    let library = Library::new();
    let folder = library.path("Paper");
    write(
        &folder,
        &[
            ("paper.tex", "\\documentclass{article}"),
            ("real.json", "{}"),
        ],
    );
    std::os::unix::fs::symlink("real.json", folder.join(".texlocal.json")).unwrap();
    let opened = library.call("OpenPath", json!({ "path": folder })).await;
    assert_eq!(opened["project"]["mainFile"], "paper.tex");
}

#[tokio::test]
async fn a_tex_file_opens_its_folder_at_that_file() {
    let library = Library::new();
    let folder = library.path("Notes");
    write(&folder, &[("a.tex", "x"), ("b.tex", "y")]);
    let opened = library
        .call("OpenPath", json!({ "path": folder.join("b.tex") }))
        .await;
    assert_eq!(opened["file"], "b.tex");
    let again = library.call("OpenPath", json!({ "path": folder })).await;
    assert_eq!(again["project"]["id"], opened["project"]["id"]);
}

#[tokio::test]
async fn opening_what_is_not_there_or_not_tex_is_refused() {
    let library = Library::new();
    let gone = library
        .refuse("OpenPath", json!({ "path": library.path("gone") }))
        .await;
    assert_eq!(gone, ErrorKind::NotFound);
    let photo = library.path("photo.jpg");
    fs::write(&photo, "jpg").unwrap();
    let refused = library.refuse("OpenPath", json!({ "path": photo })).await;
    assert_eq!(refused, ErrorKind::Invalid);
}

#[tokio::test]
async fn forgetting_a_folder_leaves_it_on_disk() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("main.tex", "x")]);
    let opened = library.call("OpenPath", json!({ "path": folder })).await;
    let id = opened["project"]["id"].clone();
    library.call("ForgetFolder", json!({ "id": id })).await;
    assert_eq!(names(&library.projects(), "id"), Vec::<&str>::new());
    assert!(folder.join("main.tex").is_file());
    library.create("Library", "blank").await;
    let refused = library
        .refuse("ForgetFolder", json!({ "id": "Library" }))
        .await;
    assert_eq!(refused, ErrorKind::Invalid);
}

#[tokio::test]
async fn a_folder_no_longer_where_it_was_is_missing() {
    let library = Library::new();
    let folder = library.path("Thesis");
    write(&folder, &[("main.tex", "x")]);
    library.call("OpenPath", json!({ "path": folder })).await;
    assert_eq!(library.projects()[0]["missing"], false);
    fs::rename(&folder, library.path("Moved")).unwrap();
    let list = library.projects();
    assert_eq!(list[0]["missing"], true);
    assert_eq!(list[0]["mtime"], 0);
}

#[tokio::test]
async fn unknown_commands_and_bad_arguments_are_refused() {
    let library = Library::new();
    assert_eq!(
        library.refuse("no_such_command", json!({})).await,
        ErrorKind::NotFound
    );
    for args in [json!({}), json!([])] {
        let refused = library.refuse("DuplicateProject", args).await;
        assert_eq!(refused, ErrorKind::Invalid);
    }
    let missing = json!({ "id": "Nope", "name": "Copy" });
    let refused = library.refuse("DuplicateProject", missing).await;
    assert_eq!(refused, ErrorKind::NotFound);
}

#[tokio::test]
async fn a_tex_folder_without_latexmk_is_refused() {
    let library = Library::new();
    let empty = library.path("empty");
    fs::create_dir(&empty).unwrap();
    let refused = library.refuse("SetTexDir", json!({ "dir": empty })).await;
    assert_eq!(refused, ErrorKind::Invalid);
    let refused = library
        .refuse("SetTexpressoDir", json!({ "dir": empty }))
        .await;
    assert_eq!(refused, ErrorKind::Invalid);
}

#[tokio::test]
async fn texpressos_install_folder_is_taken_as_its_bin_folder() {
    use std::os::unix::fs::PermissionsExt;
    let library = Library::new();
    let folder = library.path("TeXpresso");
    write(&folder, &[("bin/texpresso", "#!/bin/sh\n")]);
    let program = folder.join("bin/texpresso");
    fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
    let status = library
        .call("SetTexpressoDir", json!({ "dir": folder }))
        .await;
    assert_eq!(status["texpressoDir"], json!(folder.join("bin")));
}

#[tokio::test]
async fn a_zip_opens_without_its_top_folder_litter_or_escapes() {
    use std::io::Write;
    let library = Library::new();
    let path = library.path("Paper.zip");
    let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
    let options = zip::write::SimpleFileOptions::default();
    let entries = [
        "Paper/main.tex",
        "Paper/figs/a.png",
        "__MACOSX/Paper/._main.tex",
        "Paper/../../escape.tex",
        "../escape.tex",
    ];
    for entry in entries {
        zip.start_file(entry, options).unwrap();
        zip.write_all(b"x").unwrap();
    }
    zip.finish().unwrap();
    let opened = library.call("OpenPath", json!({ "path": path })).await;
    let root = library.project_root(opened["project"]["id"].as_str().unwrap());
    assert!(root.join("main.tex").is_file());
    assert!(root.join("figs/a.png").is_file());
    assert!(!root.join("Paper").exists());
    assert!(!root.join("__MACOSX").exists());
    for escaped in [
        root.join("escape.tex"),
        library.path("escape.tex"),
        library.path("data/escape.tex"),
    ] {
        assert!(!escaped.exists(), "{escaped:?}");
    }
}
