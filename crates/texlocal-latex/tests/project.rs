use std::sync::Arc;

use serde_json::Value;
use texlocal_latex::analyze::{self, Facts, Place};
use texlocal_latex::checks;
use texlocal_latex::syntax::{Installed, Symbols};
use texlocal_latex::{FileKind, file_kind};

fn project(files: &[(&str, &str)], installed: &[&str]) -> Symbols {
    let read = |&(name, text): &(&str, &str)| {
        (
            name.to_owned(),
            Arc::new(Facts::read(text, file_kind(name))),
        )
    };
    Symbols {
        files: files.iter().map(|(name, _)| (*name).to_owned()).collect(),
        by_file: files.iter().map(read).collect(),
        installed: Arc::new(Installed {
            inputs: installed.iter().map(|&input| input.to_owned()).collect(),
            ..Installed::default()
        }),
        ..Symbols::default()
    }
}

fn found(symbols: &Symbols) -> Vec<(String, u32, String)> {
    let items = checks::check(symbols, "main.tex").into_iter();
    let item =
        |i: texlocal_latex::logparse::LogItem| (i.file.unwrap(), i.line.unwrap(), i.message.text);
    items.map(item).collect()
}

fn titles(tree: &Value) -> Vec<&str> {
    let nodes = tree.as_array().unwrap().iter();
    nodes
        .map(|node| node["heading"]["title"].as_str().unwrap())
        .collect()
}

const MAIN: &str = "\\documentclass{article}
\\begin{document}
\\section{Intro}\\label{intro}
See \\ref{intro}, \\ref{nowhere}, \\cite{known} and \\cite{unknown}.
\\input{ch}
\\input{missing}
\\bibliography{refs}
\\end{document}
";

#[test]
fn checks_find_twice_defined_and_undefined_names_and_missing_files() {
    let ch = "\\section{Chapter}\\label{intro}\n";
    let refs = "@article{known, title={A}}\n";
    let symbols = project(
        &[("main.tex", MAIN), ("ch.tex", ch), ("refs.bib", refs)],
        &["size10"],
    );
    let item = |file: &str, line, message: &str| (file.to_owned(), line, message.to_owned());
    assert_eq!(
        found(&symbols),
        [
            item(
                "ch.tex",
                1,
                "The label “intro” is defined already, on line 3 of main.tex."
            ),
            item("main.tex", 4, "No label “nowhere” is defined."),
            item("main.tex", 4, "No citation “unknown” is defined."),
            item("main.tex", 6, "No file “missing” is in the project."),
        ]
    );
}

#[test]
fn checks_trust_inputs_tex_has_and_skip_citations_without_their_bib() {
    let symbols = project(&[("main.tex", MAIN), ("ch.tex", "")], &[]);
    let found = found(&symbols);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].2, "No label “nowhere” is defined.");
}

#[test]
fn checks_find_unclosed_and_stray_groups() {
    let main = "\\begin{document}\n\\begin{itemize}\n\\item a}\n\\end{document}\n";
    let item = |line, message: &str| ("main.tex".to_owned(), line, message.to_owned());
    assert_eq!(
        found(&project(&[("main.tex", main)], &[])),
        [
            item(3, "This } has nothing to close."),
            item(4, "\\begin{itemize} on line 2 is ended by \\end{document}."),
        ]
    );
    let main = "\\begin{document}\n$x\n\nnext {\n\\end{document}\n";
    assert_eq!(
        found(&project(&[("main.tex", main)], &[])),
        [
            item(2, "This $ is still open where the paragraph ends."),
            item(4, "This { is never closed."),
        ]
    );
}

#[test]
fn checks_pair_environments_across_inputs_and_trust_unreadable_ones() {
    let main = "\\input{head}\nText.\n\\input{tail}\n";
    let head = "\\documentclass{article}\n\\begin{document}\n";
    let files = [
        ("main.tex", main),
        ("head.tex", head),
        ("tail.tex", "\\end{document}\n"),
    ];
    assert!(found(&project(&files, &[])).is_empty());
    let main = "\\begin{document}\n\\input{\\jobname-body}\n";
    assert!(found(&project(&[("main.tex", main)], &[])).is_empty());
}

