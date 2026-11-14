use texlocal_latex::cite::citation_source;
use texlocal_latex::diff::{
    self,
    DiffLine::{Added, Removed, Same, Skipped},
};
use texlocal_latex::logparse::{aux_inputs, label_number};
use texlocal_latex::search::{Query, score};
use texlocal_latex::syntax::{Installed, TextEdit};
use texlocal_latex::utf16;

#[test]
fn doi_links_exclude_query_and_fragment_but_keep_encoded_path_characters() {
    for (text, path) in [
        (
            "https://doi.org/10.1103/PhysRevLett.116.061102?nols=y",
            "10.1103/PhysRevLett.116.061102",
        ),
        ("https://doi.org/10.1000/a#section", "10.1000/a"),
        (
            "https://doi.org/10.1000/a%3Fb%23c?query#fragment",
            "10.1000/a%3Fb%23c",
        ),
        ("10.1000/a?b#c%20", "10.1000/a%3Fb%23c%2520"),
        ("https://example.org see 10.1000/a%20", "10.1000/a%2520"),
    ] {
        assert_eq!(
            citation_source(text).unwrap().url,
            format!("https://doi.org/{path}"),
            "{text}"
        );
    }
}

#[test]
fn a_diff_shows_three_lines_around_each_change() {
    let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj";
    let new = old.replace('e', "E");
    let rows = [
        Skipped(1),
        Same("b".into()),
        Same("c".into()),
        Same("d".into()),
        Removed("e".into()),
        Added("E".into()),
    ];
    let rows = rows.into_iter().chain([
        Same("f".into()),
        Same("g".into()),
        Same("h".into()),
        Skipped(2),
    ]);
    assert_eq!(diff::compare(old, &new), rows.collect::<Vec<_>>());
    let inserted = diff::compare("a\nb\nc", "a\nx\nb\nc");
    assert_eq!(
        inserted,
        [
            Same("a".into()),
            Added("x".into()),
            Same("b".into()),
            Same("c".into())
        ]
    );
    assert_eq!(diff::compare(old, old), []);
    let ended = [Same("a".into()), Added("".into())];
    assert_eq!(diff::compare("a", "a\n"), ended);
    assert_eq!(diff::compare("", "a\n"), [Added("a".into())]);
}

#[test]
fn a_delta_keeps_to_whole_characters() {
    assert_eq!(diff::delta("aéb", "aèb"), (1, 2, "è"));
    assert_eq!(diff::delta("same", "same"), (4, 0, ""));
    let edit = TextEdit {
        start: 4,
        length: 0,
        text: "c".into(),
    };
    assert_eq!(diff::edit_to("aé😀b", "aé😀cb"), Some(edit));
    assert_eq!(diff::edit_to("same", "same"), None);
}

#[test]
fn a_line_maps_back_across_a_change_to_the_line_it_stands_for() {
    let old = "a\nb\nc\nd";
    let map = |new: &str, lines: &[u32]| -> Vec<u32> {
        lines
            .iter()
            .map(|&line| diff::map_line(old, new, line))
            .collect()
    };
    assert_eq!(map(old, &[1, 2, 3, 4]), [1, 2, 3, 4]);
    assert_eq!(map("a\nB\nc\nd", &[1, 2, 3, 4]), [1, 2, 3, 4]);
    assert_eq!(map("a\nb\nx\ny\nc\nd", &[2, 3, 4, 5, 6]), [2, 3, 3, 3, 4]);
    assert_eq!(map("a\nd", &[1, 2]), [1, 4]);
    assert_eq!(map("a\nb\nc\nd\ne", &[4, 5]), [4, 4]);
}

#[test]
fn search_finds_places_in_utf16_columns() {
    let text = "Ünïcode café\n😀 Café cafés";
    let places = |match_case, whole_word| {
        let places = Query::new("café", match_case, whole_word).places(text);
        places
            .iter()
            .map(|p| (p.line, p.column, p.length))
            .collect::<Vec<_>>()
    };
    assert_eq!(places(false, false), [(1, 8, 4), (2, 3, 4), (2, 8, 4)]);
    assert_eq!(places(false, true), [(1, 8, 4), (2, 3, 4)]);
    assert_eq!(places(true, false), [(1, 8, 4), (2, 8, 4)]);
    assert!(Query::new("", false, false).places(text).is_empty());
    let emoji = Query::new("😀a", false, false).places("😀A x 😀a😀A");
    assert_eq!(
        emoji
            .iter()
            .map(|p| (p.column, p.length))
            .collect::<Vec<_>>(),
        [(0, 3), (6, 3), (9, 3)]
    );
}

