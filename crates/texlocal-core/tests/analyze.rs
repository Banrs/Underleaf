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
