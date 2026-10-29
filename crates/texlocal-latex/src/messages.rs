crate::messages! {
    invalid_arguments(error) = "Invalid arguments: {error}";
    unknown_command = "Unknown command";
    tex(text) = "{text}";

    package_not_installed = "This package or class isn't installed in your TeX distribution. Install it, then compile again.";
    file_not_found = "TeX can't find this file. Check its name and folder, written from the main file's folder, and that the file is in the project.";
    undefined_command = "TeX doesn't know this command. Check its spelling, or load the package that defines it in the preamble.";
    undefined_environment = "LaTeX doesn't know this environment. Check its spelling, or load the package that defines it in the preamble.";
    missing_dollar = "Something only maths may hold, such as ^, _ or a Greek letter, is outside maths, or a blank line breaks an equation. Put it between $ signs, or remove the blank line.";
    extra_brace = "A closing brace has no opening one to match, or maths was left open before it. Look for a }} too many, or a $ missing, on this line or just before it.";
    missing_brace = "A group was still open where TeX needed it closed: a {{ without its }}, or maths left open. Look for the brace or $ missing on this line or just before it.";
    runaway_argument = "A command's argument runs on into a blank line or the end of the file, usually because its closing brace is missing. Close the brace where the argument should end.";
    misplaced_ampersand = r"An & is outside a table or aligned equation, where it only separates columns. Write \& for an ampersand in text.";
    extra_ampersand = "A row has more & than its table has columns. Add a column to the table's definition, or remove an & from the row.";
    mismatched_end = r"An environment is closed by another's \end, or one inside it was left open. Make each \end name its \begin's environment, closing the inner ones first.";
    before_document = r"Something that typesets comes before \begin{{document}}, where only the preamble's settings may go. Move it below \begin{{document}}, or look for a stray character in the preamble.";
    preamble_only = r"This command only works before \begin{{document}}. Move it to the preamble.";
    no_line_to_end = r"A \\ or \newline comes where no line has begun, such as at a paragraph's start or after a heading. Remove it, or use \vspace for space between paragraphs.";
    option_clash = r"The package is loaded twice with different options, perhaps once by the class or another package. Load it once with all its options, or give them earlier with \PassOptionsToPackage.";
    emergency_stop = r"TeX stopped here and couldn't go on, often because the file ends before \end{{document}} or an earlier error left it nothing to read. Fix the first error above this one, and check that the main file ends with \end{{document}}.";
    undefined_citation = r"No bibliography entry or \bibitem has this key. Check its spelling against the .bib file's, and that the document names that file with \bibliography or \addbibresource.";
    unicode_character = "pdfLaTeX's fonts have no letter for this character. XeLaTeX typesets it with a font that has one; or write it as a LaTeX command.";
    needs_xelatex = "This package needs XeLaTeX or LuaLaTeX, and the project compiles with pdfLaTeX. Compile it with XeLaTeX.";
    command_defined = r"\newcommand names a command that exists already, perhaps one a package defines. Choose another name, or use \renewcommand to replace it.";
    needs_shell_escape = "A package here runs programs as it builds, which needs Shell Escape. Turn on Shell Escape in the project's settings if you trust the project.";

    install_title = "Install";
    install_help(file) = "Installs the TeX Live package that has {file}, then compiles again.";
    add_package_title(package) = r"Add \usepackage{{{package}}}";
    add_package_help(package) = "Loads {package} in the main file's preamble, then compiles again.";
    xelatex_title = "Use XeLaTeX";
    xelatex_help = "Compiles the project with XeLaTeX from now on, which takes any Unicode character and the computer's own fonts.";
    shell_escape_title = "Turn On Shell Escape";
    shell_escape_help = "Lets the project's packages run programs as it compiles, then compiles again.";
    shell_escape_confirm = "Shell Escape lets this document run programs on your computer as it compiles. Turn it on only for documents you trust.";

    end_without_begin(environment) = r"\end{{{environment}}} has no \begin{{{environment}}}.";
    ended_by_another(open, line, environment) = r"\begin{{{open}}} on line {line} is ended by \end{{{environment}}}.";
    nothing_to_close = "This }} has nothing to close.";
    open_at_paragraph_end(delimiter) = "This {delimiter} is still open where the paragraph ends.";
    never_closed = "This {{ is never closed.";
    never_ended(environment) = r"\begin{{{environment}}} is never ended.";
    label_defined_twice(name, line, file) = "The label “{name}” is defined already, on line {line} of {file}.";
    citation_defined_twice(name, line, file) = "The citation “{name}” is defined already, on line {line} of {file}.";
    no_label(name) = "No label “{name}” is defined.";
    no_citation(name) = "No citation “{name}” is defined.";
    no_file(name) = "No file “{name}” is in the project.";
}
