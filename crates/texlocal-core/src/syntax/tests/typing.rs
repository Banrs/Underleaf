//! Typing, as the Mac's source editor did it in Swift (its SourceEditorTests'
//! cases), through an editor that applies the answers as a text view does:
//! each change reported back (`follow`), each selection (`select`), and a
//! snippet's field mirrored once the text has changed.

use crate::syntax::complete::SnippetField;
use crate::syntax::edit::{Change, Style, map_selections};
use crate::syntax::typing::{Completing, Keystroke};
use crate::syntax::{SourceDocument, TextEdit, TextRange, edit, range};

use super::units;

fn caret(at: u32) -> TextRange {
    range(at, 0)
}

/// An empty field at `start`, `index`th in Tab's order.
fn field(start: u32, index: u32) -> SnippetField {
    SnippetField {
        start,
        length: 0,
        index,
    }
}

struct Editor {
    doc: SourceDocument,
    text: Vec<u16>,
    selections: Vec<TextRange>,
    auto_pair: bool,
    mirroring: bool,
}

impl Editor {
    fn open(text: &str, caret: Option<u32>) -> Self {
        let mut editor = Self {
            doc: SourceDocument::new(text),
            text: text.encode_utf16().collect(),
            selections: vec![],
            auto_pair: true,
            mirroring: false,
        };
        editor.set_selection(range(caret.unwrap_or(units(text)), 0));
        editor
    }

    fn string(&self) -> String {
        String::from_utf16(&self.text).unwrap()
    }

    fn selection(&self) -> TextRange {
        self.selections[0]
    }

    /// The text and the selection are these.
    #[track_caller]
    fn shows(&self, text: &str, selection: TextRange) {
        assert_eq!((self.string(), self.selection()), (text.into(), selection));
    }

    fn set_selections(&mut self, selections: Vec<TextRange>) {
        self.doc.select(selections[0], self.mirroring);
        self.selections = selections;
    }

    fn set_selection(&mut self, selection: TextRange) {
        self.set_selections(vec![selection]);
    }

    /// The text storage's change, which the storage's delegate reports; the
    /// text view's selection follows it, or goes to `after`, before the
    /// change is done.
    fn replace(&mut self, e: &TextEdit, after: Option<TextRange>) {
        let new: Vec<u16> = e.text.encode_utf16().collect();
        let (start, end) = (e.start as usize, (e.start + e.length) as usize);
        let delta = new.len() as i64 - e.length as i64;
        self.text.splice(start..end, new);
        self.doc.edit(e.start, e.length, &e.text);
        let old = range(e.start, e.length);
        self.doc.follow(old, delta, None, self.mirroring);
        let moved = map_selections(std::slice::from_ref(e), &self.selections);
        self.set_selections(after.map_or(moved, |after| vec![after]));
        self.did_change_text();
    }

    /// What's typed in a field goes in its other places too.
    fn did_change_text(&mut self) {
        if self.mirroring {
            return;
        }
        let edits = self.doc.mirror_snippet();
        if edits.is_empty() {
            return;
        }
        let selection = self.selection();
        self.mirroring = true;
        for e in &edits {
            self.replace(e, None);
        }
        self.mirroring = false;
        self.set_selection(selection);
    }

    /// Typed as a key types: in place of its range, the caret after it.
    fn type_edit(&mut self, e: &TextEdit) {
        self.replace(e, Some(range(e.start + units(&e.text), 0)));
    }

    fn apply_key(&mut self, key: Keystroke, own: impl FnOnce(&mut Self)) {
        if key.edit.is_none() && key.selection.is_none() {
            own(self);
        }
        if let Some(e) = &key.edit {
            self.type_edit(e);
        }
        if let Some(selection) = key.selection {
            self.set_selection(selection);
        }
    }

    fn type_text(&mut self, typed: &str) {
        let key = self.doc.type_text(self.selection(), typed, self.auto_pair);
        let selection = self.selection();
        self.apply_key(key, |editor| {
            editor.type_edit(&edit(selection.start, selection.length, typed));
        });
    }

    /// Each key in turn: ⌫ is Delete, ⏎ Return, ⇥ Tab and ⇤ Shift-Tab, and
    /// any other character is typed.
    fn keys(&mut self, keys: &str) {
        for key in keys.chars() {
            match key {
                '⌫' => self.delete_backward(),
                '⏎' => self.newline(),
                '⇥' => self.tab(1),
                '⇤' => self.tab(-1),
                typed => self.type_text(&typed.to_string()),
            }
        }
    }

