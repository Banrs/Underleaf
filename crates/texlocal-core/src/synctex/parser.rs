//! The SyncTeX file TeX writes beside its PDF, read and searched as TeX Live's synctex program
//! does (synctex_parser.c, version 1.21), so the answers are the program's without running it.
//! A PDF form's content shows on no page here, and content without the
//! Postamble a finished run writes (Live Preview's while TeX hasn't reached the end) is used
//! as far as it goes, where the program answers nothing.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;
use std::sync::Arc;

use crate::stamp::Kept;

/// What is nowhere near, as synctex's `INT_MAX`.
const FAR: i64 = i32::MAX as i64;
/// synctex keeps its nodes in this many lists by tag plus line ("friends").
const LISTS: usize = 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Sheet,
    Form,
    VBox,
    HBox,
    VoidVBox,
    VoidHBox,
    Kern,
    Glue,
    Rule,
    Math,
    Boundary,
    /// An hbox's first and last child, which the reader adds.
    BoxBoundary,
    /// A use of a form, which goes once read.
    Ref,
}

impl Kind {
    fn is_box(self) -> bool {
        matches!(
            self,
            Self::HBox | Self::VoidHBox | Self::VBox | Self::VoidVBox
        )
    }

    fn is_hbox(self) -> bool {
        matches!(self, Self::HBox | Self::VoidHBox)
    }
}

/// In scaled points from the page's top left, v going down.
#[derive(Clone, Copy, Default)]
struct Extent {
    h: i32,
    v: i32,
    width: i32,
    height: i32,
    depth: i32,
}

/// Where in which input a node comes from: its tag, line and column.
type Place = (i32, i32, i32);

struct Node {
    kind: Kind,
    tag: i32,
    line: i32,
    column: i32,
    /// Its sheet's, or -1 in a form.
    page: i32,
    at: Extent,
    /// An hbox grown round what it holds (synctex's `_V` values); for the rest, `at`.
    seen: Extent,
    /// An hbox's lines' mean, weighted by its nodes, and their count.
    mean_line: i32,
    weight: i32,
    parent: Option<u32>,
    child: Option<u32>,
    sibling: Option<u32>,
}

/// One result of a forward search, in PDF points from the page's top left: `v` is the box's
/// bottom and `height` takes its depth in.
pub(super) struct Shown {
    pub page: i32,
    pub h: f32,
    pub v: f32,
    pub width: f32,
    pub height: f32,
}

struct Sheet {
    page: i32,
    node: u32,
    /// Its hboxes as they close; synctex chains them the last first.
    hboxes: Vec<u32>,
}

struct Input {
    tag: i32,
    name: String,
    /// The last line any node gives the input.
    last_line: i32,
}

pub(super) struct SyncTex {
    nodes: Vec<Node>,
    sheets: Vec<Sheet>,
    /// By tag, which TeX numbers them by in the order it opens them: the newest last.
    inputs: BTreeMap<i32, Input>,
    /// Nodes by `(tag + line) % LISTS`, the oldest first.
    friends: Vec<Vec<u32>>,
    magnification: i32,
    unit: f32,
    x_offset: f32,
    y_offset: f32,
}

impl SyncTex {
    /// `name.synctex` beside `name.pdf`, else `name.synctex.gz`, in the program's order; parsed
    /// again only once it changes, as a thesis's takes a while.
    pub fn beside(pdf: &Path) -> std::io::Result<Arc<Self>> {
        static PARSED: Kept<SyncTex> = Kept::new();
        let plain = pdf.with_extension("synctex");
        let file = if plain.is_file() {
            plain
        } else {
            plain.with_extension("synctex.gz")
        };
        PARSED.get(&file, Self::read)
    }

    fn read(file: &Path) -> std::io::Result<Self> {
        let bytes = std::fs::read(file)?;
        let bytes = if bytes.starts_with(&[0x1f, 0x8b]) {
            let mut unzipped = Vec::new();
            flate2::read::MultiGzDecoder::new(&bytes[..]).read_to_end(&mut unzipped)?;
            unzipped
        } else {
            bytes
        };
        Self::parse(&bytes).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "not a SyncTeX file")
        })
    }

    /// Each input's tag and name as TeX opened it, the newest first.
    pub fn inputs(&self) -> impl Iterator<Item = (i32, &str)> {
        let inputs = self.inputs.values().rev();
        inputs.map(|input| (input.tag, input.name.as_str()))
    }

    fn node(&self, id: u32) -> &Node {
        &self.nodes[id as usize]
    }

    fn children(&self, id: u32) -> impl Iterator<Item = u32> + '_ {
        std::iter::successors(self.node(id).child, |&child| self.node(child).sibling)
    }

    fn visible_h(&self, d: i32) -> f32 {
        d as f32 * self.unit + self.x_offset
    }

    fn visible_v(&self, d: i32) -> f32 {
        d as f32 * self.unit + self.y_offset
    }

    fn visible_size(&self, s: i32) -> f32 {
        s as f32 * self.unit
    }
}

// MARK: - Reading

/// A record's fields, decoded as synctex's `_synctex_decode_*` do.
struct Fields<'a> {
    text: &'a [u8],
    at: usize,
}

/// `strtol`'s digits from `at`: the number and where it ends, or None without a digit.
fn number(text: &[u8], mut at: usize) -> Option<(i32, usize)> {
    while text.get(at).is_some_and(u8::is_ascii_whitespace) {
        at += 1;
    }
    let negative = text.get(at) == Some(&b'-');
    if matches!(text.get(at), Some(b'-' | b'+')) {
        at += 1;
    }
    let start = at;
    let mut value: i64 = 0;
    while let Some(digit) = text.get(at).filter(|c| c.is_ascii_digit()) {
        value = value
            .saturating_mul(10)
            .saturating_add(i64::from(digit - b'0'));
        at += 1;
    }
    (at > start).then(|| ((if negative { -value } else { value }) as i32, at))
}

