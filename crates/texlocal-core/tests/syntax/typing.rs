//! Typing, as the Mac's source editor did it in Swift (its SourceEditorTests'
//! cases), through an editor that applies the answers as a text view does:
//! each change reported back (`follow`), each selection (`select`), and a
//! snippet's field mirrored once the text has changed. In a text, ‸ marks a
//! caret and «» a selection.

use texlocal_core::syntax::{Change, Completing, SnippetField, SourceDocument, Style};
use texlocal_core::syntax::{TextEdit, TextRange, map_selections};

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

fn edit(start: u32, length: u32, text: &str) -> TextEdit {
    let text = text.into();
    TextEdit {
        start,
        length,
        text,
    }
}

fn units(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}

/// The text without its marks, and the selections they mark.
fn unmarked(marked: &str) -> (String, Vec<TextRange>) {
    let (mut text, mut selections, mut from) = (String::new(), vec![], 0);
    for c in marked.chars() {
        let at = units(&text);
        match c {
            '‸' => selections.push(range(at, 0)),
            '«' => from = at,
            '»' => selections.push(range(from, at - from)),
            c => text.push(c),
        }
    }
    (text, selections)
}

struct Editor {
    doc: SourceDocument,
    text: Vec<u16>,
    selections: Vec<TextRange>,
    auto_pair: bool,
    mirroring: bool,
}

impl Editor {
    /// The marked text, a caret at its end if it marks none.
    fn open(marked: &str) -> Self {
        let (text, mut selections) = unmarked(marked);
        if selections.is_empty() {
            selections.push(range(units(&text), 0));
        }
        let (doc, text) = (SourceDocument::new(&text), text.encode_utf16().collect());
        let mut editor = Self {
            doc,
            text,
            selections: vec![],
            auto_pair: true,
            mirroring: false,
        };
        editor.select(selections);
        editor
    }

    /// The text, its selections marked.
    fn shown(&self) -> String {
        let mut marks: Vec<(u32, char)> = vec![];
        for &TextRange { start, length } in &self.selections {
            match length {
                0 => marks.push((start, '‸')),
                _ => marks.extend([(start, '«'), (start + length, '»')]),
            }
        }
        marks.sort_by_key(|&(at, _)| at);
        let (mut shown, mut from) = (String::new(), 0);
        for (at, mark) in marks {
            shown += &String::from_utf16(&self.text[from..at as usize]).unwrap();
            (shown, from) = (shown + &mark.to_string(), at as usize);
        }
        shown + &String::from_utf16(&self.text[from..]).unwrap()
    }

    fn select(&mut self, selections: Vec<TextRange>) {
        self.doc.select(selections[0], self.mirroring);
        self.selections = selections;
    }

    /// The text storage's change, which the storage's delegate reports; the
    /// text view's selection follows it, or goes to `after`, before the
    /// change is done.
    fn replace(&mut self, e: &TextEdit, after: Option<TextRange>) {
        let (start, end) = (e.start as usize, (e.start + e.length) as usize);
        self.text.splice(start..end, e.text.encode_utf16());
        self.doc.edit(e.start, e.length, &e.text);
        let delta = units(&e.text) as i64 - e.length as i64;
        self.doc
            .follow(range(e.start, e.length), delta, None, self.mirroring);
        let moved = map_selections(std::slice::from_ref(e), &self.selections);
        self.select(after.map_or(moved, |after| vec![after]));
        // What's typed in a field goes in its other places too.
        let edits = if self.mirroring {
            vec![]
        } else {
            self.doc.mirror_snippet()
        };
        if !edits.is_empty() {
            let selection = self.selections[0];
            self.mirroring = true;
            for e in &edits {
                self.replace(e, None);
            }
            self.mirroring = false;
            self.select(vec![selection]);
        }
    }

    /// Typed as a key types: in place of its range, the caret after it.
    fn type_edit(&mut self, e: &TextEdit) {
        self.replace(e, Some(range(e.start + units(&e.text), 0)));
    }

    /// Each key in turn: ⌫ is Delete, ⏎ Return, ⇥ Tab and ⇤ Shift-Tab, and
    /// any other character is typed. A key the document leaves to the text
    /// view does what a text view does.
    fn keys(&mut self, keys: &str) {
        for key in keys.chars() {
            let at = self.selections[0];
            let answer = match key {
                '⇥' | '⇤' => {
                    self.tab(if key == '⇥' { 1 } else { -1 });
                    continue;
                }
                '⌫' => self.doc.delete_backward(at, self.auto_pair),
                '⏎' => self.doc.insert_newline(at),
                typed => self.doc.type_text(at, &typed.to_string(), self.auto_pair),
            };
            if answer.edit.is_none() && answer.selection.is_none() {
                let own = match key {
                    '⌫' if at.length == 0 => edit(at.start - 1, 1, ""),
                    '⌫' => edit(at.start, at.length, ""),
                    '⏎' => panic!("Return is the document's"),
                    typed => edit(at.start, at.length, &typed.to_string()),
                };
                self.type_edit(&own);
            }
            if let Some(e) = &answer.edit {
                self.type_edit(e);
            }
            if let Some(selection) = answer.selection {
                self.select(vec![selection]);
            }
        }
    }

