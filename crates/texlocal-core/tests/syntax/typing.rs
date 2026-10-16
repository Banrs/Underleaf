//! Typing, as the Mac's source editor did it in Swift (its SourceEditorTests'
//! cases), through an editor that applies the answers as a text view does:
//! each change reported back (`follow`), each selection (`select`), and a
//! snippet's field mirrored once the text has changed.

use texlocal_core::syntax::{
    Change, Completing, Keystroke, SourceDocument, Style, TextEdit, TextRange, map_selections,
};

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

fn units(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}

struct Editor {
    doc: SourceDocument,
    text: Vec<u16>,
    selections: Vec<TextRange>,
    auto_pair: bool,
    mirroring: bool,
}

impl Editor {
    fn open(text: &str, caret: Option<u32>) -> Editor {
        let mut editor = Editor {
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

    fn apply_key(&mut self, key: Keystroke, own: impl FnOnce(&mut Self)) -> Keystroke {
        if key.edit.is_none() && key.selection.is_none() {
            own(self);
        }
        if let Some(e) = &key.edit {
            self.type_edit(e);
        }
        if let Some(selection) = key.selection {
            self.set_selection(selection);
        }
        key
    }

    fn type_text(&mut self, typed: &str) -> Keystroke {
        let key = self.doc.type_text(self.selection(), typed, self.auto_pair);
        let selection = self.selection();
        self.apply_key(key, |editor| {
            editor.type_edit(&TextEdit {
                start: selection.start,
                length: selection.length,
                text: typed.into(),
            })
        })
    }

    fn type_all(&mut self, typed: &str) {
        for c in typed.chars() {
            self.type_text(&c.to_string());
        }
    }

    fn delete_backward(&mut self) {
        let key = self.doc.delete_backward(self.selection(), self.auto_pair);
        let selection = self.selection();
        self.apply_key(key, |editor| {
            let e = if selection.length > 0 {
                TextEdit {
                    start: selection.start,
                    length: selection.length,
                    text: String::new(),
                }
            } else {
                TextEdit {
                    start: selection.start - 1,
                    length: 1,
                    text: String::new(),
                }
            };
            editor.type_edit(&e);
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

fn caret(at: u32) -> TextRange {
    range(at, 0)
}

#[test]
fn brackets_close_and_are_stepped_over() {
    let mut e = Editor::open("", None);
    e.type_text("{");
    assert_eq!((e.string().as_str(), e.selection()), ("{}", caret(1)));
    e.type_text("}");
    assert_eq!((e.string().as_str(), e.selection()), ("{}", caret(2)));
    // Before a word, only the one typed.
    let mut e = Editor::open("x", Some(0));
    e.type_text("(");
    assert_eq!(e.string(), "(x");
    // Round a selection, which stays selected.
    let mut e = Editor::open("ab", None);
    e.set_selection(range(0, 2));
    e.type_text("[");
    assert_eq!((e.string().as_str(), e.selection()), ("[ab]", range(1, 2)));
    // An empty pair the editor closed goes as one; one that was there loses only its bracket.
    let mut e = Editor::open("", None);
    e.type_text("{");
    e.delete_backward();
    assert_eq!(e.string(), "");
    let mut e = Editor::open("{}", Some(1));
    e.delete_backward();
    assert_eq!(e.string(), "}");
    // A closer left on a line above isn't stepped over.
    let mut e = Editor::open("", None);
    e.type_text("(");
    e.set_selection(caret(2));
    e.newline();
    e.set_selection(caret(1));
    e.type_text(")");
    assert_eq!(e.string(), "())\n");
}

#[test]
fn escaped_brackets_close_escaped() {
    let mut e = Editor::open("\\", None);
    e.type_text("[");
    assert_eq!((e.string().as_str(), e.selection()), ("\\[\\]", caret(2)));
    e.type_all("x\\]");
    assert_eq!((e.string().as_str(), e.selection()), ("\\[x\\]", caret(5)));
    // A command typed inside keeps the closer whole, and the bracket alone steps over it.
    let mut e = Editor::open("\\", None);
    e.type_all("(\\pi");
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("\\(\\pi\\)", caret(5))
    );
    e.type_text(")");
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("\\(\\pi\\)", caret(7))
    );
    let mut e = Editor::open("\\", None);
    e.type_text("{");
    assert_eq!(e.string(), "\\{\\}");
    e.delete_backward();
    assert_eq!(e.string(), "\\");
    let mut e = Editor::open("\\", None);
    e.type_text("[");
    e.newline();
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("\\[\n\n\\]", caret(3))
    );
    let mut e = Editor::open("\\\\", None);
    e.type_text("[");
    assert_eq!(e.string(), "\\\\[]");
}

#[test]
fn typing_assistance_can_be_turned_off() {
    let mut e = Editor::open("", None);
    e.auto_pair = false;
    e.type_text("{");
    assert_eq!(e.string(), "{");
    let mut e = Editor::open("{}", Some(1));
    e.auto_pair = false;
    e.delete_backward();
    assert_eq!(e.string(), "}");
}

#[test]
fn an_emoji_after_an_opening_bracket_is_occupied_text() {
    let mut e = Editor::open("😀", Some(0));
    e.type_text("(");
    assert_eq!((e.string().as_str(), e.selection()), ("(😀", caret(1)));
    // A bracket with a mark on it is no bracket.
    let mut e = Editor::open("}\u{301}", Some(0));
    e.type_text("{");
    assert_eq!(e.string(), "{}\u{301}");
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
fn new_lines_keep_the_indentation() {
    let mut e = Editor::open("  a", Some(3));
    e.newline();
    assert_eq!((e.string().as_str(), e.selection()), ("  a\n  ", caret(6)));
    // Between brackets, the closing one a line further down.
    let mut e = Editor::open("  a{}", Some(4));
    e.newline();
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("  a{\n  \n  }", caret(7))
    );
    // The spaces after the caret go; a caret in the indentation takes it down.
    let mut e = Editor::open("\ta  b", Some(2));
    e.newline();
    assert_eq!((e.string().as_str(), e.selection()), ("\ta\n\tb", caret(4)));
    let mut e = Editor::open("    x", Some(2));
    e.newline();
    assert_eq!((e.string().as_str(), e.selection()), ("\n    x", caret(5)));
    // Tab and Shift-Tab indent by two spaces; Delete in the indentation back to a stop.
    let mut e = Editor::open("x", Some(0));
    e.tab(1);
    assert_eq!(e.string(), "  x");
    e.tab(-1);
    assert_eq!(e.string(), "x");
    let mut e = Editor::open("     y", Some(5));
    e.delete_backward();
    assert_eq!(e.string(), "    y");
    e.delete_backward();
    assert_eq!(e.string(), "  y");
}

#[test]
fn wrapping_keeps_the_selection() {
    let mut e = Editor::open("word", None);
    e.set_selection(range(0, 4));
    let change = e.doc.toggle_style(&e.selections.clone(), Style::Bold);
    e.apply(change);
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("\\textbf{word}", range(8, 4))
    );
    let change = e.doc.wrap(&e.selections.clone(), "\\ref{$0}");
    e.apply(change);
    assert_eq!(e.string(), "\\textbf{\\ref{word}}");
    // Inline and display maths, and a template without "$0".
    let mut e = Editor::open("x", None);
    e.set_selection(range(0, 1));
    let change = e.doc.wrap(&e.selections.clone(), "$$0$");
    e.apply(change);
    assert_eq!((e.string().as_str(), e.selection()), ("$x$", range(1, 1)));
    let change = e.doc.wrap(&e.selections.clone(), "\\[$0\\]");
    e.apply(change);
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
    let change = e.doc.toggle_style(&e.selections.clone(), Style::Bold);
    e.apply(change);
    assert_eq!(e.string(), "a \\textit{b word c} d");
    assert_eq!(e.selection(), range(word - 8, 4));
    let change = e.doc.toggle_style(&e.selections.clone(), Style::Underline);
    e.apply(change);
    assert_eq!(e.string(), "a \\textit{b \\underline{word} c} d");
    // The caret in it, the whole command goes.
    e.set_selection(caret(11));
    let change = e.doc.toggle_style(&e.selections.clone(), Style::Italic);
    e.apply(change);
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("a b \\underline{word} c d", caret(3))
    );
    assert_eq!(e.doc.text(), e.string());
}

#[test]
fn comments_map_the_selection() {
    let mut e = Editor::open("a\n  b", None);
    e.set_selection(range(0, 5));
    let edits = e.doc.toggle_comment(&e.selections.clone());
    let selections = map_selections(&edits, &e.selections);
    e.apply(Change { edits, selections });
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("% a\n%   b", range(2, 7))
    );
}