    fn delete_backward(&mut self) {
        let key = self.doc.delete_backward(self.selection(), self.auto_pair);
        let selection = self.selection();
        self.apply_key(key, |editor| {
            let deleted = if selection.length > 0 {
                selection
            } else {
                range(selection.start - 1, 1)
            };
            editor.type_edit(&edit(deleted.start, deleted.length, ""));
        });
    }

    fn newline(&mut self) {
        let key = self.doc.insert_newline(self.selection());
        assert!(key.edit.is_some());
        self.apply_key(key, |_| unreachable!());
    }

    /// Edits from the last, as one step, the selections following them
    /// unless the change gives its own.
    fn apply(&mut self, change: Change) {
        let selections = change.selections.clone();
        for e in change.edits.iter().rev() {
            self.replace(e, None);
        }
        self.set_selections(selections);
    }

    /// The change the document answers for the selections, applied.
    fn change(&mut self, answer: impl FnOnce(&mut SourceDocument, &[TextRange]) -> Change) {
        let change = answer(&mut self.doc, &self.selections);
        self.apply(change);
    }

    /// One edit, the caret going to `at`.
    fn put(&mut self, e: TextEdit, at: u32) {
        self.apply(Change {
            edits: vec![e],
            selections: vec![caret(at)],
        });
    }

    fn tab(&mut self, step: i64) {
        let tab = self.doc.tab(&self.selections.clone(), step);
        if let Some(field) = tab.field {
            self.set_selection(field);
        } else if !tab.edits.is_empty() {
            let selections = map_selections(&tab.edits, &self.selections);
            self.apply(Change {
                edits: tab.edits,
                selections,
            });
        }
    }
}

/// Keys in a text with a selection, and the text and the selection after.
#[test]
fn keys_type_as_the_editor_assists() {
    let cases = [
        // Brackets close and are stepped over; before a word, only the one typed.
        ("", caret(0), "{", "{}", caret(1)),
        ("", caret(0), "{}", "{}", caret(2)),
        ("x", caret(0), "(", "(x", caret(1)),
        // Round a selection, which stays selected.
        ("ab", range(0, 2), "[", "[ab]", range(1, 2)),
        // An empty pair the editor closed goes as one; one that was there loses only its bracket.
        ("", caret(0), "{⌫", "", caret(0)),
        ("{}", caret(1), "⌫", "}", caret(0)),
        // Escaped brackets close escaped.
        ("\\", caret(1), "[", "\\[\\]", caret(2)),
        ("\\", caret(1), "[x\\]", "\\[x\\]", caret(5)),
        // A command typed inside keeps the closer whole, and the bracket alone steps over it.
        ("\\", caret(1), "(\\pi", "\\(\\pi\\)", caret(5)),
        ("\\", caret(1), "(\\pi)", "\\(\\pi\\)", caret(7)),
        ("\\", caret(1), "{", "\\{\\}", caret(2)),
        ("\\", caret(1), "{⌫", "\\", caret(1)),
        ("\\", caret(1), "[⏎", "\\[\n\n\\]", caret(3)),
        ("\\\\", caret(2), "[", "\\\\[]", caret(3)),
        // An emoji after an opening bracket is occupied text, and a bracket
        // with a mark on it is no bracket.
        ("😀", caret(0), "(", "(😀", caret(1)),
        ("}\u{301}", caret(0), "{", "{}\u{301}", caret(1)),
        // New lines keep the indentation; between brackets, the closing one a
        // line further down.
        ("  a", caret(3), "⏎", "  a\n  ", caret(6)),
        ("  a{}", caret(4), "⏎", "  a{\n  \n  }", caret(7)),
        // The spaces after the caret go; a caret in the indentation takes it down.
        ("\ta  b", caret(2), "⏎", "\ta\n\tb", caret(4)),
        ("    x", caret(2), "⏎", "\n    x", caret(5)),
        // Tab and Shift-Tab indent by two spaces; Delete in the indentation back to a stop.
        ("x", caret(0), "⇥", "  x", caret(2)),
        ("x", caret(0), "⇥⇤", "x", caret(0)),
        ("     y", caret(5), "⌫", "    y", caret(4)),
        ("     y", caret(5), "⌫⌫", "  y", caret(2)),
    ];
    for (text, selection, keys, after, selection_after) in cases {
        let mut e = Editor::open(text, None);
        e.set_selection(selection);
        e.keys(keys);
        let shown = (e.string(), e.selection());
        assert_eq!(
            shown,
            (after.into(), selection_after),
            "{keys:?} in {text:?}"
        );
    }
}

