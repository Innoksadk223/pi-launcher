use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::store;

#[derive(Debug, Clone, Serialize)]
pub struct TerminalKind {
    pub id: &'static str,
    pub name: &'static str,
    pub note: &'static str,
    pub supported: bool,
}

const WT: TerminalKind = TerminalKind {
    id: "wt",
    name: "Windows Terminal",
    note: "",
    supported: true,
};

pub fn known() -> &'static [TerminalKind] {
    &[WT]
}

pub fn kind(id: &str) -> Option<&'static TerminalKind> {
    known().iter().find(|k| k.id == id)
}

/// 解析可用的 `wt.exe` 路径：先扫 PATH，再查 `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe`
pub fn find_wt_exe() -> Option<PathBuf> {
    find_in_path("wt.exe").or_else(|| {
        dirs::data_local_dir()
            .map(|d| d.join("Microsoft").join("WindowsApps").join("wt.exe"))
            .filter(|p| p.is_file())
    })
}

pub fn is_installed_with<F>(id: &str, mut probe: F) -> bool
where
    F: FnMut(&str) -> bool,
{
    probe(id)
}

pub fn is_installed(k: &TerminalKind) -> bool {
    match k.id {
        "wt" => find_wt_exe().is_some(),
        _ => false,
    }
}

pub fn installed_with<F>(mut probe: F) -> Vec<&'static TerminalKind>
where
    F: FnMut(&TerminalKind) -> bool,
{
    known().iter().filter(|k| probe(k)).collect()
}

pub fn installed() -> Vec<&'static TerminalKind> {
    installed_with(is_installed)
}

pub fn resolve<'a>(
    selected: Option<&str>,
    available: &[&'a TerminalKind],
) -> (Option<&'a TerminalKind>, bool) {
    if let Some(sel) = selected {
        if let Some(&m) = available.iter().find(|k| k.id == sel && k.supported) {
            return (Some(m), false);
        }
    }
    if let Some(&m) = available.iter().find(|k| k.supported) {
        return (Some(m), selected.is_some());
    }
    (None, selected.is_some())
}

pub fn preference_path() -> PathBuf {
    store::default_data_dir().join("terminal.txt")
}

pub fn saved_selection_from(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub fn saved_selection() -> Option<String> {
    saved_selection_from(&preference_path())
}

pub fn save_selection_to(id: &str, path: &Path) -> bool {
    store::atomic_write(path, &format!("{id}\n"))
}

pub fn save_selection(id: &str) -> bool {
    save_selection_to(id, &preference_path())
}

fn find_in_path(exe_name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(exe_name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_registry_resolve_and_preference() {
        let only_wt = installed_with(|k| k.id == "wt");
        assert_eq!(only_wt.len(), 1);
        assert_eq!(only_wt[0].id, "wt");

        let (k1, fell1) = resolve(None, &only_wt);
        assert_eq!(k1.map(|k| k.id), Some("wt"));
        assert!(!fell1);

        let (k2, fell2) = resolve(Some("ghostty"), &only_wt);
        assert_eq!(k2.map(|k| k.id), Some("wt"));
        assert!(fell2);

        let (k3, fell3) = resolve(Some("wt"), &[]);
        assert!(k3.is_none());
        assert!(fell3);

        let root = std::env::temp_dir().join(format!("pi-launcher-term-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let pref = root.join("nested").join("terminal.txt");
        assert!(save_selection_to("wt", &pref));
        assert_eq!(saved_selection_from(&pref).as_deref(), Some("wt"));
        assert_eq!(saved_selection_from(&root.join("missing.txt")), None);
        std::fs::write(&pref, "\n  \n").unwrap();
        assert_eq!(saved_selection_from(&pref), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