    /// Edits from the last, as one step, then the change's selections.
    fn apply(&mut self, change: Change) {
        for e in change.edits.iter().rev() {
            self.replace(e, None);
        }
        self.select(change.selections);
    }

    /// The change the document answers for the selections, applied.
    fn change(&mut self, answer: impl FnOnce(&mut SourceDocument, &[TextRange]) -> Change) {
        let change = answer(&mut self.doc, &self.selections);
        self.apply(change);
    }

    /// An insertion's edit, its caret, and its fields, if it has any, begun.
    fn insert(&mut self, e: TextEdit, caret: u32, fields: &[SnippetField]) {
        let at = e.start;
        let selections = vec![range(caret, 0)];
        self.apply(Change {
            edits: vec![e],
            selections,
        });
        if let Some(first) = self.doc.start_snippet(fields, at) {
            self.select(vec![first]);
        }
    }

    fn tab(&mut self, step: i64) {
        let tab = self.doc.tab(&self.selections.clone(), step);
        if let Some(field) = tab.field {
            self.select(vec![field]);
        } else if !tab.edits.is_empty() {
            let selections = map_selections(&tab.edits, &self.selections);
            let edits = tab.edits;
            self.apply(Change { edits, selections });
        }
    }
}

/// Keys typed in a text, and the text after.
#[test]
fn keys_type_as_the_editor_assists() {
    for (before, keys, after) in [
        // Brackets close and are stepped over; before a word, only the one typed.
        ("‸", "{", "{‸}"),
        ("‸", "{}", "{}‸"),
        ("‸x", "(", "(‸x"),
        // Round a selection, which stays selected.
        ("«ab»", "[", "[«ab»]"),
        // An empty pair the editor closed goes as one; one that was there
        // loses only its bracket.
        ("‸", "{⌫", "‸"),
        ("{‸}", "⌫", "‸}"),
        // Escaped brackets close escaped.
        ("\\‸", "[", "\\[‸\\]"),
        ("\\‸", "[x\\]", "\\[x\\]‸"),
        // A command typed inside keeps the closer whole, and the bracket
        // alone steps over it.
        ("\\‸", "(\\pi", "\\(\\pi‸\\)"),
        ("\\‸", "(\\pi)", "\\(\\pi\\)‸"),
        ("\\‸", "{", "\\{‸\\}"),
        ("\\‸", "{⌫", "\\‸"),
        ("\\‸", "[⏎", "\\[\n‸\n\\]"),
        ("\\\\‸", "[", "\\\\[‸]"),
        // An emoji after an opening bracket is occupied text, and a bracket
        // with a mark on it is no bracket.
        ("‸😀", "(", "(‸😀"),
        ("‸}\u{301}", "{", "{‸}\u{301}"),
        // New lines keep the indentation; between brackets, the closing one a
        // line further down.
        ("  a‸", "⏎", "  a\n  ‸"),
        ("  a{‸}", "⏎", "  a{\n  ‸\n  }"),
        // The spaces after the caret go; a caret in the indentation takes it down.
        ("\ta‸  b", "⏎", "\ta\n\t‸b"),
        ("  ‸  x", "⏎", "\n    ‸x"),
        // Tab and Shift-Tab indent by two spaces; Delete in the indentation
        // goes back to a stop.
        ("‸x", "⇥", "  ‸x"),
        ("‸x", "⇥⇤", "‸x"),
        ("     ‸y", "⌫", "    ‸y"),
        ("     ‸y", "⌫⌫", "  ‸y"),
    ] {
        let mut e = Editor::open(before);
        e.keys(keys);
        assert_eq!(e.shown(), after, "{keys:?} in {before:?}");
        assert_eq!(e.doc.text(), String::from_utf16(&e.text).unwrap());
    }
}