#[test]
fn facts_read_names_packages_and_commands() {
    let text = "\\usepackage{amsmath,graphicx}\n\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\begin{document}\n\\label{eq}\n\\section{The \\emph{Start}}\\label{start}\n\\caption{A cat} \\label{cat}\n";
    let facts = Facts::read(text, FileKind::Tex);
    assert_eq!(facts.packages, ["amsmath", "graphicx"]);
    let commands: Vec<&str> = facts.commands.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(commands, ["\\vect"]);
    assert_eq!(facts.labels[0].name, "eq");
    assert_eq!(facts.labels[0].place.line, 4);
    let details: Vec<_> = facts.labels.iter().map(|l| l.detail.as_deref()).collect();
    assert_eq!(details, [None, Some("The Start"), Some("A cat")]);
    let end_of_line_1 = Place {
        line: 1,
        column: 29,
        length: 0,
    };
    assert_eq!(facts.new_package, Some(end_of_line_1));
    let bib = Facts::read(
        "@book{a, title={A}}\n@comment{b,}\n@misc{c,}\n@article{d, author={Knuth, Donald and Leslie Lamport and Other, A}, year=1984}",
        FileKind::Bib,
    );
    let keys: Vec<&str> = bib.citations.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(keys, ["a", "c", "d"]);
    let details: Vec<_> = bib.citations.iter().map(|c| c.detail.as_deref()).collect();
    assert_eq!(details, [Some("A"), None, Some("Knuth et al. · 1984")]);
}

#[test]
fn the_outline_nests_headings_across_inputs_and_counts_words() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\section{One}\nA b c.\n\\subsection{Two}\nD e.\n\\input{ch}\n\\end{document}\nNotes after the end.\n";
    let ch = "\\section{Three}\nF.\n";
    let symbols = project(
        &[
            ("main.tex", main),
            ("ch.tex", ch),
            ("lone.tex", "\\section{Lone}\n"),
        ],
        &[],
    );
    let analysis = analyze::analyze_project(&symbols, Some("main.tex"), None);
    assert_eq!(analysis.files, ["main.tex", "ch.tex"]);
    let outline = serde_json::to_value(&analysis).unwrap();
    assert_eq!(titles(&outline["tree"]), ["One", "Three"]);
    assert_eq!(titles(&outline["tree"][0]["children"]), ["Two"]);
    assert_eq!(outline["tree"][1]["heading"]["file"], "ch.tex");
    assert_eq!(outline["words"], 9);
    let tree = &outline["tree"];
    let words = [&tree[0], &tree[0]["children"][0], &tree[1]].map(|node| &node["words"]);
    assert_eq!(words, [7, 3, 2]);
    let lone = analyze::analyze_project(&symbols, Some("main.tex"), Some("lone.tex"));
    assert_eq!(lone.files, ["lone.tex"]);
    let shown = analyze::analyze_project(&symbols, Some("main.tex"), Some("ch.tex"));
    assert_eq!(shown.files, ["main.tex", "ch.tex"]);
}

#[test]
fn a_bib_entry_reads_as_authors_title_year_and_where() {
    let bib = "@book{knuth,\n  author = {Knuth, Donald E. and Lamport, Leslie},\n  title = {The {TeX}book},\n  year = 1984,\n  publisher = {Addison-Wesley}\n}\n";
    let entry = analyze::bib_entry(bib, "knuth");
    assert_eq!(
        entry.as_deref(),
        Some("Donald E. Knuth, Leslie Lamport\nThe TeXbook\n1984\nAddison-Wesley")
    );
    assert_eq!(analyze::bib_entry(bib, "lamport"), None);
}

#[test]
fn magic_comments_name_the_root_and_program_near_the_top() {
    let text = "% !TeX root = ../main.tex\n%!TEX TS-program = xelatex\n% !TeX root = other.tex\n";
    let found = analyze::magic_comments(text);
    assert_eq!(found, (Some("../main.tex".into()), Some("xelatex".into())));
    let late = format!(
        "{}% !TeX root = main.tex\n",
        "\n".repeat(analyze::MAGIC_LINES)
    );
    assert_eq!(analyze::magic_comments(&late), (None, None));
    assert_eq!(analyze::magic_comments("% TeX root = x"), (None, None));
}
