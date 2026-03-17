use std::fmt::Display;

use cliclack::{intro as cliclak_intro, log, outro as cliclak_outro, Theme, ThemeState};
use console::{style, Emoji, Style, Term};

const S_BAR: Emoji = Emoji("│", "|");
pub struct CliclackTheme;

impl Theme for CliclackTheme {
    fn bar_color(&self, state: &ThemeState) -> Style {
        match state {
            ThemeState::Active => Style::new().cyan(),
            ThemeState::Error(_) => Style::new().yellow(),
            _ => Style::new().cyan().dim(),
        }
    }
}

pub fn init_theme() {
    cliclack::set_theme(CliclackTheme);
}

fn term_write(msg: impl Display) {
    let msg = &format!("{}", msg);
    Term::stderr().write_str(msg).unwrap();
}

pub fn intro() {
    cliclak_intro(style(" Protocol CLI ").on_cyan().black()).unwrap();
}

pub fn outro(msg: impl Display) {
    cliclak_outro(msg).unwrap();
}

pub fn info(msg: impl Display) {
    log::info(msg).unwrap();
}

pub fn debug(msg: impl Display) {
    let msg = &format!("{}", msg);
    let log = CliclackTheme.format_log(msg, style("⚙").dim().to_string().as_str());
    Term::stderr().write_str(&log).unwrap();
}

pub fn warn(msg: impl Display) {
    log::warning(msg).unwrap();
}

pub fn error(msg: impl Display) {
    log::error(style(msg).red()).unwrap();
}

pub fn step(msg: impl Display) {
    log::step(msg).unwrap();
}

pub fn error_note(msg: &str, content: &str) {
    let note = CliclackTheme.format_log(msg, &CliclackTheme.error_symbol());
    term_write(note);
    let note = CliclackTheme.format_log(content, &CliclackTheme.error_symbol());
    term_write(note);
}

pub fn new_empty_line() {
    term_write("\n");
}

pub fn new_line() {
    term_write(format!(
        "{}\n",
        CliclackTheme.bar_color(&ThemeState::Submit).apply_to(S_BAR)
    ))
}
