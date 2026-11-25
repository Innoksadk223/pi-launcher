use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

pub const MAX_RECENT: usize = 15;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreData {
    pub favorites: Vec<String>,
    pub recents: Vec<String>,
}

/// 默认数据目录：%APPDATA%\PI Launcher
pub fn default_data_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("PI Launcher")
}

/// 默认数据文件：%APPDATA%\PI Launcher\projects.txt
pub fn default_file_path() -> PathBuf {
    default_data_dir().join("projects.txt")
}

pub fn is_directory(path: &str) -> bool {
    Path::new(path).is_dir()
}

/// 接受 Windows 盘符路径（`C:\...`、`C:/...`）、UNC 路径（`\\server\share`）以及 POSIX 路径（测试用）。
pub fn is_absolute_project_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    if bytes.is_empty() {
        return false;
    }
    if bytes[0] == b'/' {
        return true;
    }
    if bytes.len() >= 2 && bytes[0] == b'\\' && bytes[1] == b'\\' {
        return true;
    }
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
}

/// 把文本解析成 favorites / recents。`exists` 决定某个路径是否被接受。
pub fn parse_with<F>(text: &str, mut exists: F) -> StoreData
where
    F: FnMut(&str) -> bool,
{
    let mut favorites: Vec<String> = Vec::new();
    let mut recents: Vec<String> = Vec::new();
    let mut seen_fav: HashSet<String> = HashSet::new();
    let mut seen_rec: HashSet<String> = HashSet::new();

    for raw_line in text.split('\n') {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if line.is_empty() {
            continue;
        }
        let Some((kind, path)) = line.split_once('\t') else {
            continue;
        };
        if !is_absolute_project_path(path) || !exists(path) {
            continue;
        }
        match kind {
            "F" => {
                if seen_fav.insert(path.to_string()) {
                    favorites.push(path.to_string());
                }
            }
            "R" => {
                if seen_rec.insert(path.to_string()) {
                    recents.push(path.to_string());
                }
            }
            _ => {}
        }
    }

    StoreData { favorites, recents }
}

pub fn parse(text: &str) -> StoreData {
    parse_with(text, is_directory)
}

/// 序列化为文件内容（末尾带 `\n`；空列表得到空文本）
pub fn serialize(favorites: &[String], recents: &[String]) -> String {
    let mut lines = Vec::with_capacity(favorites.len() + recents.len());
    for p in favorites {
        lines.push(format!("F\t{p}"));
    }
    for p in recents {
        lines.push(format!("R\t{p}"));
    }
    if lines.is_empty() {
        String::new()
    } else {
        lines.join("\n") + "\n"
    }
}

/// 最近列表：新项置顶、去重、按上限截断
pub fn push_recent(path: &str, recents: &[String], limit: usize) -> Vec<String> {
    if limit == 0 {
        return Vec::new();
    }
    let mut updated = Vec::with_capacity(limit.min(recents.len() + 1));
    updated.push(path.to_string());
    for item in recents {
        if updated.len() >= limit {
            break;
        }
        if item != path {
            updated.push(item.clone());
        }
    }
    updated
}

pub fn load_from(file_path: &Path) -> StoreData {
    let Ok(text) = fs::read_to_string(file_path) else {
        return StoreData {
            favorites: Vec::new(),
            recents: Vec::new(),
        };
    };
    if text.is_empty() {
        return StoreData {
            favorites: Vec::new(),
            recents: Vec::new(),
        };
    }
    parse(&text)
}

pub fn load() -> StoreData {
    load_from(&default_file_path())
}

/// 原子写盘：先写同目录临时文件、落盘，再替换目标文件（不留 `.tmp` 残留）。
pub fn atomic_write(file_path: &Path, body: &str) -> bool {
    let Some(dir) = file_path.parent() else {
        return false;
    };
    if fs::create_dir_all(dir).is_err() {
        return false;
    }
    let Some(name) = file_path.file_name().and_then(|s| s.to_str()) else {
        return false;
    };
    let tmp = dir.join(format!("{name}.tmp"));
    let write_res = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        use std::io::Write;
        f.write_all(body.as_bytes())?;
        f.sync_all()?;
        Ok(())
    })();
    if write_res.is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    if replace_file(&tmp, file_path).is_err() {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    true
}

