//! Typing, through an editor that applies the answers as a text view does: each change reported back (`follow`),
//! each selection (`select`), and a snippet's field mirrored once the text has changed.

use crate::syntax::complete::SnippetField;
use crate::syntax::edit::{Change, Style, map_selections};
use crate::syntax::typing::{Completing, Keystroke};
use crate::syntax::{SourceDocument, TextEdit, TextRange, edit, range};

use super::units;

fn caret(at: u32) -> TextRange {
    range(at, 0)
}

fn field(start: u32, index: u32) -> SnippetField {
    SnippetField {
        start,
        length: 0,
        index,
    }
}

struct Editor {
    doc: SourceDocument,
    selections: Vec<TextRange>,
    auto_pair: bool,
    mirroring: bool,
}

impl Editor {
    fn open(text: &str, selection: TextRange) -> Self {
        let mut editor = Self {
            doc: SourceDocument::new(text),
            selections: vec![],
            auto_pair: true,
            mirroring: false,
        };
        editor.select(selection);
        editor
    }

    fn selection(&self) -> TextRange {
        self.selections[0]
    }

    #[track_caller]
    fn shows(&self, text: &str, selection: TextRange) {
        assert_eq!(
            (self.doc.text(), self.selection()),
            (text.into(), selection)
        );
    }

    fn select_all(&mut self, selections: Vec<TextRange>) {
        self.doc.select(selections[0], self.mirroring);
        self.selections = selections;
    }

    fn select(&mut self, selection: TextRange) {
        self.select_all(vec![selection]);
    }

    fn replace(&mut self, e: &TextEdit, after: Option<TextRange>) {
        let delta = units(&e.text) as i64 - e.length as i64;
        self.doc.edit(e.start, e.length, &e.text);
        self.doc
            .follow(range(e.start, e.length), delta, None, self.mirroring);
        let moved = map_selections(std::slice::from_ref(e), &self.selections);
        self.select_all(after.map_or(moved, |after| vec![after]));
        if self.mirroring {
            return;
        }
        let selection = self.selection();
        self.mirroring = true;
        for e in &self.doc.mirror_snippet() {
            self.replace(e, None);
        }
        self.mirroring = false;
        self.select(selection);
    }

    fn type_edit(&mut self, e: &TextEdit) {
        self.replace(e, Some(caret(e.start + units(&e.text))));
    }

    /// The key's answer, or what the text view does by itself when there is none.
    fn apply_key(&mut self, key: Keystroke, own: TextEdit) {
        if key.edit.is_none() && key.selection.is_none() {
            self.type_edit(&own);
        }
        if let Some(e) = &key.edit {
            self.type_edit(e);
        }
        if let Some(selection) = key.selection {
            self.select(selection);
        }
    }

    /// Each key in turn: ⌫ is Delete, ⏎ Return, ⇥ Tab and ⇤ Shift-Tab, and any other character is typed.
    fn keys(&mut self, keys: &str) {
        for key in keys.chars() {
            let s = self.selection();
            match key {
                '⌫' => {
                    let answer = self.doc.delete_backward(s, self.auto_pair);
                    let deleted = if s.length > 0 {
                        s
                    } else {
                        range(s.start - 1, 1)
                    };
                    self.apply_key(answer, edit(deleted.start, deleted.length, ""));
                }
                '⏎' => {
                    let answer = self.doc.insert_newline(s);
                    self.apply_key(answer, edit(s.start, s.length, "\n"));
                }
                '⇥' => self.tab(1),
                '⇤' => self.tab(-1),
                typed => {
                    let typed = typed.to_string();
                    let answer = self.doc.type_text(s, &typed, self.auto_pair);
                    self.apply_key(answer, edit(s.start, s.length, typed));
                }
            }
        }
    }

    fn apply(&mut self, change: Change) {
        for e in change.edits.iter().rev() {
            self.replace(e, None);
        }
        self.select_all(change.selections);
    }

    fn change(&mut self, answer: impl FnOnce(&mut SourceDocument, &[TextRange]) -> Change) {
        let change = answer(&mut self.doc, &self.selections);
        self.apply(change);
    }

