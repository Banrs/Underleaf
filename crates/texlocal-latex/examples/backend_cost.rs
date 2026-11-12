use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::{Duration, Instant};

use serde_json::json;
use texlocal_latex::facts::Facts;
use texlocal_latex::project::{self, Scan};
use texlocal_latex::search::Query;
use texlocal_latex::syntax::{Source, SourceDocument};
use texlocal_latex::{FileKind, file_kind};

struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static ALLOCS: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size(), Relaxed);
        ALLOCS.fetch_add(1, Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_sub(layout.size(), Relaxed);
        LIVE.fetch_add(new_size, Relaxed);
        ALLOCS.fetch_add(1, Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static COUNTING: Counting = Counting;

fn timed<T>(name: &str, runs: u32, mut work: impl FnMut() -> T) -> T {
    let mut out = work();
    let (allocs, started) = (ALLOCS.load(Relaxed), Instant::now());
    for _ in 0..runs {
        out = std::hint::black_box(work());
    }
    let each: Duration = started.elapsed() / runs;
    let allocs = (ALLOCS.load(Relaxed) - allocs) / runs as usize;
    println!("{name:<44} {each:>12.2?}  {allocs:>8} allocs");
    out
}

/// What the costs of the paths a session takes most often are, on the book `tools/perf-book.py` writes:
/// `cargo run --release -p texlocal-latex --example backend_cost -- <folder>`.
fn main() {
    let root = PathBuf::from(std::env::args_os().nth(1).expect("the book's folder"));
    let mut texts = BTreeMap::new();
    let mut names = vec!["main.tex".to_owned(), "refs.bib".to_owned()];
    names.extend((0..40).map(|c| format!("chapters/ch{c:02}.tex")));
    for name in &names {
        texts.insert(
            name.clone(),
            std::fs::read_to_string(root.join(name)).unwrap(),
        );
    }
    let chapter = &texts["chapters/ch07.tex"];
    let whole: String = texts.values().map(String::as_str).collect();
    println!(
        "chapter {} KB, whole {} KB",
        chapter.len() >> 10,
        whole.len() >> 10
    );

    timed("Facts::read, one chapter", 200, || {
        Facts::read(chapter, FileKind::Tex)
    });
    let before = LIVE.load(Relaxed);
    let facts: BTreeMap<String, Arc<Facts>> = timed("Facts::read, every file", 5, || {
        let read = |(name, text): (&String, &String)| {
            (name.clone(), Arc::new(Facts::read(text, file_kind(name))))
        };
        texts.iter().map(read).collect()
    });
    println!(
        "  every file's facts keep {} KB",
        (LIVE.load(Relaxed) - before) >> 10
    );
    let scan = Scan::new(facts, names.clone(), Arc::default());
    timed("project::check", 50, || project::check(&scan, "main.tex"));
    timed("project::analyze", 50, || {
        project::analyze(&scan, Some("main.tex"), None)
    });
    let analysis = project::analyze(&scan, Some("main.tex"), None);
    timed("  its JSON", 50, || {
        serde_json::to_string(&analysis).unwrap()
    });

    let query = Query::new("lorem", false, false);
    timed("Query::places, every file", 20, || {
        texts
            .values()
            .map(|text| query.places(text).len())
            .sum::<usize>()
    });

    let mut doc = SourceDocument::named(chapter, "chapters/ch07.tex");
    doc.set_symbols(Arc::clone(&scan.symbols));
    let middle = (chapter.len() / 2) as u32;
    timed("edit: type and delete a letter", 2000, || {
        doc.apply_edit(middle, 0, "x", None, false);
        doc.apply_edit(middle, 1, "", None, false);
    });
    timed("highlights, 4000 units after an edit", 2000, || {
        doc.apply_edit(middle, 0, "x", None, false);
        doc.apply_edit(middle, 1, "", None, false);
        doc.highlights(middle, 4000).len()
    });
    let call = |doc: &mut SourceDocument, name: &str, args: serde_json::Value| {
        let args: serde_json::Value = serde_json::from_str(&args.to_string()).unwrap();
        let answer = Source::call(doc, name, args).unwrap();
        // As the C ABI answers: the value written once, not copied into another first.
        format!(r#"{{"type":"ok","value":{answer}}}"#)
    };
    let selection = json!({ "start": middle, "length": 0 });
    for (name, args) in [
        (
            "TypeText",
            json!({ "selection": selection, "text": "x", "autoPair": true }),
        ),
        ("StylesAt", json!({ "selection": selection })),
        ("MathAt", json!({ "caret": middle })),
        ("Folds", json!({})),
        (
            "Words",
            json!({ "selection": { "start": 0, "length": chapter.len() } }),
        ),
        ("SymbolAt", json!({ "at": middle })),
    ] {
        timed(&format!("call {name}"), 500, || {
            call(&mut doc, name, args.clone()).len()
        });
    }
    let mut typed = SourceDocument::named("\\", "main.tex");
    typed.set_symbols(Arc::clone(&scan.symbols));
    let every = json!({ "caret": 1, "explicit": true });
    let bytes = timed("call Complete, every command", 200, || {
        call(&mut typed, "Complete", every.clone()).len()
    });
    println!("  its reply is {} KB", bytes >> 10);
    let mut cited = SourceDocument::named("\\cite{", "main.tex");
    cited.set_symbols(Arc::clone(&scan.symbols));
    let keys = json!({ "caret": 6, "explicit": false });
    let bytes = timed("call Complete, 200 citations", 200, || {
        call(&mut cited, "Complete", keys.clone()).len()
    });
    println!("  its reply is {} KB", bytes >> 10);

    let mut book = SourceDocument::named(&whole, "book.tex");
    let end = whole.encode_utf16().count() as u32 - 10;
    timed("whole book: edit near the end", 500, || {
        book.apply_edit(end, 0, "x", None, false);
        book.apply_edit(end, 1, "", None, false);
    });
    timed("whole book: StylesAt near the end", 200, || {
        book.apply_edit(end, 0, "x", None, false);
        book.apply_edit(end, 1, "", None, false);
        call(
            &mut book,
            "StylesAt",
            json!({ "selection": { "start": end, "length": 0 } }),
        )
        .len()
    });
    timed("whole book: text()", 50, || book.text().len());
}
