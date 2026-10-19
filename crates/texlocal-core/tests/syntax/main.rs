//! The editing logic (`texlocal_core::syntax`) through what it makes public,
//! in one test binary, as each file under tests/ links the whole core.

use texlocal_core::syntax::TextRange;

mod answers;
mod editing;
mod typing;

fn range(start: u32, length: u32) -> TextRange {
    TextRange { start, length }
}

fn units(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}