    fn put(&mut self, e: TextEdit, at: u32) {
        self.apply(Change {
            edits: vec![e],
            selections: vec![caret(at)],
        });
    }

    fn tab(&mut self, step: i64) {
        let tab = self.doc.tab(&self.selections, step);
        if let Some(field) = tab.field {
            self.select(field);
        } else {
            let selections = map_selections(&tab.edits, &self.selections);
            self.apply(Change {
                edits: tab.edits,
                selections,
            });
        }
    }
}

#[test]
fn keys_type_as_the_editor_assists() {
    let cases = [
        ("", caret(0), "{", "{}", caret(1)),
        ("", caret(0), "{}", "{}", caret(2)),
        ("x", caret(0), "(", "(x", caret(1)),
        ("ab", range(0, 2), "[", "[ab]", range(1, 2)),
        // An empty pair the editor closed goes as one; one that was there loses only its bracket.
        ("", caret(0), "{⌫", "", caret(0)),
        ("{}", caret(1), "⌫", "}", caret(0)),
        ("\\", caret(1), "[", "\\[\\]", caret(2)),
        ("\\", caret(1), "[x\\]", "\\[x\\]", caret(5)),
        // A command typed inside keeps the closer whole, and the bracket alone steps over it.
        ("\\", caret(1), "(\\pi", "\\(\\pi\\)", caret(5)),
        ("\\", caret(1), "(\\pi)", "\\(\\pi\\)", caret(7)),
        ("\\", caret(1), "{", "\\{\\}", caret(2)),
        ("\\", caret(1), "{⌫", "\\", caret(1)),
        ("\\", caret(1), "[⏎", "\\[\n\n\\]", caret(3)),
        ("\\\\", caret(2), "[", "\\\\[]", caret(3)),
        // An emoji after an opening bracket is occupied text.
        ("😀", caret(0), "(", "(😀", caret(1)),
        ("  a", caret(3), "⏎", "  a\n  ", caret(6)),
        ("  a{}", caret(4), "⏎", "  a{\n  \n  }", caret(7)),
        ("\ta  b", caret(2), "⏎", "\ta\n\tb", caret(4)),
        ("    x", caret(2), "⏎", "\n    x", caret(5)),
        ("\ta\t b", caret(2), "⏎", "\ta\n\tb", caret(4)),
        ("\t\tx", caret(1), "⏎", "\n\t\tx", caret(3)),
        // A CRLF line's carriage return is no part of its indentation.
        ("  a\r\n  b", caret(3), "⏎", "  a\n  \r\n  b", caret(6)),
        ("x", caret(0), "⇥", "  x", caret(2)),
        ("x", caret(0), "⇥⇤", "x", caret(0)),
        ("     y", caret(5), "⌫", "    y", caret(4)),
        ("     y", caret(5), "⌫⌫", "  y", caret(2)),
    ];
    for (text, selection, keys, after, selection_after) in cases {
        let mut e = Editor::open(text, selection);
        e.keys(keys);
        let shown = (e.doc.text(), e.selection());
        assert_eq!(
            shown,
            (after.into(), selection_after),
            "{keys:?} in {text:?}"
        );
    }
}

#[test]
fn a_closer_left_on_a_line_above_is_not_stepped_over() {
    let mut e = Editor::open("", caret(0));
    e.keys("(");
    e.select(caret(2));
    e.keys("⏎");
    e.select(caret(1));
    e.keys(")");
    assert_eq!(e.doc.text(), "())\n");
}

#[test]
fn without_typing_assistance_an_opener_goes_alone() {
    let mut e = Editor::open("", caret(0));
    e.auto_pair = false;
    e.keys("{");
    assert_eq!(e.doc.text(), "{");
    let mut e = Editor::open("", caret(0));
    e.keys("{");
    e.auto_pair = false;
    e.keys("⌫");
    assert_eq!(e.doc.text(), "}");
}