#[test]
fn a_closer_is_stepped_over_only_on_its_own_line_and_with_assistance_on() {
    let mut e = Editor::open("‸");
    e.keys("(");
    e.select(vec![range(2, 0)]);
    e.keys("⏎");
    e.select(vec![range(1, 0)]);
    e.keys(")");
    assert_eq!(e.shown(), "()‸)\n");
    for (before, keys, after) in [("‸", "{", "{‸"), ("{‸}", "⌫", "‸}")] {
        let mut e = Editor::open(before);
        e.auto_pair = false;
        e.keys(keys);
        assert_eq!(e.shown(), after);
    }
    // Nor once the document is shown again, which forgets the closers.
    let mut e = Editor::open("‸");
    e.keys("(");
    e.doc.reset_typing();
    e.keys(")");
    assert_eq!(e.shown(), "()‸)");
}

#[test]
fn keys_say_what_the_completion_list_does() {
    let mut doc = SourceDocument::new("\\");
    let caret = range(1, 0);
    let key = doc.type_text(caret, "b", true);
    assert_eq!(key.completions, Completing::Offer);
    assert_eq!((key.edit, key.selection), (None, None));
    let typed = doc.type_text(caret, "日本", true);
    assert_eq!(typed.completions, Completing::Close);
    assert_eq!(
        doc.type_text(caret, "{", true).completions,
        Completing::Offer
    );
    // A closing bracket typed shows its partner.
    assert_eq!(doc.type_text(caret, ")", true).partner, Some(1));
}

#[test]
fn styles_wrap_and_unwrap_the_selection_and_comments_map_it() {
    let mut e = Editor::open("«word»");
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    assert_eq!(e.shown(), "\\textbf{«word»}");
    e.change(|doc, s| doc.wrap(s, "\\ref{$0}"));
    assert_eq!(e.shown(), "\\textbf{\\ref{«word»}}");
    // Inline and display maths, and a template without "$0".
    let mut e = Editor::open("«x»");
    e.change(|doc, s| doc.wrap(s, "$$0$"));
    assert_eq!(e.shown(), "$«x»$");
    e.change(|doc, s| doc.wrap(s, "\\[$0\\]"));
    assert_eq!(e.shown(), "$\\[«x»\\]$");
    let change = e.doc.wrap(&[range(0, 0)], "\\today");
    assert_eq!(change.edits[0].text, "\\today");

    // A style the selection is in unwraps; with the caret in it, the whole command.
    let mut e = Editor::open("a \\textit{b \\textbf{«word»} c} d");
    e.change(|doc, s| doc.toggle_style(s, Style::Bold));
    assert_eq!(e.shown(), "a \\textit{b «word» c} d");
    e.change(|doc, s| doc.toggle_style(s, Style::Underline));
    assert_eq!(e.shown(), "a \\textit{b \\underline{«word»} c} d");
    e.select(vec![range(11, 0)]);
    e.change(|doc, s| doc.toggle_style(s, Style::Italic));
    assert_eq!(e.shown(), "a b‸ \\underline{word} c d");

    let mut e = Editor::open("«a\n  b»");
    e.change(|doc, s| {
        let edits = doc.toggle_comment(s);
        let selections = map_selections(&edits, s);
        Change { edits, selections }
    });
    assert_eq!(e.shown(), "% «a\n%   b»");
    assert_eq!(e.doc.text(), "% a\n%   b");
}

#[test]
fn a_block_tabs_through_its_fields_and_ends_at_the_last() {
    let mut e = Editor::open("");
    let block = e.doc.insert_block("figure", e.selections[0]).unwrap();
    e.insert(block.edit, block.caret, &block.fields);
    for field in ["\\linewidth]{‸}", "\\caption{‸}", "\\label{fig:‸}"] {
        assert!(e.shown().contains(field), "{field} in {}", e.shown());
        e.tab(1);
    }
    // Past the last field, Tab indents again.
    assert!(
        e.doc.text().contains("\n    \\label{fig:}"),
        "{}",
        e.shown()
    );
}