impl Fields<'_> {
    /// An integer after one optional `:` or `,`.
    fn int(&mut self) -> Option<i32> {
        let at = self.at + usize::from(matches!(self.text.get(self.at), Some(b':' | b',')));
        let (value, end) = number(self.text, at)?;
        self.at = end;
        Some(value)
    }

    /// A column, which only a `,` brings; -1 without one.
    fn column(&mut self) -> Option<i32> {
        if self.text.get(self.at) != Some(&b',') {
            return Some(-1);
        }
        let (value, end) = number(self.text, self.at + 1)?;
        self.at = end;
        Some(value)
    }

    /// A v, or `,=` for the last v read.
    fn v(&mut self, last: &mut i32) -> Option<i32> {
        if let Some(v) = self.int() {
            *last = v;
            Some(v)
        } else if self.text[self.at..].starts_with(b",=") {
            self.at += 2;
            Some(*last)
        } else {
            None
        }
    }
}

/// The list of the nodes with this tag and line, and others: none where they sum below 0.
fn friends_of(tag: i32, line: i32) -> Option<usize> {
    usize::try_from(i64::from(tag) + i64::from(line))
        .ok()
        .map(|key| key % LISTS)
}

/// The value after `name` at a line's start.
fn named<'a>(line: &'a [u8], name: &str) -> Option<&'a [u8]> {
    line.strip_prefix(name.as_bytes())
}

/// The state synctex's `__synctex_parse_sfi` keeps between records.
struct Reader {
    s: SyncTex,
    last_v: i32,
    sheet: Option<usize>,
    form: Option<u32>,
    parent: Option<u32>,
    child: Option<u32>,
    /// Per open box, the boundaries whose line may be wrong until the next node in the box
    /// gives them its own (synctex's `x_handle`); the oldest first.
    pending: Vec<Vec<u32>>,
    last_kern: Option<u32>,
    last_glue: Option<u32>,
    form_depth: i32,
    ignored_forms: i32,
}

impl SyncTex {
    fn parse(bytes: &[u8]) -> Option<Self> {
        let mut lines = bytes.split(|&c| c == b'\n').peekable();
        lines.find(|line| line.starts_with(b"SyncTeX Version:"))?;
        let mut inputs = BTreeMap::new();
        while let Some(input) = lines.peek().and_then(|line| Input::parse(line)) {
            inputs.insert(input.tag, input);
            lines.next();
        }
        lines.find(|line| line.starts_with(b"Output:"))?;
        let mut setting = |name: &str| {
            let value = lines.find_map(|line| named(line, name))?;
            number(value, 0).map(|(value, _)| value)
        };
        let (magnification, unit, x_offset, y_offset) = (
            setting("Magnification:")?,
            setting("Unit:")?,
            setting("X Offset:")?,
            setting("Y Offset:")?,
        );
        lines.find(|line| line.starts_with(b"Content:"))?;
        let magnification = if magnification > 0 {
            magnification
        } else {
            1000
        };
        let unit = if unit > 0 { unit } else { 8192 };
        let to_points = f64::from(unit) / 65781.76;
        let mut reader = Reader {
            s: Self {
                nodes: Vec::new(),
                sheets: Vec::new(),
                inputs,
                friends: vec![Vec::new(); LISTS],
                magnification,
                unit: ((to_points as f32) as f64 * (f64::from(magnification) / 1000.0)) as f32,
                x_offset: (f64::from(x_offset) * to_points) as f32,
                y_offset: (f64::from(y_offset) * to_points) as f32,
            },
            last_v: -1,
            sheet: None,
            form: None,
            parent: None,
            child: None,
            pending: vec![Vec::new()],
            last_kern: None,
            last_glue: None,
            form_depth: 0,
            ignored_forms: 0,
        };
        for line in lines {
            if !reader.record(line) {
                break;
            }
        }
        let mut s = reader.s;
        s.unlink_refs();
        Some(s)
    }

    /// A form's uses go: the program puts the form's content in their place.
    fn unlink_refs(&mut self) {
        for id in 0..self.nodes.len() as u32 {
            let mut link = self.node(id).child;
            let mut previous: Option<u32> = None;
            while let Some(child) = link {
                link = self.node(child).sibling;
                if self.node(child).kind == Kind::Ref {
                    match previous {
                        Some(previous) => self.nodes[previous as usize].sibling = link,
                        None => self.nodes[id as usize].child = link,
                    }
                } else {
                    previous = Some(child);
                }
            }
        }
    }
}

impl Input {
    fn parse(line: &[u8]) -> Option<Self> {
        let rest = named(line, "Input:")?;
        let (tag, end) = number(rest, 0)?;
        let name = rest.get(end + 1..)?;
        let name = String::from_utf8_lossy(name);
        Some(Self {
            tag,
            name: name.trim_end_matches(['\r', ' ']).to_owned(),
            last_line: 0,
        })
    }
}

