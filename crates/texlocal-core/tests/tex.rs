mod common;

use std::path::Path;

use common::Rig;
use serde_json::json;

const ARTICLE: &str = "\\documentclass{article}\n\\begin{document}\n\\section{Intro}\\label{sec:intro}\nA first paragraph of words.\n\nSee section~\\ref{sec:intro} and \\cite{knuth}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n";
const REFS: &str = "@book{knuth, author = {Donald Knuth}, title = {The TeXbook}, year = {1984}, publisher = {Addison-Wesley}}\n";

async fn built(files: &[(&str, &str)]) -> (Rig, serde_json::Value) {
    let rig = Rig::open(files).await;
    rig.call("Compile", json!({ "auto": false }));
    let finished = rig.event("buildFinished", |_| true);
    (rig, finished["result"].clone())
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn latexmk_builds_a_pdf_with_its_bibliography() {
    let (rig, result) = built(&[("main.tex", ARTICLE), ("refs.bib", REFS)]).await;
    assert_eq!(result["ok"], true, "{}", result["log"]);
    assert_eq!(result["errors"], json!([]));
    assert_eq!(
        result["warnings"],
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
    let (rig, result) = built(&[("main.tex", ARTICLE), ("refs.bib", REFS)]).await;
    assert_eq!(result["ok"], true);
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
    let (_rig, result) = built(&[("main.tex", main)]).await;
    assert_eq!(result["ok"], false);
    assert!(
        result["pdf"].is_string(),
        "a build doesn't stop at the first error"
    );
    let error = &result["errors"][0];
    assert_eq!(
        (error["file"].clone(), error["line"].clone()),
        (json!("main.tex"), json!(4))
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs TeX"]
async fn a_glossary_is_built_with_makeglossaries() {
    let main = "\\documentclass{article}\n\\usepackage{glossaries}\n\\makeglossaries\n\\newglossaryentry{tex}{name={TeX},description={a typesetting system}}\n\\begin{document}\n\\gls{tex} is used here.\n\\printglossaries\n\\end{document}\n";
    let (rig, result) = built(&[("main.tex", main)]).await;
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
    let typed = rig.find(|e| {
        matches!(
            e["event"]["type"].as_str(),
            Some("livePage" | "liveDocument")
        )
    });
    assert!(Path::new(typed["event"]["value"]["path"].as_str().unwrap()).is_file());
    rig.call("StopLive", json!({}));
    rig.event("live", |e| e["state"]["phase"] == "stopped");
}
