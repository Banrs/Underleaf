use std::path::Path;
use std::process::ExitCode;

fn main() -> std::io::Result<ExitCode> {
    let write = match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [flag] if flag == "--write" => true,
        [flag] if flag == "--check" => false,
        _ => {
            eprintln!("usage: cargo run -p texlocal-wire -- --write | --check");
            return Ok(ExitCode::from(2));
        }
    };
    let stale = texlocal_wire::stale();
    for (path, text) in &stale {
        if write {
            std::fs::write(Path::new(texlocal_wire::ROOT).join(path), text)?;
            println!("wrote {path}");
        } else {
            eprintln!("{path} is stale: run cargo run -p texlocal-wire -- --write");
        }
    }
    Ok(if write || stale.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}