impl Reader {
    /// One line; false at the Postamble.
    fn record(&mut self, line: &[u8]) -> bool {
        if self.ignored_forms > 0 {
            match line.first() {
                Some(b'<') => self.ignored_forms += 1,
                Some(b'>') => self.ignored_forms -= 1,
                _ => {}
            }
            if self.ignored_forms == 0 {
                self.reset_kern();
            }
            return true;
        }
        if self.sheet.is_none() && self.form.is_none() {
            return self.outside(line);
        }
        let first = line.first().copied().unwrap_or(b'\n');
        let handled = match first {
            b'<' => {
                self.begin_form(line);
                false
            }
            b'[' => self.begin_box(line, Kind::VBox),
            b'(' => self.begin_box(line, Kind::HBox),
            b']' if self
                .parent
                .is_some_and(|p| self.s.node(p).kind == Kind::VBox) =>
            {
                self.end_vbox();
                true
            }
            b')' if self
                .parent
                .is_some_and(|p| self.s.node(p).kind == Kind::HBox) =>
            {
                self.end_hbox();
                true
            }
            b'v' => self.leaf(line, Kind::VoidVBox),
            b'h' => self.leaf(line, Kind::VoidHBox),
            b'k' => self.leaf(line, Kind::Kern),
            b'g' => self.leaf(line, Kind::Glue),
            b'r' => self.leaf(line, Kind::Rule),
            b'$' => self.leaf(line, Kind::Math),
            b'x' => self.leaf(line, Kind::Boundary),
            b'f' => self.form_ref(line),
            b'}' if self.sheet.is_some()
                && self.parent == self.sheet.map(|i| self.s.sheets[i].node) =>
            {
                (self.sheet, self.parent) = (None, None);
                self.form = None;
                return true;
            }
            b'>' if self.form.is_some() && self.parent == self.form && self.form_depth > 0 => {
                self.end_form();
                return true;
            }
            _ => false,
        };
        // A form, a character, an anchor or a record the program ignores leaves the last kern
        // behind.
        if !handled || matches!(first, b'c' | b'!') {
            self.reset_kern();
        }
        true
    }

    fn reset_kern(&mut self) {
        (self.last_kern, self.last_glue) = (None, None);
    }

    /// Between sheets: inputs, a sheet, a form, or the Postamble.
    fn outside(&mut self, line: &[u8]) -> bool {
        (self.parent, self.child) = (None, None);
        if let Some(input) = Input::parse(line) {
            self.s.inputs.insert(input.tag, input);
        } else if let Some(page) = line.strip_prefix(b"{").and_then(|page| number(page, 0)) {
            let node = self.add(Node::new(Kind::Sheet));
            self.s.sheets.push(Sheet {
                page: page.0,
                node,
                hboxes: Vec::new(),
            });
            self.sheet = Some(self.s.sheets.len() - 1);
            self.parent = Some(node);
            self.reset_kern();
        } else if line.starts_with(b"<") {
            self.begin_form(line);
            self.reset_kern();
        } else if line.starts_with(b"Postamble:") {
            return false;
        }
        true
    }

    fn add(&mut self, node: Node) -> u32 {
        self.s.nodes.push(node);
        (self.s.nodes.len() - 1) as u32
    }

    fn page(&self) -> i32 {
        match (self.form, self.sheet) {
            (None, Some(sheet)) => self.s.sheets[sheet].page,
            _ => -1,
        }
    }

    /// As the last child of the open container.
    fn append(&mut self, mut node: Node) -> u32 {
        node.parent = self.parent;
        node.page = self.page();
        let id = self.add(node);
        match self.child {
            Some(child) => self.s.nodes[child as usize].sibling = Some(id),
            None => {
                if let Some(parent) = self.parent {
                    self.s.nodes[parent as usize].child = Some(id);
                }
            }
        }
        self.child = Some(id);
        id
    }

    fn decode(&mut self, line: &[u8], kind: Kind) -> Option<Node> {
        let mut fields = Fields {
            text: line.get(1..)?,
            at: 0,
        };
        let (tag, line, column) = (fields.int()?, fields.int()?, fields.column()?);
        let (h, v) = (fields.int()?, fields.v(&mut self.last_v)?);
        let (width, height, depth) = match kind {
            Kind::Glue | Kind::Math | Kind::Boundary => (0, 0, 0),
            Kind::Kern => (fields.int()?, 0, 0),
            _ => (fields.int()?, fields.int()?, fields.int()?),
        };
        let at = Extent {
            h,
            v,
            width,
            height,
            depth,
        };
        Some(Node {
            tag,
            line,
            column,
            at,
            seen: at,
            ..Node::new(kind)
        })
    }

    /// Lines past an input's last make the program's forward search look no further.
    fn register_line(&mut self, id: u32) {
        let node = self.s.node(id);
        let (tag, line) = (node.tag, node.line);
        if let Some(input) = self.s.inputs.get_mut(&tag) {
            input.last_line = input.last_line.max(line);
        }
    }

    fn make_friend(&mut self, id: u32) {
        let node = self.s.node(id);
        if let Some(list) = friends_of(node.tag, node.line) {
            self.s.friends[list].push(id);
        }
    }

    /// The pending boundaries take `from`'s tag, line and column, the newest first, and are
    /// listed.
    fn settle_pending(&mut self, from: u32) {
        let pending = std::mem::take(self.pending.last_mut().expect("the outermost level stays"));
        let place = self.s.node(from).place();
        for id in pending.into_iter().rev() {
            self.s.nodes[id as usize].set_place(place);
            if self.form.is_none() {
                self.make_friend(id);
            }
        }
    }

    fn begin_box(&mut self, line: &[u8], kind: Kind) -> bool {
        let Some(node) = self.decode(line, kind) else {
            return false;
        };
        let id = self.append(node);
        self.pending.push(Vec::new());
        self.parent = Some(id);
        self.child = None;
        if kind == Kind::HBox {
            let node = self.s.node(id);
            let start = self.append(Node::boundary(node.place(), node.at));
            if self.form.is_none() {
                self.make_friend(start);
            }
        }
        self.register_line(id);
        self.reset_kern();
        true
    }

    /// Closes the open box, which becomes the last child of its parent.
    fn close(&mut self) -> u32 {
        let closed = self.parent.expect("a box is open");
        self.child = Some(closed);
        self.parent = self.s.node(closed).parent;
        let pending = self.pending.pop().unwrap_or_default();
        if self.pending.is_empty() {
            self.pending.push(Vec::new());
        }
        if self.form.is_none() {
            for id in pending.into_iter().rev() {
                self.make_friend(id);
            }
        }
        self.settle_pending(closed);
        closed
    }