#[test]
fn blocks_tab_through_their_fields() {
    let mut e = Editor::open("", None);
    let insertion = e.doc.insert_block("figure", e.selection()).unwrap();
    e.apply(Change {
        edits: vec![insertion.edit.clone()],
        selections: vec![caret(insertion.caret)],
    });
    let first = e.doc.start_snippet(&insertion.fields, insertion.edit.start);
    e.set_selection(first.unwrap());
    let string = e.string();
    let at = |s: &str| units(&string[..string.find(s).unwrap()]);
    assert_eq!(e.selection(), caret(at("]{}") + 2));
    e.tab(1);
    assert_eq!(e.selection(), caret(at("\\caption{") + 9));
    e.tab(1);
    assert_eq!(e.selection(), caret(at("fig:") + 4));
    // The last field ends the snippet: Tab indents again.
    e.tab(1);
    assert!(e.string().contains("\n    \\label{fig:}"), "{}", e.string());
}

#[test]
fn a_field_in_two_places_is_typed_in_both() {
    let mut e = Editor::open("\\beg", None);
    let offer = e.doc.completions(4, false, &[], &[]).unwrap();
    let item = &offer.items[0];
    e.apply(Change {
        edits: vec![TextEdit {
            start: offer.start,
            length: 4 - offer.start,
            text: item.text.clone(),
        }],
        selections: vec![caret(offer.start + units(&item.text))],
    });
    let first = e.doc.start_snippet(&item.fields, offer.start).unwrap();
    e.set_selection(first);
    assert_eq!(first, range(7, 3));
    e.type_all("fig");
    assert_eq!(e.string(), "\\begin{fig}\n  \n\\end{fig}");
    assert_eq!(e.selection(), caret(10));
    e.delete_backward();
    assert_eq!(e.string(), "\\begin{fi}\n  \n\\end{fi}");
    e.tab(1);
    assert_eq!(e.selection(), caret(13));
    // Selecting outside the fields ends the snippet.
    let mut e = Editor::open("\\beg", None);
    let item = &e.doc.completions(4, false, &[], &[]).unwrap().items[0];
    let (text, fields) = (item.text.clone(), item.fields.clone());
    e.apply(Change {
        edits: vec![TextEdit {
            start: 0,
            length: 4,
            text,
        }],
        selections: vec![caret(0)],
    });
    let first = e.doc.start_snippet(&fields, 0).unwrap();
    e.set_selection(first);
    e.set_selection(caret(0));
    e.type_text("x");
    e.set_selection(caret(8));
    e.type_text("y");
    assert_eq!(e.string(), "x\\begin{yenv}\n  \n\\end{env}");
    // Escape ends one.
    let mut doc = SourceDocument::new("ab");
    let field = |start, index| texlocal_core::syntax::SnippetField {
        start,
        length: 0,
        index,
    };
    assert!(doc.start_snippet(&[field(0, 0), field(1, 1)], 0).is_some());
    assert!(doc.end_snippet());
    assert!(!doc.end_snippet());
}

