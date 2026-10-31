use std::path::Path;
use std::process::ExitCode;

fn main() -> std::io::Result<ExitCode> {
    if std::env::args().nth(1).as_deref() != Some("--write") {
        eprintln!("usage: cargo run -p texlocal-wire -- --write");
        return Ok(ExitCode::from(2));
    }
    for (path, text) in texlocal_wire::stale() {
        std::fs::write(Path::new(texlocal_wire::ROOT).join(path), text)?;
        println!("wrote {path}");
    }
    Ok(ExitCode::SUCCESS)
}