    fn end_vbox(&mut self) {
        let vbox = self.parent.expect("a vbox is open");
        // Only a vbox with nothing in it is listed.
        if self.s.node(vbox).child.is_none() && self.form.is_none() {
            self.make_friend(vbox);
        }
        self.close();
        self.reset_kern();
    }

    fn end_hbox(&mut self) {
        let hbox = self.parent.expect("an hbox is open");
        if self.form.is_none()
            && let Some(sheet) = self.sheet
        {
            self.s.sheets[sheet].hboxes.push(hbox);
        }
        let first = self
            .s
            .node(hbox)
            .child
            .expect("an hbox starts with its boundary");
        if let Some(next) = self.s.node(first).sibling {
            self.s.nodes[first as usize].line = self.s.node(next).line;
            let (mut weight, mut lines) = (0u32, 0u32);
            for id in std::iter::successors(Some(next), |&id| self.s.node(id).sibling) {
                let node = self.s.node(id);
                let (w, line) = match node.kind {
                    Kind::HBox => (node.weight.max(1), node.mean_line),
                    _ => (1, node.line),
                };
                weight = weight.wrapping_add(w as u32);
                lines = lines.wrapping_add(line.wrapping_mul(w) as u32);
            }
            let node = &mut self.s.nodes[hbox as usize];
            node.mean_line = (lines.wrapping_add(weight / 2) / weight.max(1)) as i32;
            node.weight = weight as i32;
        } else {
            let node = &mut self.s.nodes[hbox as usize];
            (node.mean_line, node.weight) = (node.line, 1);
        }
        // The closing boundary, at the box's end, takes the last child's lines (past form uses).
        let source = self
            .s
            .children(hbox)
            .filter(|&id| self.s.node(id).kind != Kind::Ref)
            .last()
            .expect("an hbox starts with its boundary");
        let seen = self.s.node(hbox).seen;
        let end = Extent {
            h: seen.h.wrapping_add(seen.width),
            ..seen
        };
        self.append(Node::boundary(self.s.node(source).place(), end));
        let start = &mut self.s.nodes[first as usize];
        start.at = Extent {
            h: seen.h,
            v: seen.v,
            ..Extent::default()
        };
        start.seen = start.at;
        // A kern and glue that end the box take the lines of what comes before them.
        if let (Some(kern), Some(glue)) = (self.last_kern, self.last_glue) {
            let before = self
                .s
                .children(hbox)
                .find(|&id| self.s.node(id).sibling == Some(kern));
            if let Some(before) = before {
                let place = self.s.node(before).place();
                for id in [kern, glue] {
                    self.s.nodes[id as usize].set_place(place);
                }
            }
        }
        self.close();
        let seen = self.s.node(hbox).seen;
        self.contain(Bounds::of_extent(seen));
        self.reset_kern();
    }

    fn leaf(&mut self, line: &[u8], kind: Kind) -> bool {
        let Some(node) = self.decode(line, kind) else {
            return false;
        };
        let previous = self.child.map(|child| self.s.node(child).kind);
        let id = self.append(node);
        let at = self.s.node(id).at;
        if kind == Kind::Boundary {
            let pending = self.pending.last_mut().expect("the outermost level stays");
            if previous == Some(Kind::BoxBoundary) || !pending.is_empty() {
                pending.push(id);
            } else if self.form.is_none() {
                self.make_friend(id);
            }
        } else {
            if matches!(kind, Kind::Kern | Kind::Glue | Kind::Rule | Kind::Math)
                && self.form.is_none()
            {
                self.make_friend(id);
            }
            self.settle_pending(id);
        }
        match kind {
            Kind::VoidHBox => self.contain(Bounds::of_extent(at)),
            Kind::Kern => {
                let (h, width) = (i64::from(at.h), i64::from(at.width));
                let (min_h, max_h) = if width > 0 {
                    (h - width, h)
                } else {
                    (h, h - width)
                };
                self.contain(Bounds {
                    min_h,
                    max_h,
                    ..Bounds::point(at.h, at.v)
                });
            }
            Kind::Glue | Kind::Math | Kind::Boundary => self.contain(Bounds::point(at.h, at.v)),
            _ => {}
        }
        self.register_line(id);
        match kind {
            Kind::Kern => (self.last_kern, self.last_glue) = (Some(id), None),
            Kind::Glue if self.last_kern.is_some() => self.last_glue = Some(id),
            _ => self.reset_kern(),
        }
        true
    }

    fn form_ref(&mut self, line: &[u8]) -> bool {
        let mut fields = Fields {
            text: &line[1..],
            at: 0,
        };
        let mut decode = || Some((fields.int()?, fields.int()?, fields.v(&mut self.last_v)?));
        let Some((tag, h, v)) = decode() else {
            return false;
        };
        // A form's use has no line: the program counts it as line 0 in its box's mean.
        let at = Extent {
            h,
            v,
            ..Extent::default()
        };
        self.append(Node {
            tag,
            line: 0,
            column: 0,
            at,
            seen: at,
            ..Node::new(Kind::Ref)
        });
        self.reset_kern();
        true
    }

    fn begin_form(&mut self, line: &[u8]) {
        let Some((tag, _)) = number(&line[1..], 0) else {
            return;
        };
        self.form_depth += 1;
        // A form within a form within a form is passed over whole.
        if self
            .form
            .is_some_and(|form| self.s.node(form).parent.is_some())
        {
            self.ignored_forms = 1;
            return;
        }
        let mut node = Node::new(Kind::Form);
        (node.tag, node.parent) = (tag, self.form);
        let id = self.add(node);
        (self.form, self.parent, self.child) = (Some(id), Some(id), None);
    }

