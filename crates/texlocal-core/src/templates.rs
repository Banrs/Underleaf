//! Built-in project templates. Each maps relative file path → content.

const BIB: &str = include_str!("../templates/references.bib");

/// The files for a template; an unknown name falls back to `article`.
pub(crate) fn files(template: &str) -> &'static [(&'static str, &'static str)] {
    match template {
        "blank" => &[("main.tex", include_str!("../templates/blank.tex"))],
        "report" => {
            &[("main.tex", include_str!("../templates/report.tex")), ("references.bib", BIB)]
        }
        "beamer" => &[("main.tex", include_str!("../templates/beamer.tex"))],
        _ => &[("main.tex", include_str!("../templates/article.tex")), ("references.bib", BIB)],
    }
}

#[cfg(test)]
mod tests {
    use super::files;

    #[test]
    fn every_template_is_plain_file_names_led_by_main_tex() {
        // create_project writes these straight into the new folder, without
        // the path checks user input goes through.
        for name in ["blank", "article", "report", "beamer", "unknown"] {
            let template = files(name);
            assert_eq!(template[0].0, "main.tex", "{name}");
            for (file, text) in template {
                assert!(!file.contains('/') && !file.starts_with('.'), "{name}: {file}");
                // A checkout's line ends don't reach a new project.
                assert!(!text.contains('\r'), "{name}: {file}");
            }
        }
        assert_eq!(files("unknown"), files("article"));
    }
}