#[cfg(windows)]
fn replace_file(tmp: &Path, dst: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let mut src_w: Vec<u16> = tmp.as_os_str().encode_wide().collect();
    src_w.push(0);
    let mut dst_w: Vec<u16> = dst.as_os_str().encode_wide().collect();
    dst_w.push(0);
    let ok = unsafe {
        MoveFileExW(
            src_w.as_ptr(),
            dst_w.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok != 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(windows))]
fn replace_file(tmp: &Path, dst: &Path) -> std::io::Result<()> {
    fs::rename(tmp, dst)
}

pub fn save_to(favorites: &[String], recents: &[String], file_path: &Path) -> bool {
    let body = serialize(favorites, recents);
    atomic_write(file_path, &body)
}

pub fn save(favorites: &[String], recents: &[String]) -> bool {
    save_to(favorites, recents, &default_file_path())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToggleResult {
    pub favorites: Vec<String>,
    pub recents: Vec<String>,
    pub made_favorite: bool,
}

/// 切换常用。取消常用时降级到「最近」，不能从列表消失。
pub fn toggling_favorite(path: &str, favorites: &[String], recents: &[String]) -> ToggleResult {
    let mut new_favorites = favorites.to_vec();
    let mut new_recents = recents.to_vec();
    let was_favorite = favorites.iter().any(|p| p == path);
    if was_favorite {
        new_favorites.retain(|p| p != path);
        if !new_recents.iter().any(|p| p == path) {
            new_recents = push_recent(path, &new_recents, MAX_RECENT);
        }
    } else {
        new_favorites.push(path.to_string());
    }
    ToggleResult {
        favorites: new_favorites,
        recents: new_recents,
        made_favorite: !was_favorite,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddFavoriteResult {
    pub favorites: Vec<String>,
    pub recents: Vec<String>,
    pub added: bool,
}

pub fn adding_favorite(path: &str, favorites: &[String], recents: &[String]) -> AddFavoriteResult {
    if favorites.iter().any(|p| p == path) {
        return AddFavoriteResult {
            favorites: favorites.to_vec(),
            recents: recents.to_vec(),
            added: false,
        };
    }
    let mut new_favorites = favorites.to_vec();
    new_favorites.push(path.to_string());
    AddFavoriteResult {
        favorites: new_favorites,
        recents: recents.to_vec(),
        added: true,
    }
}

pub fn removing_recent(path: &str, favorites: &[String], recents: &[String]) -> StoreData {
    StoreData {
        favorites: favorites.to_vec(),
        recents: recents.iter().filter(|p| p.as_str() != path).cloned().collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "pi-launcher-store-{}-{}",
            tag,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        base
    }

    #[test]
    fn windows_drive_and_unc_paths_accepted() {
        assert!(is_absolute_project_path(r"C:\Users\dev\proj"));
        assert!(is_absolute_project_path("d:/work/proj"));
        assert!(is_absolute_project_path(r"\\server\share\proj"));
        assert!(is_absolute_project_path("/tmp/proj"));
        assert!(!is_absolute_project_path("relative/path"));
        assert!(!is_absolute_project_path("C:relative"));

        let raw = "F\tC:\\Users\\demo\\项目 A\r\nR\t\\\\nas\\code\\proj\r\nF\trelative\\bad\r\n";
        let parsed = parse_with(raw, |_| true);
        assert_eq!(parsed.favorites, vec![r"C:\Users\demo\项目 A"]);
        assert_eq!(parsed.recents, vec![r"\\nas\code\proj"]);
    }

    #[test]
    fn round_trip_messy_and_empty() {
        let root = temp_root("rt");
        let dir_a = root.join("项目 A");
        let dir_b = root.join("proj'b");
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();
        let path_a = dir_a.to_string_lossy().into_owned();
        let path_b = dir_b.to_string_lossy().into_owned();
        let missing = root.join("不存在").to_string_lossy().into_owned();

        let text = serialize(&[path_a.clone(), path_b.clone()], &[path_b.clone()]);
        assert!(text.ends_with('\n') && text.contains("F\t"));
        let parsed = parse(&text);
        assert_eq!(parsed.favorites, vec![path_a.clone(), path_b.clone()]);
        assert_eq!(parsed.recents, vec![path_b.clone()]);

        let messy = format!("F\t{path_a}\ngarbage\nX\t{path_a}\nF\t{missing}\nR\t{path_b}\nF\t{path_a}\n");
        let messy_parsed = parse(&messy);
        assert_eq!(messy_parsed.favorites, vec![path_a.clone()]);
        assert_eq!(messy_parsed.recents, vec![path_b.clone()]);

        let empty = parse("");
        assert!(empty.favorites.is_empty() && empty.recents.is_empty());
        assert!(serialize(&[], &[]).is_empty());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn push_recent_and_file_atomic_overwrite() {
        assert_eq!(
            push_recent("/b", &["/a".into(), "/b".into(), "/c".into()], MAX_RECENT),
            vec!["/b", "/a", "/c"]
        );
        assert_eq!(
            push_recent("/d", &["/a".into(), "/b".into(), "/c".into()], 3),
            vec!["/d", "/a", "/b"]
        );
        assert_eq!(push_recent("/x", &[], MAX_RECENT), vec!["/x"]);

        let root = temp_root("file");
        let dir_a = root.join("项目 A");
        let dir_b = root.join("proj'b");
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();
        let path_a = dir_a.to_string_lossy().into_owned();
        let path_b = dir_b.to_string_lossy().into_owned();

        let store_file = root.join("fresh run").join("deep").join("projects.txt");
        assert!(save_to(&[path_a.clone()], &[path_b.clone()], &store_file));
        let reloaded = load_from(&store_file);
        assert_eq!(reloaded.favorites, vec![path_a.clone()]);
        assert_eq!(reloaded.recents, vec![path_b.clone()]);
        assert!(!root.join("fresh run").join("deep").join("projects.txt.tmp").exists());

        // 覆盖保存
        assert!(save_to(&[path_b.clone()], &[], &store_file));
        let overwritten = load_from(&store_file);
        assert_eq!(overwritten.favorites, vec![path_b]);
        assert!(overwritten.recents.is_empty());

        // 不存在与空文件
        let absent = load_from(&root.join("nope/projects.txt"));
        assert!(absent.favorites.is_empty() && absent.recents.is_empty());
        let empty_file = root.join("empty/projects.txt");
        fs::create_dir_all(empty_file.parent().unwrap()).unwrap();
        fs::write(&empty_file, "").unwrap();
        let from_empty = load_from(&empty_file);
        assert!(from_empty.favorites.is_empty() && from_empty.recents.is_empty());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn favorite_and_remove_transitions() {
        let p = r"C:\work\proj";
        let a = toggling_favorite(p, &[p.into()], &[]);
        assert!(a.favorites.is_empty() && a.recents == vec![p] && !a.made_favorite);

        let b = toggling_favorite(p, &[p.into()], &[p.into()]);
        assert_eq!(b.recents, vec![p]);

        let c = toggling_favorite(p, &[], &[p.into()]);
        assert_eq!(c.favorites, vec![p]);
        assert!(c.made_favorite);

        let add1 = adding_favorite(p, &[], &[]);
        assert!(add1.added && add1.favorites == vec![p] && add1.recents.is_empty());
        let add2 = adding_favorite(p, &[p.into()], &[r"C:\b".into()]);
        assert!(!add2.added && add2.favorites == vec![p] && add2.recents == vec![r"C:\b"]);

        let rem = removing_recent("/b", &["/a".into()], &["/a".into(), "/b".into(), "/c".into()]);
        assert_eq!(rem.recents, vec!["/a", "/c"]);
        assert_eq!(rem.favorites, vec!["/a"]);
    }
}