    fn end_form(&mut self) {
        let form = self.form.expect("a form is open");
        self.form_depth -= 1;
        if let Some(outer) = self.s.node(form).parent {
            self.s.nodes[form as usize].parent = None;
            (self.child, self.form, self.parent) = (Some(form), Some(outer), Some(outer));
        } else if let Some(sheet) = self.sheet {
            let node = self.s.sheets[sheet].node;
            let last = self.child.map(|child| {
                std::iter::successors(Some(child), |&id| self.s.node(id).sibling)
                    .last()
                    .unwrap_or(child)
            });
            (self.form, self.parent, self.child) = (None, Some(node), last);
        } else {
            (self.form, self.parent, self.child) = (None, None, None);
        }
        self.reset_kern();
    }

    /// The open hbox grows to hold `bounds`, as what it shows can be past its size.
    fn contain(&mut self, bounds: Bounds) {
        let Some(parent) = self.parent.filter(|&p| self.s.node(p).kind == Kind::HBox) else {
            return;
        };
        let seen = &mut self.s.nodes[parent as usize].seen;
        let (h, width) = (i64::from(seen.h), i64::from(seen.width));
        if width < 0 {
            let (min, max) = (h + width, h);
            if bounds.min_h < min {
                seen.width = (bounds.min_h - max) as i32;
            } else if bounds.max_h > max {
                seen.h = bounds.max_h as i32;
                seen.width = (min - bounds.max_h) as i32;
            }
        } else {
            let (min, max) = (h, h + width);
            if bounds.min_h < min {
                seen.h = bounds.min_h as i32;
                seen.width = (max - bounds.min_h) as i32;
            } else if bounds.max_h > max {
                seen.width = (bounds.max_h - min) as i32;
            }
        }
        let n = i64::from(seen.v);
        if bounds.min_v < n - i64::from(seen.height) {
            seen.height = (n - bounds.min_v) as i32;
        } else if bounds.max_v > n + i64::from(seen.depth) {
            seen.depth = (bounds.max_v - n) as i32;
        }
    }
}

impl Node {
    /// A box's start or end: a point with a place.
    fn boundary(place: Place, at: Extent) -> Self {
        let at = Extent {
            h: at.h,
            v: at.v,
            ..Extent::default()
        };
        let mut node = Self {
            at,
            seen: at,
            ..Self::new(Kind::BoxBoundary)
        };
        node.set_place(place);
        node
    }

    fn place(&self) -> Place {
        (self.tag, self.line, self.column)
    }

    fn set_place(&mut self, (tag, line, column): Place) {
        (self.tag, self.line, self.column) = (tag, line, column);
    }

    fn new(kind: Kind) -> Self {
        Self {
            kind,
            tag: 0,
            line: 0,
            column: -1,
            page: -1,
            at: Extent::default(),
            seen: Extent::default(),
            mean_line: 0,
            weight: 0,
            parent: None,
            child: None,
            sibling: None,
        }
    }
}

/// In i64, as a damaged file's sums can pass i32's.
#[derive(Clone, Copy)]
struct Bounds {
    min_h: i64,
    max_h: i64,
    min_v: i64,
    max_v: i64,
}

impl Bounds {
    fn point(h: i32, v: i32) -> Self {
        let (h, v) = (i64::from(h), i64::from(v));
        Self {
            min_h: h,
            max_h: h,
            min_v: v,
            max_v: v,
        }
    }

    fn of_extent(e: Extent) -> Self {
        let (h, width, v) = (i64::from(e.h), i64::from(e.width), i64::from(e.v));
        let (min_h, max_h) = if width < 0 {
            (h + width, h)
        } else {
            (h, h + width)
        };
        Self {
            min_h,
            max_h,
            min_v: v - i64::from(e.height),
            max_v: v + i64::from(e.depth),
        }
    }
}

// MARK: - Searching

/// A node and how far it is, as synctex's `synctex_nd_s`.
#[derive(Clone, Copy)]
struct Near {
    node: Option<u32>,
    distance: i64,
}

const NOWHERE: Near = Near {
    node: None,
    distance: FAR,
};

/// In scaled points.
#[derive(Clone, Copy)]
struct Point {
    h: i64,
    v: i64,
}

/// The program's steps from a line with nothing on the page: +1, -2, +3, -4…
fn next_step(step: i32) -> i32 {
    if step < 0 { -(step - 1) } else { -(step + 1) }
}

impl SyncTex {
    /// The boxes that show `line` of the input `tag`, else the nearest line that shows, in the
    /// program's order (synctex's `synctex_iterator_new_display`, no page hint).
    pub fn forward(&self, tag: i32, line: i32) -> Vec<Shown> {
        let Some(last) = self.inputs.get(&tag).map(|input| input.last_line) else {
            return Vec::new();
        };
        let (mut line, mut step) = (line.min(last), 1);
        for _ in 0..100 {
            if line > last {
                break;
            }
            let list = friends_of(tag, line)
                .map(|i| &self.friends[i])
                .filter(|list| !list.is_empty());
            if let Some(groups) = list.and_then(|list| {
                self.on_line(list, tag, line, true)
                    .or_else(|| self.on_line(list, tag, line, false))
            }) {
                return self
                    .ordered(groups)
                    .into_iter()
                    .map(|id| self.shown(id))
                    .collect();
            }
            line = line.saturating_add(step);
            step = next_step(step);
            if line <= 0 {
                line = line.saturating_add(step);
                step = next_step(step);
            }
        }
        Vec::new()
    }

    /// The listed nodes with this tag and line, a group per page, as synctex's
    /// `_synctex_display_query_v2` links them; boxes left out first.
    fn on_line(&self, list: &[u32], tag: i32, line: i32, no_boxes: bool) -> Option<Vec<Vec<u32>>> {
        let mut found = list.iter().rev().copied().filter(|&id| {
            let node = self.node(id);
            node.tag == tag && node.line == line && !(no_boxes && node.kind.is_box())
        });
        let first = found.next()?;
        let mut groups = vec![vec![first]];
        while let Some(id) = found.next() {
            if self.node(id).page == self.node(first).page {
                groups[0].insert(0, id);
                continue;
            }
            groups.push(vec![id]);
            for id in found.by_ref() {
                let page = self.node(id).page;
                match groups
                    .iter_mut()
                    .find(|group| self.node(group[0]).page == page)
                {
                    Some(group) => group.insert(1, id),
                    None => groups.insert(0, vec![id]),
                }
            }
        }
        Some(groups)
    }