#[test]
fn a_field_in_two_places_is_typed_in_both_until_the_snippet_ends() {
    let offer = SourceDocument::new("\\beg").call("completions", r#"{"caret": 4}"#);
    let item = &serde_json::from_str::<serde_json::Value>(&offer.unwrap()).unwrap()["items"][0];
    let text = item["text"].as_str().unwrap();
    let fields: Vec<SnippetField> = serde_json::from_value(item["fields"].clone()).unwrap();
    let mut e = Editor::open("\\beg");
    e.insert(edit(0, 4, text), units(text), &fields);
    assert_eq!(e.shown(), "\\begin{«env»}\n  \n\\end{env}");
    e.keys("fig");
    assert_eq!(e.shown(), "\\begin{fig‸}\n  \n\\end{fig}");
    e.keys("⌫");
    assert_eq!(e.shown(), "\\begin{fi‸}\n  \n\\end{fi}");
    e.tab(1);
    assert_eq!(e.shown(), "\\begin{fi}\n  ‸\n\\end{fi}");

    // Selecting outside the fields ends it.
    let mut e = Editor::open("\\beg");
    e.insert(edit(0, 4, text), 0, &fields);
    e.select(vec![range(0, 0)]);
    e.keys("x");
    e.select(vec![range(8, 0)]);
    e.keys("y");
    assert_eq!(e.shown(), "x\\begin{y‸env}\n  \n\\end{env}");
    // As do Escape and showing the document again.
    let fields = [0, 1].map(|at| SnippetField {
        start: at,
        length: 0,
        index: at,
    });
    let mut doc = SourceDocument::new("ab");
    assert!(doc.start_snippet(&fields, 0).is_some());
    assert!(doc.end_snippet() && !doc.end_snippet());
    assert!(doc.start_snippet(&fields, 0).is_some());
    doc.reset_typing();
    assert!(!doc.end_snippet());
}

#[test]
fn lines_move_up_and_down_with_their_selections() {
    let up = |doc: &mut SourceDocument, s: &[TextRange]| doc.move_lines(s, true).unwrap();
    let down = |doc: &mut SourceDocument, s: &[TextRange]| doc.move_lines(s, false).unwrap();
    let mut e = Editor::open("a\n‸b\nc\nd");
    e.change(up);
    assert_eq!(e.shown(), "‸b\na\nc\nd");
    assert_eq!(e.doc.move_lines(&e.selections, true), None);
    // Down to the end: the moved line takes the last one's place, without its break.
    e.select(vec![range(4, 1)]);
    e.change(down);
    assert_eq!(e.shown(), "b\na\nd\n«c»");
    assert_eq!(e.doc.move_lines(&e.selections, false), None);
    e.change(up);
    assert_eq!(e.shown(), "b\na\n«c»\nd");
    assert_eq!(e.doc.text(), "b\na\nc\nd");
    // The empty line after a final line break has nothing to move.
    let mut e = Editor::open("a\n‸");
    assert_eq!(e.doc.move_lines(&e.selections, true), None);
    // CRLF ends a line as one.
    let mut e = Editor::open("a\r\nb‸");
    e.change(up);
    assert_eq!(e.shown(), "b‸\r\na");
    // Lines 2–3 (selected up to line 4's start) and line 5, together.
    let mut e = Editor::open("1\n«2\n3\n»4\n«5»\n6");
    e.change(up);
    assert_eq!(e.shown(), "«2\n3\n»1\n«5»\n4\n6");
    assert_eq!(e.doc.text(), "2\n3\n1\n5\n4\n6");
}

#[test]
fn a_bracket_finds_its_partner_near_it() {
    let mut doc = SourceDocument::new("(a [b] {c}) ]");
    let partners = [0, 10, 3, 12, 1, 99].map(|at| doc.partner(at));
    assert_eq!(partners, [Some(10), Some(0), Some(5), None, None, None]);
    let far = format!("({})", "x".repeat(10_000));
    assert_eq!(SourceDocument::new(&far).partner(0), None);
    let near = format!("({})", "x".repeat(9_999));
    assert_eq!(SourceDocument::new(&near).partner(0), Some(10_000));
}

/// The commands as the C ABI sends them, each answered as JSON.
#[test]
fn typing_answers_by_name() {
    let mut doc = SourceDocument::new("");
    // Each a command, its arguments and its answer.
    for case in [
        r#"type {"selection": {"start": 0, "length": 0}, "text": "{"} => {"edit":{"start":0,"length":0,"text":"{}"},"selection":{"start":1,"length":0},"partner":null,"completions":"offer"}"#,
        r#"type {"selection": {"start": 0, "length": 0}, "text": "{", "autoPair": false} => {"edit":null,"selection":null,"partner":null,"completions":"offer"}"#,
        r#"map_selections {"edits": [{"start": 0, "length": 0, "text": "ab"}], "selections": [{"start": 0, "length": 1}]} => [{"start":2,"length":1}]"#,
        r#"tab {"selections": [{"start": 0, "length": 0}]} => {"field":null,"edits":[{"start":0,"length":0,"text":"  "}]}"#,
        // An edit's following and a selection's are the C ABI's own.
        r#"follow {"old": {"start": 0, "length": 0}, "delta": 2} => none"#,
        r#"toggle_style {"style": "strong"} => none"#,
    ] {
        let (command, rest) = case.split_once(' ').unwrap();
        let (args, answer) = rest.split_once(" => ").unwrap();
        let found = doc.call(command, args).unwrap_or("none".into());
        assert_eq!(found, answer, "{case}");
    }
}
