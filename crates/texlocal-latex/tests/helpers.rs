use texlocal_latex::diff::{
    self,
    Row::{Added, Removed, Same, Skipped},
};
use texlocal_latex::logparse::{aux_inputs, label_number};
use texlocal_latex::search::{Query, score};
use texlocal_latex::syntax::{Installed, TextEdit};
use texlocal_latex::utf16;

#[test]
fn a_diff_shows_three_lines_around_each_change() {
    let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj";
    let new = old.replace('e', "E");
    let rows = [
        Skipped(1),
        Same("b"),
        Same("c"),
        Same("d"),
        Removed("e"),
        Added("E"),
    ];
    let rows = rows
        .into_iter()
        .chain([Same("f"), Same("g"), Same("h"), Skipped(2)]);
    assert_eq!(diff::compare(old, &new), rows.collect::<Vec<_>>());
    let inserted = diff::compare("a\nb\nc", "a\nx\nb\nc");
    assert_eq!(inserted, [Same("a"), Added("x"), Same("b"), Same("c")]);
    assert_eq!(diff::compare(old, old), []);
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