    /// The groups, each sorted, the one on the lowest page first and the rest after it in reverse.
    fn ordered(&self, groups: Vec<Vec<u32>>) -> Vec<u32> {
        let page = |chain: &[u32]| self.node(chain[0]).page.unsigned_abs();
        let mut groups = groups.into_iter();
        let first = groups.next().expect("a match makes a group");
        let mut best = page(&first);
        let mut chains = vec![self.weighed(first)];
        for group in groups {
            let chain = self.weighed(group);
            if page(&chain) < best {
                best = page(&chain);
                chains.insert(0, chain);
            } else {
                chains.insert(1, chain);
            }
        }
        chains.concat()
    }

    /// A page's matches by how many of their box's nodes share their line, one per box (synctex's
    /// `_synctex_vertically_sorted_v2`).
    fn weighed(&self, group: Vec<u32>) -> Vec<u32> {
        let (tag, line) = (self.node(group[0]).tag, self.node(group[0]).line);
        // Only an hbox keeps the weight it is given, so a second match in one is left out.
        let mut weighed_hboxes = std::collections::HashSet::new();
        let mut chain: Vec<(u32, usize)> = Vec::new();
        for id in group {
            let parent = self.node(id).parent;
            let weight = match parent {
                Some(parent) if !weighed_hboxes.contains(&parent) => {
                    if self.node(parent).kind == Kind::HBox {
                        weighed_hboxes.insert(parent);
                    }
                    self.children(parent)
                        .filter(|&c| self.node(c).tag == tag && self.node(c).line == line)
                        .count()
                }
                _ => 0,
            };
            if chain.is_empty() || weight > chain[0].1 {
                chain.insert(0, (id, weight));
            } else if weight > 0 {
                let mut at = 0;
                while at + 1 < chain.len() {
                    at += 1;
                    if weight >= chain[at].1 {
                        break;
                    }
                }
                chain.insert(at + 1, (id, weight));
            }
        }
        chain.into_iter().map(|(id, _)| id).collect()
    }

    /// In the program's words, the visible box of `id`: its own or its parent, grown to the
    /// highest hbox round it on the same line, unless one is wider or taller than 1,500,000 sp.
    fn shown(&self, id: u32) -> Shown {
        let mut node = id;
        if !self.node(node).kind.is_box() {
            node = self.node(node).parent.unwrap_or(node);
        }
        let bound = (1_500_000.0 / (f64::from(self.magnification) / 1000.0)) as i32;
        let mean = self.mean_line(node);
        let mut up = node;
        while let Some(parent) = self.node(up).parent {
            up = parent;
            let at = self.node(parent).at;
            if self.node(parent).kind.is_hbox() {
                if mean.abs_diff(self.mean_line(parent)) > 1 {
                    break;
                }
                if at.width > bound || at.height.saturating_add(at.depth) > bound {
                    node = parent;
                    break;
                }
                node = parent;
            }
        }
        let seen = self.node(node).seen;
        Shown {
            page: self.node(id).page,
            h: self.visible_h(seen.h),
            v: self.visible_v(seen.v) + self.visible_size(seen.depth),
            width: self.visible_size(seen.width),
            height: self.visible_size(seen.height) + self.visible_size(seen.depth),
        }
    }

    fn mean_line(&self, id: u32) -> i32 {
        let node = self.node(id);
        match node.parent {
            _ if node.kind == Kind::HBox => node.mean_line,
            Some(parent) if self.node(parent).kind == Kind::HBox => self.node(parent).mean_line,
            _ => node.line,
        }
    }

    /// The input's name and line under the point, in PDF points from the page's top left
    /// (synctex's `synctex_iterator_new_edit`, its first result).
    pub fn inverse(&self, page: i32, h: f32, v: f32) -> Option<(&str, i32)> {
        let sheet = self.sheets.iter().find(|sheet| sheet.page == page)?;
        let hit = Point {
            h: i64::from(((h - self.x_offset) / self.unit) as i32),
            v: i64::from(((v - self.y_offset) / self.unit) as i32),
        };
        let mut hboxes = sheet.hboxes.iter().rev().copied();
        let ((mut left, right), container) =
            match hboxes.by_ref().find(|&id| self.contains(hit, id)) {
                Some(first) => {
                    // Where hboxes overlap, the smallest.
                    let mut node = first;
                    for other in hboxes.filter(|&other| self.contains(hit, other)) {
                        node = self.smallest(other, node);
                    }
                    let node = self.deepest(hit, node)?;
                    (self.closest_children(hit, node), node)
                }
                None => {
                    let top = self.node(sheet.node).child?;
                    ((self.closest_deep_child(hit, top), NOWHERE), top)
                }
            };
        match (left.node, right.node) {
            (Some(l), Some(r)) => {
                let (ln, rn) = (self.node(l), self.node(r));
                if ln.place() != rn.place() {
                    // Of two lines, the first, or of one, the nearer.
                    if rn.line < ln.line || (rn.line == ln.line && left.distance > right.distance) {
                        left.node = Some(r);
                    }
                } else if left.distance > right.distance {
                    left.node = Some(r);
                }
            }
            (None, Some(_)) => left = right,
            (None, None) => left.node = Some(container),
            (Some(_), None) => {}
        }
        let node = self.node(left.node?);
        let input = self.inputs.get(&node.tag)?;
        Some((&input.name, node.line))
    }

    fn contains(&self, hit: Point, id: u32) -> bool {
        self.h_ordered(hit, id) == 0 && self.v_ordered(hit, id) == 0
    }

