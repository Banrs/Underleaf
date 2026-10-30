mod common;

use std::path::Path;
use std::process::Command;

use common::Rig;
use serde_json::json;

const ARTICLE: &str = "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\\label{sec:intro}\nA first paragraph of words.\n\nSee section~\\ref{sec:intro} and \\cite{knuth}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n";
const REFS: &str = "@book{knuth, author = {Donald Knuth}, title = {The TeXbook}, year = {1984}, publisher = {Addison-Wesley}}\n";

async fn built(files: &[(&str, &str)]) -> (Rig, serde_json::Value) {
    let rig = Rig::open(files).await;
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
    let build = rig.section("build", |b| !b["result"].is_null());
    (rig, build)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn latexmk_builds_a_pdf_with_its_bibliography() {
    let (rig, build) = built(&[("main.tex", ARTICLE), ("refs.bib", REFS)]).await;
    let result = &build["result"];
    assert_eq!(result["ok"], true, "{}", result["log"]);
    assert_eq!(
        build["issues"],
        json!([]),
        "the reference and citation resolve"
    );
    let pdf = result["pdf"].as_str().unwrap();
    assert!(Path::new(pdf).is_file());
    assert!(rig.root().join("build/main.synctex.gz").is_file());
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn synctex_goes_from_a_line_to_the_pdf_and_back() {
    let (rig, build) = built(&[("main.tex", ARTICLE), ("refs.bib", REFS)]).await;
    assert_eq!(build["result"]["ok"], true);
    let forward = rig.call("SynctexForward", json!({ "file": "main.tex", "line": 4 }));
    assert_eq!(forward["page"].as_f64(), Some(1.0));
    let (h, v) = (
        forward["h"].as_f64().unwrap(),
        forward["v"].as_f64().unwrap(),
    );
    let height = forward["height"].as_f64().unwrap_or(0.0);
    let at = json!({ "page": 1, "x": h + 5.0, "y": v - height / 2.0 });
    let back = rig.call("SynctexInverse", at);
    assert_eq!(back["file"], "main.tex");
    assert_eq!(back["line"], 4);
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn a_tex_error_is_on_its_line_and_the_pdf_still_comes() {
    let main = "\\documentclass{article}\n\\begin{document}\nBefore.\n\\undefinedcommand\nAfter.\n\\end{document}\n";
    let (_rig, build) = built(&[("main.tex", main)]).await;
    assert_eq!(build["result"]["ok"], false);
    assert!(
        build["result"]["pdf"].is_string(),
        "a build doesn't stop at the first error"
    );
    let error = &build["issues"][0];
    assert_eq!(
        (error["file"].clone(), error["line"].clone()),
        (json!("main.tex"), json!(4))
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn a_glossary_is_built_with_makeglossaries() {
    let main = "\\documentclass{article}\n\\usepackage{glossaries}\n\\makeglossaries\n\\newglossaryentry{tex}{name={TeX},description={a typesetting system}}\n\\begin{document}\n\\gls{tex} is used here.\n\\printglossaries\n\\end{document}\n";
    let (rig, build) = built(&[("main.tex", main)]).await;
    let result = &build["result"];
    assert_eq!(result["ok"], true, "{}", result["log"]);
    assert!(rig.root().join("build/main.gls").is_file());
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX and TeXpresso"]
async fn live_preview_writes_pages_as_the_text_changes() {
    let main =
        "\\documentclass{article}\n\\begin{document}\nHello live preview.\n\\end{document}\n";
    let rig = Rig::open(&[("main.tex", main)]).await;
    let doc = rig.open_document("main.tex");
    rig.call("StartLive", json!({}));
    rig.call("LiveView", json!({ "first": 0, "last": 0 }));
    let whole = rig.event("liveDocument", |e| e["complete"] == true);
    assert!(Path::new(whole["path"].as_str().unwrap()).is_file());
    rig.forget();
    doc.edit(40, 0, "More words. ", None, false);
    let page = rig.event("livePage", |p| p["page"] == 0);
    assert!(page["pdf"].as_str().unwrap().starts_with("JVBER"), "a PDF");
    rig.call("StopLive", json!({}));
    rig.section("live", |l| l["phase"] == "stopped");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX and TeXpresso"]
async fn forward_sync_follows_the_live_documents_synctex() {
    let main = "\\documentclass{article}\n\\begin{document}\nFirst page.\n\\end{document}\n";
    let rig = Rig::open(&[("main.tex", main)]).await;
    let doc = rig.open_document("main.tex");
    rig.call("StartLive", json!({}));
    rig.call("LiveView", json!({ "first": 0, "last": 0 }));
    rig.event("liveDocument", |e| e["complete"] == true);
    let page = |line: u32| {
        let at = json!({ "file": "main.tex", "line": line });
        rig.call("SynctexForward", at)["page"].as_f64()
    };
    assert_eq!(page(3), Some(1.0));
    let end = main.find("\\end").unwrap() as u32;
    doc.edit(end, 0, "\\newpage\nSecond page.\n", None, false);
    rig.event("liveDocument", |e| {
        let second = |r: &serde_json::Value| r["last"].as_u64() >= Some(1);
        e["complete"] == true && e["changed"].as_array().unwrap().iter().any(second)
    });
    assert_eq!(page(5), Some(2.0));
    rig.call("StopLive", json!({}));
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX and TeXpresso"]
async fn a_main_file_in_a_folder_inputs_from_the_root_in_compile_and_live() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\input{part}\n\\end{document}\n";
    let part = "A part at the root.\n";
    let rig = Rig::open(&[("sub/main.tex", main), ("part.tex", part)]).await;
    let main_file = json!({ "patch": { "mainFile": "sub/main.tex" } });
    rig.call("SetSettings", main_file);
    rig.call("Compile", json!({ "auto": false }));
    rig.event("buildFinished", |_| true);
    let build = rig.section("build", |b| !b["result"].is_null());
    assert_eq!(build["result"]["ok"], true, "{}", build["result"]["log"]);
    assert_eq!(build["issues"], json!([]));
    rig.open_document("part.tex");
    rig.call("StartLive", json!({}));
    rig.call("LiveView", json!({ "first": 0, "last": 0 }));
    rig.event("liveDocument", |e| e["complete"] == true);
    let at = json!({ "file": "part.tex", "line": 1 });
    assert_eq!(rig.call("SynctexForward", at)["page"].as_f64(), Some(1.0));
    rig.call("LiveLog", json!({ "shown": true }));
    let live = rig.section("live", |l| l["log"].is_string());
    let log = live["log"].as_str().unwrap();
    assert!(!log.lines().any(|line| line.starts_with("! ")), "{log}");
    assert_eq!(live["failures"], json!([]));
    rig.call("StopLive", json!({}));
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX and TeXpresso"]
async fn a_live_edit_to_an_input_after_a_compile_typesets_and_places_its_error() {
    let main = "\\documentclass{article}\n\\begin{document}\n\\input{part}\n\\end{document}\n";
    let part = "A part.\n";
    let (rig, build) = built(&[("main.tex", main), ("part.tex", part)]).await;
    assert_eq!(build["result"]["ok"], true, "{}", build["result"]["log"]);
    let doc = rig.open_document("part.tex");
    rig.call("StartLive", json!({}));
    rig.call("LiveView", json!({ "first": 0, "last": 0 }));
    rig.event("liveDocument", |e| e["complete"] == true);
    doc.edit(part.len() as u32, 0, "\\undefinedcommand\n", None, false);
    let live = rig.section("live", |l| !l["lines"]["part.tex"].is_null());
    assert_eq!(live["lines"]["part.tex"][0]["line"], 2);
    rig.call("StopLive", json!({}));
}

fn first_page(pdf: &str) -> String {
    let text = Command::new("mutool")
        .args(["draw", "-F", "txt", "-o", "-", pdf, "1"])
        .output()
        .unwrap()
        .stdout;
    let words = String::from_utf8_lossy(&text);
    words.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX, TeXpresso and mutool"]
async fn the_live_contents_read_as_the_compiled_ones() {
    let main = "\\documentclass{article}\n\\usepackage{hyperref}\n\\begin{document}\n\\tableofcontents\n\\section{Section 1}\nText.\n\\end{document}\n";
    let (rig, build) = built(&[("main.tex", main)]).await;
    let compiled = first_page(build["result"]["pdf"].as_str().unwrap());
    assert!(compiled.contains("Contents 1 Section 1 1"), "{compiled}");
    rig.open_document("main.tex");
    rig.call("StartLive", json!({}));
    rig.call("LiveView", json!({ "first": 0, "last": 0 }));
    rig.event("liveDocument", |e| {
        e["complete"] == true && first_page(e["path"].as_str().unwrap()) == compiled
    });
    rig.call("LiveLog", json!({ "shown": true }));
    let log = rig.section("live", |l| l["log"].is_string())["log"].take();
    let log = log.as_str().unwrap();
    assert!(!log.lines().any(|line| line.starts_with("! ")), "{log}");
    rig.call("StopLive", json!({}));
}
