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

#[test]
fn inputs_do_not_append_a_second_tex_extension() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("main.tex"), "\\input{part.tex}").unwrap();
    fs::write(dir.path().join("part.tex"), "\\section{Part}").unwrap();
    fs::write(dir.path().join("part.tex.tex"), "\\section{Wrong}").unwrap();
    let analysis = analyze_project(dir.path(), "main.tex", "main.tex");
    assert_eq!(analysis.outline[0].title, "Part");
}

#[test]
fn inputs_inside_literal_and_comment_environments_are_not_followed() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("main.tex"), "\\section{Main}\n\\begin{verbatim}\n\\input{example}\n\\end{verbatim}\n\\begin{comment}\n\\input{example}\n\\end{comment}\n\\verb|\\input{example}|\n\\input{real}").unwrap();
    fs::write(dir.path().join("example.tex"), "\\section{Example}").unwrap();
    fs::write(dir.path().join("real.tex"), "\\section{Real}").unwrap();
    let analysis = analyze_project(dir.path(), "main.tex", "main.tex");
    let titles: Vec<_> = analysis.outline.iter().map(|h| h.title.as_str()).collect();
    assert_eq!(titles, ["Main", "Real"]);
}