#[test]
fn quick_open_scores_word_starts_above_letters_inside_words() {
    let (starts, inside) = (score("mf", "main_file.tex"), score("mf", "myfile.tex"));
    assert!(starts.unwrap() > inside.unwrap());
    assert!(score("MF", "mainFile").unwrap() >= starts.unwrap());
    assert_eq!(score("fm", "main_file.tex"), None);
}

#[test]
fn utf16_offsets_fall_between_whole_characters() {
    assert_eq!(utf16::len("a😀b"), 4);
    let offsets: Vec<_> = (0..6)
        .map(|units| utf16::byte_offset("a😀b", units))
        .collect();
    assert_eq!(offsets, [Some(0), Some(1), None, Some(5), Some(6), None]);
    let units: Vec<u16> = "aé😀".encode_utf16().collect();
    assert_eq!(utf16::lossy(&units), "aé😀");
    assert_eq!(utf16::lossy(&[0xD800, 0x61]), "\u{FFFD}a");
}

#[test]
fn a_label_is_numbered_from_the_aux_files() {
    let aux =
        "\\newlabel{fig}{{2.1}{4}{Caption}{figure.2}{}}\n\\@input{ch.aux}\n\\@input{app.aux}\n";
    assert_eq!(label_number(aux, "fig").as_deref(), Some("2.1 on page 4"));
    assert_eq!(label_number(aux, "fi"), None);
    assert_eq!(aux_inputs(aux).collect::<Vec<_>>(), ["ch.aux", "app.aux"]);
}

#[test]
fn ls_r_lists_what_tex_and_bibtex_can_load() {
    let ls_r = "% ls-R -- filename database\n./tex/latex/amsmath:\namsthm.sty\namsmath.sty\n./tex/latex/base:\narticle.cls\nsize10.clo\n./bibtex/bst/base:\nplain.bst\n./doc/latex/foo:\nfoo.sty\n./tex/plain/base:\nplain.tex\n";
    let installed = Installed {
        packages: vec!["amsmath".into(), "amsthm".into()],
        classes: vec!["article".into()],
        styles: vec!["plain".into()],
        inputs: vec!["plain".into()],
    };
    assert_eq!(Installed::from_ls_r(ls_r), installed);
}

#[test]
fn a_diff_keeps_unchanged_lines_between_distant_edits() {
    let old: String = (0..3000).map(|i| format!("line {i}\n")).collect();
    let new = old
        .replacen("line 0\n", "first\n", 1)
        .replace("line 2999\n", "last\n");
    assert_eq!(
        diff::compare(&old, &new),
        [
            Removed("line 0".into()),
            Added("first".into()),
            Same("line 1".into()),
            Same("line 2".into()),
            Same("line 3".into()),
            Skipped(2992),
            Same("line 2996".into()),
            Same("line 2997".into()),
            Same("line 2998".into()),
            Removed("line 2999".into()),
            Added("last".into()),
        ]
    );
}

#[test]
fn a_diff_can_replace_every_line_of_a_large_file() {
    let old = "old\n".repeat(2100);
    let new = "new\n".repeat(2100);
    let rows = diff::compare(&old, &new);
    assert_eq!(rows.len(), 4200);
    assert!(rows[..2100].iter().all(|row| *row == Removed("old".into())));
    assert!(rows[2100..].iter().all(|row| *row == Added("new".into())));
}

#[test]
fn short_diffs_reconstruct_both_texts_with_the_fewest_edits() {
    let mut texts = vec![vec![]];
    for len in 1..=4 {
        for bits in 0..1 << len {
            texts.push(
                (0..len)
                    .map(|i| if bits & (1 << i) == 0 { "a" } else { "b" })
                    .collect(),
            );
        }
    }
    for a in &texts {
        for b in &texts {
            let rows = diff::compare(&a.join("\n"), &b.join("\n"));
            if a == b {
                assert!(rows.is_empty());
                continue;
            }
            let mut lengths = vec![vec![0usize; b.len() + 1]; a.len() + 1];
            for (i, x) in a.iter().enumerate() {
                for (j, y) in b.iter().enumerate() {
                    lengths[i + 1][j + 1] = if x == y {
                        lengths[i][j] + 1
                    } else {
                        lengths[i][j + 1].max(lengths[i + 1][j])
                    };
                }
            }
            let (mut before, mut after) = (Vec::new(), Vec::new());
            let mut edits = 0;
            for row in &rows {
                match row {
                    Same(line) => {
                        before.push(line.as_str());
                        after.push(line.as_str());
                    }
                    Removed(line) => {
                        before.push(line.as_str());
                        edits += 1;
                    }
                    Added(line) => {
                        after.push(line.as_str());
                        edits += 1;
                    }
                    Skipped(_) => panic!("four-line inputs need no folded context"),
                }
            }
            assert_eq!(&before, a);
            assert_eq!(&after, b);
            assert_eq!(edits, a.len() + b.len() - 2 * lengths[a.len()][b.len()]);
        }
    }
}
