use std::alloc::{GlobalAlloc, Layout, System};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::Instant;

use texlocal_latex::synctex::SyncTex;
use texlocal_latex::syntax::sync_lines;

struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let live = LIVE.fetch_add(layout.size(), Relaxed) + layout.size();
        PEAK.fetch_max(live, Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static COUNTING: Counting = Counting;

const MB: f64 = 1024.0 * 1024.0;

#[test]
#[ignore = "needs the 400-page fixture in ~/TeXLocal, built"]
fn the_long_fixtures_synctex_cost() {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap());
    let project = home.join("TeXLocal/Test Long (400 pages)");
    let bytes = std::fs::read(project.join("build/main.synctex.gz")).unwrap();
    let (before, started) = (LIVE.load(Relaxed), Instant::now());
    PEAK.store(before, Relaxed);
    let sync = SyncTex::read(bytes).unwrap();
    let parsed = started.elapsed();
    let (kept, peak) = (LIVE.load(Relaxed) - before, PEAK.load(Relaxed) - before);
    let text = std::fs::read_to_string(project.join("main.tex")).unwrap();
    let main = sync.inputs().find(|(_, name)| name.ends_with("main.tex"));
    let tag = main.unwrap().0;
    let lines = text.lines().count() as u32;
    let started = Instant::now();
    let found = (1..=lines).filter(|&line| !sync.forward(tag, &sync_lines(&text, line)).is_empty());
    let found = found.count();
    let per_line = started.elapsed() / lines;
    println!(
        "parse {parsed:?}, kept {:.1} MB, peak {:.1} MB; sync_lines and forward {per_line:?} a line, {found} of {lines} lines found",
        kept as f64 / MB,
        peak as f64 / MB,
    );
    assert!(found > 0);
}