#[test]
fn a_closer_left_on_a_line_above_is_not_stepped_over() {
    let mut e = Editor::open("", None);
    e.keys("(");
    e.set_selection(caret(2));
    e.newline();
    e.set_selection(caret(1));
    e.keys(")");
    assert_eq!(e.string(), "())\n");
}

#[test]
fn typing_assistance_can_be_turned_off() {
    let mut e = Editor::open("", None);
    e.auto_pair = false;
    e.keys("{");
    assert_eq!(e.string(), "{");
    let mut e = Editor::open("{}", Some(1));
    e.auto_pair = false;
    e.keys("⌫");
    assert_eq!(e.string(), "}");
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
    // A closing bracket typed shows its partner.
    assert_eq!(doc.type_text(caret(1), ")", true).partner, Some(1));
}

#[test]
fn wrapping_keeps_the_selection() {
    let mut e = Editor::open("word", None);
    e.set_selection(range(0, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    e.shows("\\textbf{word}", range(8, 4));
    e.change(|doc, s| doc.wrap(s, "\\ref{$0}"));
    assert_eq!(e.string(), "\\textbf{\\ref{word}}");
    // Inline and display maths, and a template without "$0".
    let mut e = Editor::open("x", None);
    e.set_selection(range(0, 1));
    e.change(|doc, s| doc.wrap(s, "$$0$"));
    e.shows("$x$", range(1, 1));
    e.change(|doc, s| doc.wrap(s, "\\[$0\\]"));
    assert_eq!(e.string(), "$\\[x\\]$");
    let change = e.doc.wrap(&[caret(0)], "\\today");
    assert_eq!(change.edits[0].text, "\\today");
}

#[test]
fn a_style_the_selection_is_in_unwraps() {
    let source = "a \\textit{b \\textbf{word} c} d";
    let mut e = Editor::open(source, None);
    let word = units(&source[..source.find("word").unwrap()]);
    e.set_selection(range(word, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    e.shows("a \\textit{b word c} d", range(word - 8, 4));
    e.change(|doc, s| doc.toggle_style(s, Style::Underline));
    assert_eq!(e.string(), "a \\textit{b \\underline{word} c} d");
    // The caret in it, the whole command goes.
    e.set_selection(caret(11));
    e.change(|doc, s| doc.toggle_style(s, Style::Italic));
    e.shows("a b \\underline{word} c d", caret(3));
    assert_eq!(e.doc.text(), e.string());
}

#[test]
fn comments_map_the_selection() {
    let mut e = Editor::open("a\n  b", None);
    e.set_selection(range(0, 5));
    e.change(|doc, s| {
        let edits = doc.toggle_comment(s);
        let selections = map_selections(&edits, s);
        Change { edits, selections }
    });
    e.shows("% a\n%   b", range(2, 7));
}

#[test]
fn blocks_tab_through_their_fields() {
    let mut e = Editor::open("", None);
    let insertion = e.doc.insert_block("figure", e.selection()).unwrap();
    e.put(insertion.edit.clone(), insertion.caret);
    let first = e.doc.start_snippet(&insertion.fields, insertion.edit.start);
    e.set_selection(first.unwrap());
    let string = e.string();
    let at = |s: &str| units(&string[..string.find(s).unwrap()]);
    assert_eq!(e.selection(), caret(at("]{}") + 2));
    e.tab(1);
    assert_eq!(e.selection(), caret(at("\\caption{") + 9));
    e.tab(1);
    assert_eq!(e.selection(), caret(at("fig:") + 4));
    // The last field keeps the snippet, so Shift-Tab goes back; Tab from it
    // ends the snippet, and indents again.
    e.tab(-1);
    assert_eq!(e.selection(), caret(at("\\caption{") + 9));
    e.tab(1);
    assert_eq!(e.selection(), caret(at("fig:") + 4));
    e.tab(1);
    assert!(e.string().contains("\n    \\label{fig:}"), "{}", e.string());
}

#[test]
fn a_field_in_two_places_is_typed_in_both() {
    let mut e = Editor::open("\\beg", None);
    let offer = e.doc.completions(4, false).unwrap();
    let item = &offer.items[0];
    let end = offer.start + units(&item.text);
    e.put(edit(offer.start, 4 - offer.start, &item.text), end);
    let first = e.doc.start_snippet(&item.fields, offer.start).unwrap();
    e.set_selection(first);
    assert_eq!(first, range(7, 3));
    e.keys("fig");
    e.shows("\\begin{fig}\n  \n\\end{fig}", caret(10));
    e.delete_backward();
    assert_eq!(e.string(), "\\begin{fi}\n  \n\\end{fi}");
    e.tab(1);
    assert_eq!(e.selection(), caret(13));
    // Selecting outside the fields ends the snippet.
    let mut e = Editor::open("\\beg", None);
    e.put(edit(0, 4, &item.text), 0);
    let first = e.doc.start_snippet(&item.fields, 0).unwrap();
    e.set_selection(first);
    e.set_selection(caret(0));
    e.type_text("x");
    e.set_selection(caret(8));
    e.type_text("y");
    assert_eq!(e.string(), "x\\begin{yenv}\n  \n\\end{env}");
    // Escape ends one.
    let mut doc = SourceDocument::new("ab");
    assert!(doc.start_snippet(&[field(0, 0), field(1, 1)], 0).is_some());
    assert!(doc.end_snippet());
    assert!(!doc.end_snippet());
}

/// Fields that are empty, `index` being each one's in Tab's order.
fn snippet(e: &mut Editor, places: &[(u32, u32)]) {
    let fields: Vec<_> = places
        .iter()
        .map(|&(start, index)| field(start, index))
        .collect();
    let first = e.doc.start_snippet(&fields, 0).unwrap();
    e.set_selection(first);
}

#[test]
fn the_last_field_is_mirrored_and_left_by_shift_tab() {
    let mut e = Editor::open("   ", Some(0));
    // The second field is in two places, and the last.
    snippet(&mut e, &[(0, 0), (1, 1), (2, 1)]);
    e.tab(1);
    e.keys("z");
    e.shows(" z z ", caret(2));
    e.tab(-1);
    assert_eq!(e.selection(), caret(0));
    // Before the first field there is nowhere to go, and nothing is outdented.
    e.tab(-1);
    e.shows(" z z ", caret(0));
    // Tab to the last field, and from it: the lines are indented.
    e.tab(1);
    assert_eq!(e.selection(), range(1, 1));
    e.tab(1);
    e.shows("   z z ", range(3, 1));
}

#[test]
fn a_completions_own_bracket_is_stepped_over() {
    let mut e = Editor::open("\\textb", None);
    let offer = e.doc.completions(6, false).unwrap();
    let item = &offer.items[0];
    assert_eq!(item.text, "\\textbf{}");
    e.put(edit(offer.start, 6, &item.text), 9);
    // One field is no snippet, but the bracket after it is still the user's to step over.
    let first = e.doc.start_snippet(&item.fields, offer.start).unwrap();
    e.set_selection(first);
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
    // The closer put in is stepped over by the bracket typed...
    let mut e = Editor::open("", None);
    e.type_text("(");
    e.set_selection(caret(1));
    e.type_text(")");
    e.shows("()", caret(2));
    // ...but not once the document is shown again.
    let mut e = Editor::open("", None);
    e.type_text("(");
    e.set_selection(caret(1));
    e.doc.reset_typing();
    e.type_text(")");
    e.shows("())", caret(2));
    // A snippet is over.
    let mut doc = SourceDocument::new("ab");
    assert!(doc.start_snippet(&[field(0, 0), field(1, 1)], 0).is_some());
    doc.reset_typing();
    assert!(!doc.end_snippet());
}

#[test]
fn lines_move_up_and_down() {
    let mut e = Editor::open("a\nb\nc\nd", Some(2));
    e.change(|doc, s| doc.move_lines(s, true).unwrap());
    e.shows("b\na\nc\nd", caret(0));
    assert_eq!(e.doc.move_lines(&e.selections, true), None);
    // Down to the end: the moved line takes the last one's place, without its break.
    e.set_selection(range(4, 1));
    e.change(|doc, s| doc.move_lines(s, false).unwrap());
    e.shows("b\na\nd\nc", range(6, 1));
    assert_eq!(e.doc.move_lines(&e.selections, false), None);
    e.change(|doc, s| doc.move_lines(s, true).unwrap());
    e.shows("b\na\nc\nd", range(4, 1));
    assert_eq!(e.doc.text(), e.string());
    // The empty line after a final line break has nothing to move.
    let e = Editor::open("a\n", None);
    assert_eq!(e.doc.move_lines(&e.selections, true), None);
    // CRLF ends a line as one.
    let mut e = Editor::open("a\r\nb", None);
    e.change(|doc, s| doc.move_lines(s, true).unwrap());
    e.shows("b\r\na", caret(1));
    // Counted in UTF-16 units: an emoji is two.
    let mut e = Editor::open("😀\nb", Some(3));
    e.change(|doc, s| doc.move_lines(s, true).unwrap());
    e.shows("b\n😀", caret(0));
    // Return keeps the indentation of a CRLF line, whose carriage return is no part of it.
    let mut e = Editor::open("  a\r\n  b", Some(3));
    e.newline();
    e.shows("  a\n  \r\n  b", caret(6));
}

#[test]
fn several_selections_move_together() {
    let cases = [
        // Lines 2–3 (selected up to line 4's start) and line 5.
        (
            vec![range(2, 4), range(8, 1)],
            "2\n3\n1\n5\n4\n6",
            vec![range(0, 4), range(6, 1)],
        ),
        // In any order: line 5, line 2, and line 5 again.
        (
            vec![range(8, 1), range(2, 1), caret(8)],
            "2\n1\n3\n5\n4\n6",
            vec![range(6, 1), range(0, 1), caret(6)],
        ),
        // Given last first, they move as the same lines.
        (
            vec![range(8, 1), range(2, 4)],
            "2
3
1
5
4
6",
            vec![range(6, 1), range(0, 4)],
        ),
    ];
    for (selections, text, after) in cases {
        let mut e = Editor::open("1\n2\n3\n4\n5\n6", Some(0));
        e.set_selections(selections);
        e.change(|doc, s| doc.move_lines(s, true).unwrap());
        assert_eq!((e.string(), &e.selections), (text.into(), &after));
        assert_eq!(e.doc.text(), e.string());
    }
}

#[test]
fn a_bracket_finds_its_partner() {
    let doc = SourceDocument::new("(a [b] {c}) ]");
    assert_eq!(doc.partner(0), Some(10));
    assert_eq!(doc.partner(10), Some(0));
    assert_eq!(doc.partner(3), Some(5));
    assert_eq!(doc.partner(12), None);
    assert_eq!(doc.partner(1), None);
    assert_eq!(doc.partner(99), None);
    let far = format!("({})", "x".repeat(10_000));
    assert_eq!(SourceDocument::new(&far).partner(0), None);
    let near = format!("({})", "x".repeat(9_999));
    assert_eq!(SourceDocument::new(&near).partner(0), Some(10_000));
}

#[test]
fn a_partner_is_not_an_escaped_bracket_nor_one_in_a_comment() {
    // The escaped brace is no one's partner for the plain ones.
    let doc = SourceDocument::new("{a \\} b}");
    assert_eq!(doc.partner(0), Some(7));
    assert_eq!(doc.partner(7), Some(0));
    // The escaped pair is a pair of its own.
    let doc = SourceDocument::new("\\{ {a} \\}");
    assert_eq!(doc.partner(1), Some(8));
    assert_eq!(doc.partner(8), Some(1));
    assert_eq!(doc.partner(3), Some(5));
    // A double backslash escapes nothing.
    assert_eq!(SourceDocument::new("{a \\\\}").partner(0), Some(5));
    // A bracket in a comment is passed over, and has no partner of its own;
    // the next line is no comment, nor is an escaped percent one.
    let doc = SourceDocument::new("(a % b )\nc)");
    assert_eq!(doc.partner(0), Some(10));
    assert_eq!(doc.partner(7), None);
    let doc = SourceDocument::new("(a 5\\% )");
    assert_eq!(doc.partner(0), Some(7));
}
