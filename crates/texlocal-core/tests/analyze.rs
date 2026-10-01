use std::fs;

use texlocal_core::analyze::analyze_project;

#[test]
fn open_file_aliases_keep_the_whole_document() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("chapters")).unwrap();
    fs::write(
        dir.path().join("main.tex"),
        "\\section{Main}\n\\input{chapters/one}",
    )
    .unwrap();
    fs::write(dir.path().join("chapters/one.tex"), "\\section{One}").unwrap();
    let expected = analyze_project(dir.path(), "main.tex", "chapters/one.tex");
    for open in [
        "./chapters/one.tex",
        "chapters\\one.tex",
        "chapters/../chapters/one.tex",
    ] {
        assert_eq!(
            analyze_project(dir.path(), "main.tex", open),
            expected,
            "{open}"
        );
    }
}

#[test]
fn inputs_accept_texs_unbraced_names() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("main.tex"),
        "\\section{Main}\n\\input chapter\n\\section{End}",
    )
    .unwrap();
    fs::write(dir.path().join("chapter.tex"), "\\section{Chapter}\nbody").unwrap();
    let analysis = analyze_project(dir.path(), "main.tex", "main.tex");
    let titles: Vec<_> = analysis.outline.iter().map(|h| h.title.as_str()).collect();
    assert_eq!(titles, ["Main", "Chapter", "End"]);
}