#[test]
fn resetting_typing_forgets_the_closers_and_the_snippet() {
    // The closer put in is stepped over by the bracket typed...
    let mut e = Editor::open("", None);
    e.type_text("(");
    e.set_selection(caret(1));
    e.type_text(")");
    assert_eq!((e.string().as_str(), e.selection()), ("()", caret(2)));
    // ...but not once the document is shown again.
    let mut e = Editor::open("", None);
    e.type_text("(");
    e.set_selection(caret(1));
    e.doc.reset_typing();
    e.type_text(")");
    assert_eq!((e.string().as_str(), e.selection()), ("())", caret(2)));
    // A snippet is over.
    let mut doc = SourceDocument::new("ab");
    let field = |start, index| texlocal_core::syntax::SnippetField {
        start,
        length: 0,
        index,
    };
    assert!(doc.start_snippet(&[field(0, 0), field(1, 1)], 0).is_some());
    doc.reset_typing();
    assert!(!doc.end_snippet());
}

#[test]
fn lines_move_up_and_down() {
    let mut e = Editor::open("a\nb\nc\nd", Some(2));
    let change = e.doc.move_lines(&e.selections.clone(), true).unwrap();
    e.apply(change);
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("b\na\nc\nd", caret(0))
    );
    assert_eq!(e.doc.move_lines(&e.selections.clone(), true), None);
    // Down to the end: the moved line takes the last one's place, without its break.
    e.set_selection(range(4, 1));
    let change = e.doc.move_lines(&e.selections.clone(), false).unwrap();
    e.apply(change);
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("b\na\nd\nc", range(6, 1))
    );
    assert_eq!(e.doc.move_lines(&e.selections.clone(), false), None);
    let change = e.doc.move_lines(&e.selections.clone(), true).unwrap();
    e.apply(change);
    assert_eq!(
        (e.string().as_str(), e.selection()),
        ("b\na\nc\nd", range(4, 1))
    );
    assert_eq!(e.doc.text(), e.string());
    // The empty line after a final line break has nothing to move.
    let e = Editor::open("a\n", None);
    assert_eq!(e.doc.move_lines(&e.selections, true), None);
    // CRLF ends a line as one.
    let mut e = Editor::open("a\r\nb", None);
    let change = e.doc.move_lines(&e.selections.clone(), true).unwrap();
    e.apply(change);
    assert_eq!((e.string().as_str(), e.selection()), ("b\r\na", caret(1)));
}