    /// Of two hboxes, the one of least area, else widest as TeX made it, else least tall.
    fn smallest(&self, node: u32, other: u32) -> u32 {
        let measure = |id: u32| {
            let seen = self.node(id).seen;
            let height =
                u64::from(seen.depth.unsigned_abs()) + u64::from(seen.height.unsigned_abs());
            (
                height * u64::from(seen.width.unsigned_abs()),
                self.node(id).at.width.unsigned_abs(),
                height,
            )
        };
        let ((area, width, height), (other_area, other_width, other_height)) =
            (measure(node), measure(other));
        if area != other_area {
            return if area < other_area { node } else { other };
        }
        if width != other_width {
            return if width > other_width { node } else { other };
        }
        if height > other_height { other } else { node }
    }

    /// How far right of the point the node is: positive to its right, negative to its left.
    fn h_ordered(&self, hit: Point, id: u32) -> i64 {
        let node = self.node(id);
        let outside = |min: i64, max: i64| {
            if hit.h < min {
                min - hit.h
            } else if hit.h > max {
                max - hit.h
            } else {
                0
            }
        };
        match node.kind {
            Kind::VBox | Kind::VoidVBox | Kind::VoidHBox => {
                let min = i64::from(node.at.h);
                outside(min, min + i64::from(node.at.width).abs())
            }
            Kind::HBox => {
                let min = i64::from(node.seen.h);
                outside(min, min + i64::from(node.seen.width).abs())
            }
            // Its place is recorded after the move, and it holds no text: the nearer edge counts,
            // with a point's penalty.
            Kind::Kern => {
                let (h, width) = (i64::from(node.at.h), i64::from(node.at.width));
                let (min, max) = if width < 0 {
                    (h, h - width)
                } else {
                    (h - width, h)
                };
                let middle = (min + max) / 2;
                if hit.h < min {
                    min - hit.h + 1
                } else if hit.h > max {
                    max - hit.h - 1
                } else if hit.h > middle {
                    max - hit.h + 1
                } else {
                    min - hit.h - 1
                }
            }
            Kind::Rule | Kind::Glue | Kind::Math | Kind::Boundary | Kind::BoxBoundary => {
                i64::from(node.at.h) - hit.h
            }
            _ => FAR,
        }
    }

    /// How far below the point the node is: positive below, negative above.
    fn v_ordered(&self, hit: Point, id: u32) -> i64 {
        let node = self.node(id);
        let (v, height, depth) = match node.kind {
            Kind::VBox | Kind::VoidVBox | Kind::VoidHBox => {
                (node.at.v, node.at.height, node.at.depth)
            }
            Kind::HBox => (node.seen.v, node.seen.height, node.seen.depth),
            Kind::Rule | Kind::Kern | Kind::Glue | Kind::Math => {
                let parent = node.parent.map(|p| self.node(p).at).unwrap_or_default();
                (node.at.v, parent.height, parent.depth)
            }
            _ => return FAR,
        };
        let v = i64::from(v);
        let (min, max) = (v - i64::from(height).abs(), v + i64::from(depth).abs());
        if hit.v < min {
            min - hit.v
        } else if hit.v > max {
            max - hit.v
        } else {
            0
        }
    }

    /// synctex's distance from a point to a node: 0 inside, else nearly the L1 distance.
    fn distance(&self, hit: Point, id: u32) -> i64 {
        let node = self.node(id);
        let at = node.at;
        let parent_height = || i64::from(node.parent.map_or(0, |p| self.node(p).at.height)).abs();
        let (h, v) = (i64::from(at.h), i64::from(at.v));
        let to_box = |min_h: i64, max_h: i64, min_v: i64, max_v: i64| {
            let across = if hit.h < min_h {
                min_h - hit.h
            } else if hit.h > max_h {
                hit.h - max_h
            } else {
                0
            };
            let down = if hit.v < min_v {
                min_v - hit.v
            } else if hit.v > max_v {
                hit.v - max_v
            } else {
                0
            };
            across + down
        };
        match node.kind {
            Kind::VBox => to_box(
                h,
                h + i64::from(at.width).abs(),
                v - i64::from(at.height).abs(),
                v + i64::from(at.depth).abs(),
            ),
            Kind::HBox => {
                let seen = node.seen;
                let (h, v) = (i64::from(seen.h), i64::from(seen.v));
                to_box(
                    h,
                    h + i64::from(seen.width).abs(),
                    v - i64::from(seen.height).abs(),
                    v + i64::from(seen.depth).abs(),
                )
            }
            // The nearer of its two edges.
            Kind::VoidVBox | Kind::VoidHBox => {
                let (top, bottom) = (
                    v - i64::from(at.height).abs(),
                    v + i64::from(at.depth).abs(),
                );
                let right = h + i64::from(at.width).abs();
                to_box(h, h, top, bottom).min(to_box(right, right, top, bottom))
            }
            Kind::Kern => {
                let other = h - i64::from(at.width);
                to_box(h, h, v - parent_height(), v).min(to_box(
                    other,
                    other,
                    v - parent_height(),
                    v,
                ))
            }
            Kind::Glue | Kind::Math | Kind::Boundary | Kind::BoxBoundary => {
                to_box(h, h, v - parent_height(), v)
            }
            _ => FAR,
        }
    }

    /// The deepest box with children that holds the point, else a vbox's nearest such child
    /// (synctex's `_synctex_eq_deepest_container_v2`).
    fn deepest(&self, hit: Point, id: u32) -> Option<u32> {
        self.node(id).child?;
        for child in self.children(id) {
            if let Some(deep) = self
                .contains(hit, child)
                .then(|| self.deepest(hit, child))
                .flatten()
            {
                return Some(deep);
            }
        }
        if self.node(id).kind == Kind::VBox {
            let mut best = NOWHERE;
            for child in self.children(id).filter(|&c| self.node(c).child.is_some()) {
                let distance = self.distance(hit, child);
                if distance <= best.distance {
                    best = Near {
                        node: Some(child),
                        distance,
                    };
                }
            }
            if best.node.is_some() {
                return best.node;
            }
        }
        self.contains(hit, id).then_some(id)
    }

