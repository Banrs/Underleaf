//! Baseline for tools/synctex-experiment; emits exact-line navigation and timings.
use std::path::PathBuf;
use std::time::Instant;

use texlocal_latex::synctex::SyncTex;
use texlocal_latex::syntax::SyncLines;

fn main() {
    let args: Vec<_> = std::env::args().collect();
    let pdf = PathBuf::from(&args[1]);
    let plain = pdf.with_extension("synctex");
    let file = if plain.is_file() {
        plain
    } else {
        pdf.with_extension("synctex.gz")
    };
    let started = Instant::now();
    let sync = SyncTex::read(std::fs::read(file).unwrap()).unwrap();
    let parsed = started.elapsed().as_secs_f64();
    for (tag, name) in sync.inputs() {
        println!("I\t{tag}\t{name}");
    }
    let tag = sync.inputs().find(|(_, name)| *name == args[2]).unwrap().0;
    let lines: u32 = args[3].parse().unwrap();
    let at = |line| SyncLines::Within {
        line,
        range: line..=line,
    };
    let started = Instant::now();
    let mut found = 0;
    for _ in 0..20 {
        for line in 1..=lines {
            if !sync.forward(tag, &at(line)).is_empty() {
                found += 1;
            }
        }
    }
    let per_line = started.elapsed().as_secs_f64() / f64::from(20 * lines);
    println!("T\t{parsed:.9}\t{per_line:.9}\t{}", found / 20);
    for line in 1..=lines {
        let hits = sync.forward(tag, &at(line));
        let Some(hit) = hits.first() else {
            println!("F\t{line}\t0");
            continue;
        };
        let (name, back) = sync
            .inverse(hit.page, hit.h + 5.0, hit.v - hit.height / 2.0)
            .unwrap_or(("", 0));
        println!(
            "F\t{line}\t{}\t{:.6}\t{:.6}\t{:.6}\t{:.6}\t{name}\t{back}",
            hit.page, hit.h, hit.v, hit.width, hit.height
        );
    }
}
