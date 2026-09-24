//! `texlocal-server [--port N] [--web-dir PATH]` — serve TeXLocal to a browser
//! on this machine only.

use std::path::PathBuf;
use std::sync::Arc;

use texlocal_core::service::Service;
use texlocal_server::{http, new_token, App, MAX_BODY};

const DEFAULT_PORT: u16 = 7878;

fn usage() -> ! {
    eprintln!("usage: texlocal-server [--port N] [--web-dir PATH]");
    std::process::exit(2);
}

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let mut port = DEFAULT_PORT;
    let mut web_dir = PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../web"));
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                port = args
                    .next()
                    .and_then(|p| p.parse().ok())
                    .unwrap_or_else(|| usage())
            }
            "--web-dir" => web_dir = args.next().map(PathBuf::from).unwrap_or_else(|| usage()),
            _ => usage(),
        }
    }
    let web_dir = std::path::absolute(web_dir)?;
    if !web_dir.join("dist/bundle.js").is_file() {
        eprintln!(
            "No web build in {} — run `npm run build` first.",
            web_dir.display()
        );
        std::process::exit(1);
    }

    let data_dir = texlocal_core::default_data_dir();
    std::fs::create_dir_all(&data_dir)?;

    // Loopback only, never a wildcard address: see the crate docs.
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
    let port = listener.local_addr()?.port();
    let token = new_token();
    let app = Arc::new(App::new(
        Service::new(data_dir.clone()),
        web_dir,
        port,
        token.clone(),
    ));

    println!("TeXLocal is serving {}", data_dir.display());
    println!("Open http://127.0.0.1:{port}/?token={token}");

    let handler = {
        let app = app.clone();
        Arc::new(move |req| {
            let app = app.clone();
            async move { app.handle(req).await }
        })
    };
    http::serve(listener, handler, MAX_BODY, async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await;
    // Compiles run in their own process groups, so nothing else stops them.
    app.service.compile.kill_all();
    Ok(())
}