    /// As `deepest`, but going into every child first (synctex's `_v3`).
    fn deepest_anywhere(&self, hit: Point, id: u32) -> Near {
        if self.node(id).child.is_none() {
            return NOWHERE;
        }
        if let Some(deep) = self
            .children(id)
            .map(|child| self.deepest_anywhere(hit, child))
            .find(|deep| deep.node.is_some())
        {
            return deep;
        }
        if self.node(id).kind == Kind::VBox {
            let mut best = NOWHERE;
            for child in self.children(id).filter(|&c| self.node(c).child.is_some()) {
                let distance = self.distance(hit, child);
                if distance < best.distance {
                    best = Near {
                        node: Some(child),
                        distance,
                    };
                }
            }
            if best.node.is_some() {
                return best;
            }
        }
        if self.contains(hit, id) {
            Near {
                node: Some(id),
                distance: 0,
            }
        } else {
            NOWHERE
        }
    }

    /// The nearest node to the point among the descendants that aren't boxes; at an equal
    /// distance the later, unless it is a kern.
    fn closest_deep_child(&self, hit: Point, id: u32) -> Near {
        let mut best = NOWHERE;
        for child in self.children(id) {
            let near = if self.node(child).kind.is_box() {
                self.closest_deep_child(hit, child)
            } else {
                Near {
                    node: Some(child),
                    distance: self.distance(hit, child),
                }
            };
            let kern = near.node.is_some_and(|n| self.node(n).kind == Kind::Kern);
            if near.distance < best.distance || (near.distance == best.distance && !kern) {
                best = near;
            }
        }
        best
    }

    /// The nodes of an hbox nearest the point on its left and on its right, each narrowed to
    /// what is deepest within it (synctex's `__synctex_eq_get_closest_children_in_hbox_v2`). The
    /// program's search in a vbox starts from no node and finds none, which this keeps.
    fn closest_children(&self, hit: Point, id: u32) -> (Near, Near) {
        if self.node(id).kind != Kind::HBox || self.node(id).child.is_none() {
            return (NOWHERE, NOWHERE);
        }
        let (mut left, mut right) = (NOWHERE, NOWHERE);
        // At an equal distance, the earlier place in the same input.
        let earlier = |node: u32, than: u32| {
            let (n, t) = (self.node(node), self.node(than));
            t.tag == n.tag && (t.line > n.line || (t.line == n.line && t.column > n.column))
        };
        for child in self.children(id) {
            let distance = self.h_ordered(hit, child);
            if distance == 0 {
                if self.node(child).child.is_some() {
                    return self.closest_children(hit, child);
                }
                left = Near {
                    node: Some(child),
                    distance: 0,
                };
                continue;
            }
            let side = if distance > 0 { &mut right } else { &mut left };
            let distance = distance.abs();
            if side.distance > distance
                || (side.distance == distance && side.node.is_some_and(|than| earlier(child, than)))
            {
                *side = Near {
                    node: Some(child),
                    distance,
                };
            }
        }
        for side in [&mut left, &mut right] {
            if let Some(node) = side.node {
                let deep = self.deepest_anywhere(hit, node);
                if deep.node.is_some() {
                    *side = deep;
                }
                if let Some(child) = self.closest_deep_child(hit, side.node.unwrap_or(node)).node {
                    side.node = Some(child);
                }
            }
        }
        (left, right)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    /// fixtures/main.tex built by pdflatex with `-synctex=1`, and TeX Live's synctex program's
    /// answers for it (answers.txt): every line of each input forward, and points across its
    /// pages back.
    #[test]
    fn answers_as_tex_lives_synctex_program() {
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/synctex/fixtures");
        let sync = super::SyncTex::read(&fixtures.join("main.synctex.gz")).unwrap();
        let answers = std::fs::read_to_string(fixtures.join("answers.txt")).unwrap();
        let numbers = |text: &str| -> Vec<f32> {
            text.split_whitespace()
                .map(|n| n.parse().unwrap())
                .collect()
        };
        for answer in answers.lines().filter(|line| !line.starts_with('#')) {
            let (query, theirs) = answer.split_once(" | ").unwrap_or((answer, ""));
            let query: Vec<&str> = query.split_whitespace().collect();
            match query[..] {
                ["view", file, line] => {
                    let input = format!("/./{file}");
                    let tag = sync.inputs().find(|(_, name)| name.ends_with(&input));
                    let ours = tag.map_or_else(Vec::new, |(tag, _)| {
                        sync.forward(tag, line.parse().unwrap())
                    });
                    let theirs: Vec<Vec<f32>> = theirs.split(" | ").map(numbers).collect();
                    let theirs = theirs.iter().filter(|shown| !shown.is_empty());
                    assert_eq!(ours.len(), theirs.clone().count(), "{answer}");
                    for (ours, theirs) in ours.iter().zip(theirs) {
                        let ours = [ours.page as f32, ours.h, ours.v, ours.width, ours.height];
                        let near = ours.iter().zip(theirs).all(|(a, b)| (a - b).abs() < 1e-3);
                        assert!(near, "{answer}: {ours:?}");
                    }
                }
                ["edit", page, x, y] => {
                    let ours = sync.inverse(
                        page.parse().unwrap(),
                        x.parse().unwrap(),
                        y.parse().unwrap(),
                    );
                    let ours = ours.map(|(name, line)| format!("{name} {line}"));
                    assert_eq!(ours.as_deref().unwrap_or(""), theirs, "{answer}");
                }
                _ => panic!("{answer}"),
            }
        }
    }
}