#[test]
fn several_selections_move_together() {
    let mut e = Editor::open("1\n2\n3\n4\n5\n6", Some(0));
    // Lines 2–3 (selected up to line 4's start) and line 5.
    e.set_selections(vec![range(2, 4), range(8, 1)]);
    let change = e.doc.move_lines(&e.selections.clone(), true).unwrap();
    e.apply(change);
    assert_eq!(e.string(), "2\n3\n1\n5\n4\n6");
    assert_eq!(e.selections, [range(0, 4), range(6, 1)]);
    assert_eq!(e.doc.text(), e.string());
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
fn typing_answers_by_name() {
    let mut doc = SourceDocument::new("");
    let key = doc.call(
        "type",
        r#"{"selection": {"start": 0, "length": 0}, "text": "{"}"#,
    );
    assert_eq!(
        key.as_deref(),
        Some(
            r#"{"edit":{"start":0,"length":0,"text":"{}"},"selection":{"start":1,"length":0},"partner":null,"completions":"offer"}"#
        )
    );
    let off = r#"{"selection": {"start": 0, "length": 0}, "text": "{", "autoPair": false}"#;
    assert!(doc.call("type", off).unwrap().contains(r#""edit":null"#));
    let follow = r#"{"old": {"start": 0, "length": 0}, "delta": 2}"#;
    assert_eq!(doc.call("follow", follow).as_deref(), Some("null"));
    assert_eq!(doc.call("toggle_style", r#"{"style": "strong"}"#), None);
    let edits = r#"{"edits": [{"start": 0, "length": 0, "text": "ab"}], "selections": [{"start": 0, "length": 1}]}"#;
    assert_eq!(
        doc.call("map_selections", edits).as_deref(),
        Some(r#"[{"start":2,"length":1}]"#)
    );
    assert_eq!(
        doc.call("tab", r#"{"selections": [{"start": 0, "length": 0}]}"#)
            .as_deref(),
        Some(r#"{"field":null,"edits":[{"start":0,"length":0,"text":"  "}]}"#)
    );
}