#[test]
fn keys_say_what_the_completion_list_does() {
    let mut doc = SourceDocument::new("\\");
    let key = doc.type_text(caret(1), "b", true);
    assert_eq!(key.completions, Completing::Offer);
    assert_eq!((key.edit, key.selection), (None, None));
    assert_eq!(
        doc.type_text(caret(1), "日本", true).completions,
        Completing::Close
    );
    let key = doc.type_text(caret(1), "{", true);
    assert_eq!(key.completions, Completing::Offer);
    assert_eq!(doc.type_text(caret(1), ")", true).partner, Some(1));
}

#[test]
fn wrapping_keeps_the_selection() {
    let mut e = Editor::open("word", range(0, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    e.shows("\\textbf{word}", range(8, 4));
    let mut e = Editor::open("x", range(0, 1));
    e.change(|doc, s| doc.wrap(s, "$$0$"));
    e.shows("$x$", range(1, 1));
    let change = e.doc.wrap(&[caret(0)], "\\today");
    assert_eq!(change.edits[0].text, "\\today");
}

#[test]
fn a_style_the_selection_is_in_unwraps() {
    let source = "a \\textit{b \\textbf{word} c} d";
    let word = units(&source[..source.find("word").unwrap()]);
    let mut e = Editor::open(source, range(word, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    e.shows("a \\textit{b word c} d", range(word - 8, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Underline));
    assert_eq!(e.doc.text(), "a \\textit{b \\underline{word} c} d");
    e.select(caret(11));
    e.change(|doc, s| doc.toggle_style(s, Style::Italic));
    e.shows("a b \\underline{word} c d", caret(3));
}

#[test]
fn comments_map_the_selection() {
    let mut e = Editor::open("a\n  b", range(0, 5));
    e.change(|doc, s| {
        let edits = doc.toggle_comment(s);
        let selections = map_selections(&edits, s);
        Change { edits, selections }
    });
    e.shows("% a\n%   b", range(2, 7));
}

#[test]
fn blocks_tab_through_their_fields() {
    let mut e = Editor::open("", caret(0));
    let insertion = e.doc.insert_block("figure", e.selection()).unwrap();
    e.put(insertion.edit.clone(), insertion.caret);
    let first = e.doc.start_snippet(&insertion.fields, insertion.edit.start);
    e.select(first.unwrap());
    let string = e.doc.text();
    let at = |s: &str| units(&string[..string.find(s).unwrap()]);
    assert_eq!(e.selection(), caret(at("]{}") + 2));
    for (keys, field) in [("⇥", "\\caption{"), ("⇥", "fig:"), ("⇤", "\\caption{")] {
        e.keys(keys);
        assert_eq!(e.selection(), caret(at(field) + units(field)), "{keys}");
    }
    e.keys("⇥⇥");
    assert!(
        e.doc.text().contains("\n    \\label{fig:}"),
        "{}",
        e.doc.text()
    );
}

#[test]
fn a_field_in_two_places_is_typed_in_both() {
    let mut e = Editor::open("\\beg", caret(4));
    let offer = e.doc.completions(4, false).unwrap();
    let item = &offer.items[0];
    let end = offer.start + units(&item.text);
    e.put(edit(offer.start, 4 - offer.start, &item.text), end);
    let first = e.doc.start_snippet(&item.fields, offer.start).unwrap();
    e.select(first);
    assert_eq!(first, range(7, 3));
    e.keys("fig");
    e.shows("\\begin{fig}\n  \n\\end{fig}", caret(10));
    e.keys("⌫");
    assert_eq!(e.doc.text(), "\\begin{fi}\n  \n\\end{fi}");
    e.keys("⇥");
    assert_eq!(e.selection(), caret(13));
    // Typing outside the fields ends the snippet.
    let mut e = Editor::open("\\beg", caret(4));
    e.put(edit(0, 4, &item.text), 0);
    let first = e.doc.start_snippet(&item.fields, 0).unwrap();
    e.select(first);
    e.select(caret(0));
    e.keys("x");
    e.select(caret(8));
    e.keys("y");
    assert_eq!(e.doc.text(), "x\\begin{yenv}\n  \n\\end{env}");
}

#[test]
fn the_last_field_is_mirrored_and_left_by_shift_tab() {
    let mut e = Editor::open("   ", caret(0));
    let fields = [field(0, 0), field(1, 1), field(2, 1)];
    let first = e.doc.start_snippet(&fields, 0).unwrap();
    e.select(first);
    e.keys("⇥z");
    e.shows(" z z ", caret(2));
    e.keys("⇤");
    assert_eq!(e.selection(), caret(0));
    e.keys("⇤");
    e.shows(" z z ", caret(0));
    e.keys("⇥");
    assert_eq!(e.selection(), range(1, 1));
    e.keys("⇥");
    e.shows("   z z ", range(3, 1));
}

#[test]
fn a_completions_own_bracket_is_stepped_over() {
    let mut e = Editor::open("\\textb", caret(6));
    let offer = e.doc.completions(6, false).unwrap();
    let item = &offer.items[0];
    assert_eq!(item.text, "\\textbf{}");
    e.put(edit(offer.start, 6, &item.text), 9);
    // One field is no snippet, but the bracket after it is still the user's to step over.
    let first = e.doc.start_snippet(&item.fields, offer.start).unwrap();
    e.select(first);
    e.keys("x}");
    e.shows("\\textbf{x}", caret(10));
}

#[test]
fn the_range_an_editor_says_it_changes_stands_for_the_edit() {
    // TextKit may report an insertion as the paragraph's tail replaced by itself
    // with the text in it; the change alone leaves a closer after it standing.
    let mut doc = SourceDocument::new("");
    doc.type_text(caret(0), "(", true);
    doc.edit(0, 0, "()");
    doc.follow(range(0, 0), 2, None, false);
    doc.edit(1, 1, "x)");
    doc.follow(range(1, 1), 1, Some(range(1, 0)), false);
    doc.select(caret(2), false);
    let key = doc.type_text(caret(2), ")", true);
    assert_eq!(key.selection, Some(caret(3)));
}

#[test]
fn resetting_typing_forgets_the_closers_and_the_snippet() {
    let mut e = Editor::open("", caret(0));
    e.keys("(");
    e.doc.reset_typing();
    e.keys(")");
    e.shows("())", caret(2));
    let mut doc = SourceDocument::new("ab");
    let fields = [field(0, 0), field(1, 1)];
    doc.start_snippet(&fields, 0);
    assert!(doc.end_snippet());
    assert!(!doc.end_snippet());
    doc.start_snippet(&fields, 0);
    doc.reset_typing();
    assert!(!doc.end_snippet());
}

#[test]
fn lines_move_up_and_down_with_their_selections() {
    type Case<'a> = (
        &'a str,
        &'a [(u32, u32)],
        bool,
        Option<(&'a str, &'a [(u32, u32)])>,
    );
    // Several selections move together.
    const SIX: &str = "1\n2\n3\n4\n5\n6";
    #[rustfmt::skip]
    let cases: [Case; 11] = [
        ("a\nb\nc\nd", &[(2, 0)], true, Some(("b\na\nc\nd", &[(0, 0)]))),
        ("b\na\nc\nd", &[(0, 0)], true, None),
        ("b\na\nc\nd", &[(4, 1)], false, Some(("b\na\nd\nc", &[(6, 1)]))),
        ("b\na\nd\nc", &[(6, 1)], false, None),
        ("b\na\nd\nc", &[(6, 1)], true, Some(("b\na\nc\nd", &[(4, 1)]))),
        ("a\n", &[(2, 0)], true, None),
        ("a\r\nb", &[(4, 0)], true, Some(("b\r\na", &[(1, 0)]))),
        ("😀\nb", &[(3, 0)], true, Some(("b\n😀", &[(0, 0)]))),
        (SIX, &[(2, 4), (8, 1)], true, Some(("2\n3\n1\n5\n4\n6", &[(0, 4), (6, 1)]))),
        (SIX, &[(8, 1), (2, 1), (8, 0)], true, Some(("2\n1\n3\n5\n4\n6", &[(6, 1), (0, 1), (6, 0)]))),
        (SIX, &[(8, 1), (2, 4)], true, Some(("2\n3\n1\n5\n4\n6", &[(6, 1), (0, 4)]))),
    ];
    for (text, selections, up, after) in cases {
        let mut e = Editor::open(text, caret(0));
        e.select_all(selections.iter().map(|&(s, l)| range(s, l)).collect());
        let Some(change) = e.doc.move_lines(&e.selections, up) else {
            assert_eq!(after, None, "{text:?} {up}");
            continue;
        };
        e.apply(change);
        let moved: Vec<_> = e.selections.iter().map(|r| (r.start, r.length)).collect();
        let moved_text = e.doc.text();
        assert_eq!(
            Some((moved_text.as_str(), &moved[..])),
            after,
            "{text:?} {up}"
        );
    }
}

type LinesCase<'a> = (&'a str, &'a [(u32, u32)], &'a str, &'a [(u32, u32)]);

fn lines_changed(cases: &[LinesCase], change: fn(&SourceDocument, &[TextRange]) -> Change) {
    for &(text, selections, after, selected) in cases {
        let mut e = Editor::open(text, caret(0));
        e.select_all(selections.iter().map(|&(s, l)| range(s, l)).collect());
        e.apply(change(&e.doc, &e.selections));
        let selections: Vec<_> = e.selections.iter().map(|r| (r.start, r.length)).collect();
        assert_eq!(
            (e.doc.text().as_str(), &selections[..]),
            (after, selected),
            "{text:?}"
        );
    }
}

#[test]
fn lines_are_duplicated_with_the_selection_on_the_copy() {
    #[rustfmt::skip]
    lines_changed(&[
        ("a\nb\nc", &[(2, 1)], "a\nb\nb\nc", &[(4, 1)]),
        ("a\r\nb", &[(3, 0)], "a\r\nb\r\nb", &[(6, 0)]),
        ("a", &[(0, 1)], "a\na", &[(2, 1)]),
        ("1\n2\n3\n4", &[(0, 0), (4, 0)], "1\n1\n2\n3\n3\n4", &[(2, 0), (8, 0)]),
    ], SourceDocument::duplicate_lines);
}

#[test]
fn lines_are_deleted_leaving_the_caret_on_the_next() {
    #[rustfmt::skip]
    lines_changed(&[
        ("a\nb\nc", &[(2, 1)], "a\nc", &[(2, 0)]),
        ("a\r\nb\r\nc", &[(3, 0)], "a\r\nc", &[(3, 0)]),
        ("a\nb", &[(2, 1)], "a", &[(1, 0)]),
        ("a", &[(0, 1)], "", &[(0, 0)]),
        ("1\n2\n3\n4", &[(0, 0), (1, 0), (4, 0)], "2\n4", &[(0, 0), (2, 0)]),
    ], SourceDocument::delete_lines);
}

/// Not an escaped bracket, nor one in a comment, which has no partner of its own; an escaped one pairs only with
/// the escaped, and the next line is no comment, nor is an escaped percent one.
#[test]
fn a_bracket_finds_its_partner() {
    let far = format!("({})", "x".repeat(10_000));
    let near = format!("({})", "x".repeat(9_999));
    let cases = [
        ("(a [b] {c}) ]", 0, Some(10)),
        ("(a [b] {c}) ]", 10, Some(0)),
        ("(a [b] {c}) ]", 3, Some(5)),
        ("(a [b] {c}) ]", 12, None),
        ("(a [b] {c}) ]", 1, None),
        ("(a [b] {c}) ]", 99, None),
        (&far, 0, None),
        (&near, 0, Some(10_000)),
        ("{a \\} b}", 0, Some(7)),
        ("{a \\} b}", 7, Some(0)),
        ("\\{ {a} \\}", 1, Some(8)),
        ("\\{ {a} \\}", 8, Some(1)),
        ("\\{ {a} \\}", 3, Some(5)),
        ("{a \\\\}", 0, Some(5)),
        ("(a % b )\nc)", 0, Some(10)),
        ("(a % b )\nc)", 7, None),
        ("(a 5\\% )", 0, Some(7)),
    ];
    for (text, at, partner) in cases {
        assert_eq!(
            SourceDocument::new(text).partner(at),
            partner,
            "{text} {at}"
        );
    }
}
