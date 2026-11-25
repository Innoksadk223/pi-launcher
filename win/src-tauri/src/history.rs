use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use memchr::memchr;
use serde::Serialize;
use serde_json::Value;

pub const MAX_ITEMS: usize = 10;
const MAX_LINE_BYTES: usize = 256 * 1024;
const MAX_SCAN_LINES: usize = 128;
const TAIL_BYTES: u64 = 64 * 1024;
const MAX_CANDIDATES: usize = 40;
const TAIL_SESSION_INFO_LINES: usize = 4;

const MAX_CACHED_ENTRIES: usize = 256;
const MAX_CACHED_ENTRIES_PER_DIR: usize = 64;
const MAX_CACHED_DIRECTORIES: usize = 64;
const MAX_CACHED_SUMMARIES: usize = 128;

#[derive(Debug, Clone, Serialize)]
pub struct SessionItem {
    pub path: String,
    pub title: String,
    #[serde(rename = "modified")]
    pub modified_ms: f64,
    #[serde(rename = "messageCount")]
    pub message_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Summary {
    pub count: usize,
    pub last_ms: Option<f64>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Statistics {
    pub directory_listings: usize,
    pub attribute_reads: usize,
    pub stability_attribute_reads: usize,
    pub head_scans: usize,
    pub activity_reads: usize,
    pub message_count_reads: usize,
    pub metadata_hits: usize,
    pub metadata_misses: usize,
    pub count_hits: usize,
    pub summary_hits: usize,
    pub cache_stores: usize,
    pub cached_entries: usize,
    pub cached_directories: usize,
    pub cached_summaries: usize,
    pub largest_directory_entry_count: usize,
}

/// 默认 agent 目录：优先读 `PI_CODING_AGENT_DIR`，否则 `%USERPROFILE%\.pi\agent`
pub fn default_agent_dir() -> PathBuf {
    if let Ok(raw) = std::env::var("PI_CODING_AGENT_DIR") {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return expand_tilde(trimmed);
        }
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".pi")
        .join("agent")
}

fn expand_tilde(raw: &str) -> PathBuf {
    if raw == "~" {
        return dirs::home_dir().unwrap_or_else(|| PathBuf::from(raw));
    }
    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(raw)
}

/// PI 的 `getDefaultSessionDirPath` 规则：
/// `--` + 去掉首个 `/` 或 `\`，再把 `/` `\` `:` 换成 `-` + `--`
pub fn encode_cwd(path: &str) -> String {
    let mut chars = path.chars();
    let stripped = match chars.next() {
        Some('/') | Some('\\') => chars.as_str(),
        _ => path,
    };
    let mut out = String::with_capacity(stripped.len() + 4);
    out.push_str("--");
    for ch in stripped.chars() {
        match ch {
            '/' | '\\' | ':' => out.push('-'),
            c => out.push(c),
        }
    }
    out.push_str("--");
    out
}

/// 词法标准化，不解析符号链接；Windows 下把 `/` 统一成 `\` 并保留盘符写法
pub fn standardize_path(path: &str) -> String {
    let normalized_slashes = if cfg!(windows) || looks_windows_path(path) {
        path.replace('/', "\\")
    } else {
        path.to_string()
    };

    // 如果是 Windows 路径字符串（包括测试时在非 Windows 上传入的盘符路径），按词法整理 . / ..
    if looks_windows_path(&normalized_slashes) {
        return normalize_windows_lexical(&normalized_slashes);
    }

    let p = Path::new(&normalized_slashes);
    let mut stack: Vec<String> = Vec::new();
    let is_abs = normalized_slashes.starts_with('/');
    for comp in p.components() {
        match comp {
            Component::RootDir => {}
            Component::CurDir => {}
            Component::ParentDir => {
                if !stack.is_empty() && (!is_abs || !stack.is_empty()) {
                    stack.pop();
                }
            }
            Component::Normal(s) => stack.push(s.to_string_lossy().into_owned()),
            Component::Prefix(pre) => stack.push(pre.as_os_str().to_string_lossy().into_owned()),
        }
    }
    if is_abs {
        if stack.is_empty() {
            "/".to_string()
        } else {
            format!("/{}", stack.join("/"))
        }
    } else if stack.is_empty() {
        ".".to_string()
    } else {
        stack.join("/")
    }
}

fn looks_windows_path(path: &str) -> bool {
    let b = path.as_bytes();
    (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
        || (b.len() >= 2 && (b[0] == b'\\' || b[0] == b'/') && (b[1] == b'\\' || b[1] == b'/'))
}

fn normalize_windows_lexical(raw: &str) -> String {
    let s = raw.replace('/', "\\");
    let (prefix, rest) = if s.starts_with("\\\\") {
        let trimmed = s.trim_start_matches('\\');
        let mut parts = trimmed.splitn(3, '\\');
        let srv = parts.next().unwrap_or("");
        let share = parts.next().unwrap_or("");
        let tail = parts.next().unwrap_or("");
        (format!("\\\\{srv}\\{share}"), tail)
    } else if s.len() >= 2 && s.as_bytes()[0].is_ascii_alphabetic() && s.as_bytes()[1] == b':' {
        let drive = &s[..2];
        let tail = s[2..].trim_start_matches('\\');
        (format!("{drive}\\"), tail)
    } else {
        (String::new(), s.as_str())
    };

    let mut stack: Vec<&str> = Vec::new();
    for seg in rest.split('\\') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            stack.pop();
        } else {
            stack.push(seg);
        }
    }
    if prefix.is_empty() {
        stack.join("\\")
    } else if prefix.ends_with('\\') {
        format!("{prefix}{}", stack.join("\\"))
    } else if stack.is_empty() {
        prefix
    } else {
        format!("{prefix}\\{}", stack.join("\\"))
    }
}

/// 剥掉结尾多余的分隔符（保留 `C:\` 和 `/`）
pub fn path_key(path: &str) -> String {
    let mut s = standardize_path(path);
    if looks_windows_path(&s) {
        while s.len() > 3 && s.ends_with('\\') {
            s.pop();
        }
        s.to_ascii_lowercase()
    } else {
        while s.len() > 1 && s.ends_with('/') {
            s.pop();
        }
        s
    }
}

fn resolve_symlinks_path(path: &str) -> String {
    let Ok(canon) = fs::canonicalize(path) else {
        return path.to_string();
    };
    let s = canon.to_string_lossy().into_owned();
    #[cfg(windows)]
    if let Some(stripped) = s.strip_prefix("\\\\?\\UNC\\") {
        return format!("\\\\{stripped}");
    } else if let Some(stripped) = s.strip_prefix("\\\\?\\") {
        return stripped.to_string();
    }
    s
}

/// 目录编码候选列表：先词法路径，再翻转盘符大小写（C:\ ↔ c:\），再符号链接目标
pub fn candidate_directories(project: &str, agent_dir: &Path) -> Vec<PathBuf> {
    let std_form = standardize_path(project);
    let mut forms: Vec<String> = Vec::new();
    let mut push_unique = |f: String| {
        if !forms.contains(&f) {
            forms.push(f);
        }
    };

    push_unique(std_form.clone());
    if let Some(flipped) = flip_drive_case(&std_form) {
        push_unique(flipped);
    }

    let resolved = resolve_symlinks_path(&std_form);
    push_unique(resolved.clone());
    if let Some(flipped) = flip_drive_case(&resolved) {
        push_unique(flipped);
    }

    let sessions_root = agent_dir.join("sessions");
    let mut dirs: Vec<PathBuf> = Vec::with_capacity(forms.len());
    for form in forms {
        let encoded = encode_cwd(&form);
        let dir = sessions_root.join(encoded);
        if !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    dirs
}

fn flip_drive_case(path: &str) -> Option<String> {
    let b = path.as_bytes();
    if b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':' {
        let toggled = if b[0].is_ascii_uppercase() {
            (b[0] as char).to_ascii_lowercase()
        } else {
            (b[0] as char).to_ascii_uppercase()
        };
        let mut out = String::with_capacity(path.len());
        out.push(toggled);
        out.push_str(&path[1..]);
        Some(out)
    } else {
        None
    }
}

pub fn directory_for(project: &str, agent_dir: &Path) -> PathBuf {
    let candidates = candidate_directories(project, agent_dir);
    candidates
        .iter()
        .find(|p| p.exists())
        .cloned()
        .unwrap_or_else(|| candidates.into_iter().next().unwrap())
}

fn same_project(stored: &str, project: &str) -> bool {
    let a_key = path_key(stored);
    let b_key = path_key(project);
    if a_key == b_key {
        return true;
    }
    let a_res = path_key(&resolve_symlinks_path(&standardize_path(stored)));
    let b_res = path_key(&resolve_symlinks_path(&standardize_path(project)));
    a_res == b_res
}

// ── 文件属性与缓存 ────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileIdentity {
    size: u64,
    modified_nanos: i128,
    created_or_changed_nanos: i128,
    dev: u64,
    ino: u64,
    is_regular_file: bool,
    is_symlink: bool,
}

impl FileIdentity {
    fn modified_ms(&self) -> f64 {
        (self.modified_nanos as f64) / 1_000_000.0
    }
}

#[derive(Debug, Clone)]
struct FileSnapshot {
    name: String,
    path: PathBuf,
    identity: FileIdentity,
}

#[derive(Debug, Clone)]
enum MetadataOutcome {
    Usable {
        title: String,
        header_ms: Option<f64>,
        stored_cwd: String,
    },
    ProjectMismatch {
        stored_cwd: String,
    },
    Unusable,
}

#[derive(Debug, Clone)]
struct CacheEntry {
    directory: String,
    project_key: String,
    identity: FileIdentity,
    outcome: MetadataOutcome,
    activity_ms: Option<f64>,
    count: Option<usize>,
}

#[derive(Debug, Clone)]
struct SummaryCacheEntry {
    directory: String,
    project_key: String,
    membership: Membership,
    top: Vec<Option<FileIdentity>>,
    value: Summary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Membership {
    count: usize,
    hash: u64,
}

#[derive(Default)]
struct CacheState {
    stats: Statistics,
    entry_cache: HashMap<String, CacheEntry>,
    entry_order: Vec<String>,
    summary_cache: HashMap<String, SummaryCacheEntry>,
    summary_order: Vec<String>,
    directory_membership: HashMap<String, Membership>,
    directory_order: Vec<String>,
}

fn cache() -> &'static Mutex<CacheState> {
    static CACHE: OnceLock<Mutex<CacheState>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(CacheState::default()))
}

static READ_MUTATION_HOOK: OnceLock<Mutex<Option<Box<dyn FnMut() + Send>>>> = OnceLock::new();

pub fn set_read_mutation_hook<F: FnMut() + Send + 'static>(hook: Option<F>) {
    let cell = READ_MUTATION_HOOK.get_or_init(|| Mutex::new(None));
    let mut guard = cell.lock().unwrap();
    *guard = hook.map(|f| Box::new(f) as Box<dyn FnMut() + Send>);
}

fn run_read_mutation_hook() {
    if let Some(cell) = READ_MUTATION_HOOK.get() {
        let taken = cell.lock().unwrap().take();
        if let Some(mut f) = taken {
            f();
        }
    }
}

fn system_time_nanos(t: std::io::Result<SystemTime>) -> i128 {
    match t {
        Ok(ts) => match ts.duration_since(UNIX_EPOCH) {
            Ok(d) => d.as_nanos() as i128,
            Err(e) => -(e.duration().as_nanos() as i128),
        },
        Err(_) => 0,
    }
}

fn read_identity(path: &Path) -> Option<FileIdentity> {
    let meta = fs::symlink_metadata(path).ok()?;
    let ft = meta.file_type();
    let is_symlink = ft.is_symlink();
    let is_regular_file = ft.is_file() && !is_symlink;
    let modified_nanos = system_time_nanos(meta.modified());

    #[cfg(unix)]
    let (dev, ino, changed_nanos) = {
        use std::os::unix::fs::MetadataExt;
        (
            meta.dev(),
            meta.ino(),
            (meta.ctime() as i128) * 1_000_000_000 + (meta.ctime_nsec() as i128),
        )
    };

    #[cfg(windows)]
    let (dev, ino, changed_nanos) = {
        use std::os::windows::fs::MetadataExt;
        // Windows FILETIME (100ns 单位) 的创建时间 + file_index（如有）拼入身份
        let created = (meta.creation_time() as i128) * 100;
        let (vol, idx) = windows_file_id(path).unwrap_or((0, 0));
        (vol, idx, created)
    };

    #[cfg(not(any(unix, windows)))]
    let (dev, ino, changed_nanos) = (0u64, 0u64, system_time_nanos(meta.created()));

    Some(FileIdentity {
        size: meta.len(),
        modified_nanos,
        created_or_changed_nanos: changed_nanos,
        dev,
        ino,
        is_regular_file,
        is_symlink,
    })
}

#[cfg(windows)]
fn windows_file_id(path: &Path) -> Option<(u64, u64)> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        FILE_FLAG_BACKUP_SEMANTICS, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        OPEN_EXISTING,
    };

    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    wide.push(0);
    unsafe {
        let handle = CreateFileW(
            wide.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        );
        if handle == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
        let ok = GetFileInformationByHandle(handle, &mut info);
        CloseHandle(handle);
        if ok == 0 {
            return None;
        }
        let idx = ((info.nFileIndexHigh as u64) << 32) | (info.nFileIndexLow as u64);
        Some((info.dwVolumeSerialNumber as u64, idx))
    }
}

fn snapshot_identity(path: &Path) -> Option<FileIdentity> {
    let val = read_identity(path);
    cache().lock().unwrap().stats.attribute_reads += 1;
    val
}

fn stability_identity(path: &Path) -> Option<FileIdentity> {
    let val = read_identity(path);
    cache().lock().unwrap().stats.stability_attribute_reads += 1;
    val
}

fn cache_key(project_key: &str, directory: &str, name: &str) -> String {
    format!("{project_key}\0{directory}\0{name}")
}

fn summary_key(project_key: &str, directory: &str) -> String {
    format!("{project_key}\0{directory}")
}

fn membership_of(names: &[String]) -> Membership {
    let mut hash: u64 = 0;
    for name in names {
        let mut item: u64 = 0xcbf29ce484222325;
        for &b in name.as_bytes() {
            item = (item ^ (b as u64)).wrapping_mul(0x100000001b3);
        }
        hash = hash.wrapping_add(item.wrapping_mul(0x9e3779b97f4a7c15));
    }
    Membership {
        count: names.len(),
        hash,
    }
}

fn purge_directory_locked(state: &mut CacheState, directory: &str) {
    state.entry_cache.retain(|_, v| v.directory != directory);
    let entries = &state.entry_cache;
    state.entry_order.retain(|k| entries.contains_key(k));

    state.summary_cache.retain(|_, v| v.directory != directory);
    let summaries = &state.summary_cache;
    state.summary_order.retain(|k| summaries.contains_key(k));
}

fn note_membership(directory: &str, names: &[String]) -> Membership {
    let current = membership_of(names);
    let mut state = cache().lock().unwrap();
    if let Some(prev) = state.directory_membership.get(directory) {
        if *prev != current {
            purge_directory_locked(&mut state, directory);
        }
    }
    state.directory_membership.insert(directory.to_string(), current);
    state.directory_order.retain(|d| d != directory);
    state.directory_order.push(directory.to_string());
    while state.directory_order.len() > MAX_CACHED_DIRECTORIES {
        let evicted = state.directory_order.remove(0);
        state.directory_membership.remove(&evicted);
        purge_directory_locked(&mut state, &evicted);
    }
    current
}

fn invalidate_directory(directory: &str) {
    let mut state = cache().lock().unwrap();
    state.directory_membership.remove(directory);
    state.directory_order.retain(|d| d != directory);
    purge_directory_locked(&mut state, directory);
}

fn touch_entry_locked(state: &mut CacheState, key: &str) {
    state.entry_order.retain(|k| k != key);
    state.entry_order.push(key.to_string());
}

fn cached_entry(key: &str, project_key: &str, id: &FileIdentity) -> Option<CacheEntry> {
    let mut state = cache().lock().unwrap();
    let hit = match state.entry_cache.get(key) {
        Some(e) if e.identity == *id && e.project_key == project_key => Some(e.clone()),
        _ => None,
    };
    if hit.is_some() {
        state.stats.metadata_hits += 1;
        touch_entry_locked(&mut state, key);
    } else {
        state.stats.metadata_misses += 1;
    }
    hit
}

fn store_entry(key: String, entry: CacheEntry) {
    let mut state = cache().lock().unwrap();
    let dir = entry.directory.clone();
    state.entry_cache.insert(key.clone(), entry);
    touch_entry_locked(&mut state, &key);

    loop {
        let same_dir_count = state
            .entry_order
            .iter()
            .filter(|k| state.entry_cache.get(*k).map(|e| e.directory == dir).unwrap_or(false))
            .count();
        if same_dir_count <= MAX_CACHED_ENTRIES_PER_DIR {
            break;
        }
        if let Some(pos) = state
            .entry_order
            .iter()
            .position(|k| state.entry_cache.get(k).map(|e| e.directory == dir).unwrap_or(false))
        {
            let evicted = state.entry_order.remove(pos);
            state.entry_cache.remove(&evicted);
        } else {
            break;
        }
    }

    while state.entry_order.len() > MAX_CACHED_ENTRIES {
        let evicted = state.entry_order.remove(0);
        state.entry_cache.remove(&evicted);
    }
    state.stats.cache_stores += 1;
}

fn cached_count(key: &str, project_key: &str, id: &FileIdentity) -> Option<usize> {
    let mut state = cache().lock().unwrap();
    let count = state
        .entry_cache
        .get(key)
        .filter(|e| e.identity == *id && e.project_key == project_key)
        .and_then(|e| e.count);
    if count.is_some() {
        state.stats.count_hits += 1;
        touch_entry_locked(&mut state, key);
    }
    count
}

fn store_count(key: &str, project_key: &str, id: &FileIdentity, count: usize) {
    let mut state = cache().lock().unwrap();
    if let Some(entry) = state.entry_cache.get_mut(key) {
        if entry.identity == *id && entry.project_key == project_key {
            entry.count = Some(count);
            state.stats.cache_stores += 1;
        }
    }
}

fn cached_summary(
    key: &str,
    project_key: &str,
    membership: Membership,
    top: &[Option<FileIdentity>],
) -> Option<Summary> {
    let mut state = cache().lock().unwrap();
    let hit = state
        .summary_cache
        .get(key)
        .filter(|e| e.project_key == project_key && e.membership == membership && e.top == top)
        .map(|e| e.value);
    if hit.is_some() {
        state.stats.summary_hits += 1;
        state.summary_order.retain(|k| k != key);
        state.summary_order.push(key.to_string());
    }
    hit
}

fn store_summary(key: String, entry: SummaryCacheEntry) {
    let mut state = cache().lock().unwrap();
    state.summary_cache.insert(key.clone(), entry);
    state.summary_order.retain(|k| k != &key);
    state.summary_order.push(key);
    while state.summary_order.len() > MAX_CACHED_SUMMARIES {
        let evicted = state.summary_order.remove(0);
        state.summary_cache.remove(&evicted);
    }
    state.stats.cache_stores += 1;
}

fn remove_summary(key: &str) {
    let mut state = cache().lock().unwrap();
    state.summary_cache.remove(key);
    state.summary_order.retain(|k| k != key);
}

pub fn invalidate_project(project: &str, agent_dir: &Path) {
    let pkey = path_key(project);
    let dirs: Vec<String> = candidate_directories(project, agent_dir)
        .into_iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    let mut state = cache().lock().unwrap();
    for dir in dirs {
        state.directory_membership.remove(&dir);
        state.directory_order.retain(|d| d != &dir);
        purge_directory_locked(&mut state, &dir);
    }
    state.entry_cache.retain(|_, v| v.project_key != pkey);
    let ec = &state.entry_cache;
    state.entry_order.retain(|k| ec.contains_key(k));
    state.summary_cache.retain(|_, v| v.project_key != pkey);
    let sc = &state.summary_cache;
    state.summary_order.retain(|k| sc.contains_key(k));
}

pub fn invalidate_all() {
    let mut state = cache().lock().unwrap();
    state.entry_cache.clear();
    state.entry_order.clear();
    state.summary_cache.clear();
    state.summary_order.clear();
    state.directory_membership.clear();
    state.directory_order.clear();
}

pub fn statistics() -> Statistics {
    let state = cache().lock().unwrap();
    let mut s = state.stats.clone();
    s.cached_entries = state.entry_cache.len();
    s.cached_directories = state.directory_membership.len();
    s.cached_summaries = state.summary_cache.len();
    let mut per_dir: HashMap<&str, usize> = HashMap::new();
    for e in state.entry_cache.values() {
        *per_dir.entry(&e.directory).or_insert(0) += 1;
    }
    s.largest_directory_entry_count = per_dir.values().copied().max().unwrap_or(0);
    s
}

pub fn reset_statistics() {
    cache().lock().unwrap().stats = Statistics::default();
}

// ── 列表 / 摘要 / 核验 ────────────────────────────────────────

pub fn list(project: &str, agent_dir: &Path) -> Result<Vec<SessionItem>, std::io::Error> {
    ranked_items(project, agent_dir, true)
}

pub fn latest(project: &str, agent_dir: &Path) -> Option<SessionItem> {
    ranked_items(project, agent_dir, false).ok()?.into_iter().next()
}

pub fn validated(path: &str, project: &str, agent_dir: &Path) -> Option<String> {
    let pkey = path_key(project);
    let dir = directory_for(project, agent_dir);
    let dir_str = dir.to_string_lossy().into_owned();
    let std_target = standardize_path(path);
    let target_path = Path::new(&std_target);
    let parent = target_path.parent()?;
    if path_key(&parent.to_string_lossy()) != path_key(&dir_str) {
        return None;
    }
    if target_path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
        return None;
    }
    let name = target_path.file_name()?.to_string_lossy().into_owned();
    let identity = snapshot_identity(target_path)?;
    let snap = FileSnapshot {
        name,
        path: target_path.to_path_buf(),
        identity,
    };
    inspect(&snap, project, &pkey, &dir_str).map(|c| c.item.path)
}

pub fn summary(
    project: &str,
    agent_dir: &Path,
    is_cancelled: &dyn Fn() -> bool,
) -> Option<Summary> {
    let pkey = path_key(project);
    let dir = directory_for(project, agent_dir);
    let dir_str = dir.to_string_lossy().into_owned();
    if is_cancelled() {
        return None;
    }
    let rd = match fs::read_dir(&dir) {
        Ok(rd) => rd,
        Err(_) => {
            invalidate_directory(&dir_str);
            return None;
        }
    };
    cache().lock().unwrap().stats.directory_listings += 1;

    let mut jsonl: Vec<String> = Vec::new();
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".jsonl") {
            jsonl.push(name);
        }
    }
    if jsonl.is_empty() {
        remove_summary(&summary_key(&pkey, &dir_str));
        return None;
    }

    struct Entry {
        path: PathBuf,
        modified_nanos: i128,
        identity: Option<FileIdentity>,
    }

    let mut entries: Vec<Entry> = Vec::with_capacity(jsonl.len());
    for name in &jsonl {
        if is_cancelled() {
            return None;
        }
        let path = dir.join(name);
        let id = snapshot_identity(&path);
        let modified_nanos = id.as_ref().map(|i| i.modified_nanos).unwrap_or(i128::MIN);
        entries.push(Entry {
            path,
            modified_nanos,
            identity: id,
        });
    }
    let membership = note_membership(&dir_str, &jsonl);
    entries.sort_by(|a, b| b.modified_nanos.cmp(&a.modified_nanos));

    let top_count = entries.len().min(3);
    let top_identities: Vec<Option<FileIdentity>> =
        entries[..top_count].iter().map(|e| e.identity.clone()).collect();
    let skey = summary_key(&pkey, &dir_str);
    if let Some(hit) = cached_summary(&skey, &pkey, membership, &top_identities) {
        return Some(hit);
    }

    let mut last_ms: Option<f64> = entries.first().and_then(|e| {
        if e.modified_nanos == i128::MIN {
            None
        } else {
            Some((e.modified_nanos as f64) / 1_000_000.0)
        }
    });
    for e in &entries[..top_count] {
        if is_cancelled() {
            return None;
        }
        if let Some(precise) = last_activity(&e.path) {
            last_ms = Some(match last_ms {
                Some(cur) if cur > precise => cur,
                _ => precise,
            });
        }
    }
    if is_cancelled() {
        return None;
    }
    let val = Summary {
        count: jsonl.len(),
        last_ms,
    };

    let cacheable = entries
        .iter()
        .all(|e| e.identity.as_ref().map(|i| i.is_regular_file).unwrap_or(false));
    if !is_cancelled() && cacheable && top_identities.iter().all(|i| i.is_some()) {
        let stable = entries[..top_count].iter().all(|e| {
            e.identity
                .as_ref()
                .map(|id| stability_identity(&e.path).as_ref() == Some(id))
                .unwrap_or(false)
        });
        if stable {
            store_summary(
                skey,
                SummaryCacheEntry {
                    directory: dir_str,
                    project_key: pkey,
                    membership,
                    top: top_identities,
                    value: val,
                },
            );
        }
    }

    Some(val)
}

fn ranked_items(
    project: &str,
    agent_dir: &Path,
    with_counts: bool,
) -> Result<Vec<SessionItem>, std::io::Error> {
    let pkey = path_key(project);
    let dir = directory_for(project, agent_dir);
    let dir_str = dir.to_string_lossy().into_owned();
    if !dir.exists() {
        invalidate_directory(&dir_str);
        return Ok(Vec::new());
    }
    let rd = fs::read_dir(&dir)?;
    cache().lock().unwrap().stats.directory_listings += 1;

    let mut names: Vec<String> = Vec::new();
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".jsonl") {
            names.push(name);
        }
    }
    note_membership(&dir_str, &names);

    let mut files: Vec<FileSnapshot> = Vec::with_capacity(names.len());
    for name in names {
        let path = dir.join(&name);
        if let Some(id) = snapshot_identity(&path) {
            files.push(FileSnapshot {
                name,
                path,
                identity: id,
            });
        }
    }
    files.sort_by(|a, b| b.identity.modified_nanos.cmp(&a.identity.modified_nanos));

    let mut candidates: Vec<Candidate> = files
        .into_iter()
        .take(MAX_CANDIDATES)
        .filter_map(|snap| inspect(&snap, project, &pkey, &dir_str))
        .collect();
    candidates.sort_by(|a, b| {
        b.item
            .modified_ms
            .partial_cmp(&a.item.modified_ms)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    candidates.truncate(MAX_ITEMS);

    if !with_counts {
        return Ok(candidates.into_iter().map(|c| c.item).collect());
    }

    Ok(candidates
        .into_iter()
        .map(|c| {
            let count = message_count_for(&c, &pkey, &dir_str);
            SessionItem {
                path: c.item.path,
                title: c.item.title,
                modified_ms: c.item.modified_ms,
                message_count: count,
            }
        })
        .collect())
}

struct Candidate {
    item: SessionItem,
    name: String,
    identity: FileIdentity,
}

fn make_item(path: &Path, title: String, modified_ms: f64) -> SessionItem {
    SessionItem {
        path: path.to_string_lossy().into_owned(),
        title: if title.is_empty() {
            "未命名会话".to_string()
        } else {
            title
        },
        modified_ms,
        message_count: 0,
    }
}

fn inspect(
    snap: &FileSnapshot,
    project: &str,
    project_key: &str,
    directory: &str,
) -> Option<Candidate> {
    if snap.path.extension().and_then(|s| s.to_str()) != Some("jsonl")
        || !snap.identity.is_regular_file
        || snap.identity.is_symlink
    {
        return None;
    }
    let parent_ok = snap
        .path
        .parent()
        .map(|p| p.to_string_lossy() == directory)
        .unwrap_or(false);
    if !parent_ok {
        return None;
    }

    let ckey = cache_key(project_key, directory, &snap.name);
    if let Some(entry) = cached_entry(&ckey, project_key, &snap.identity) {
        match entry.outcome {
            MetadataOutcome::Usable {
                title,
                header_ms,
                stored_cwd,
            } => {
                if same_project(&stored_cwd, project) {
                    let modified_ms = entry
                        .activity_ms
                        .or(header_ms)
                        .unwrap_or_else(|| snap.identity.modified_ms());
                    return Some(Candidate {
                        item: make_item(&snap.path, title, modified_ms),
                        name: snap.name.clone(),
                        identity: snap.identity.clone(),
                    });
                }
            }
            MetadataOutcome::ProjectMismatch { stored_cwd } => {
                if !same_project(&stored_cwd, project) {
                    return None;
                }
            }
            MetadataOutcome::Unusable => return None,
        }
    }

    let read = scan_head(&snap.path, project);
    let activity_ms = match &read {
        HeadRead::Accepted(_) => last_activity(&snap.path),
        HeadRead::ProjectMismatch(_) | HeadRead::Unusable => None,
    };
    run_read_mutation_hook();
    let stable = stability_identity(&snap.path).as_ref() == Some(&snap.identity);

    match read {
        HeadRead::Accepted(scan) => {
            let modified_ms = activity_ms
                .or(scan.header_ms)
                .unwrap_or_else(|| snap.identity.modified_ms());
            if stable {
                store_entry(
                    ckey,
                    CacheEntry {
                        directory: directory.to_string(),
                        project_key: project_key.to_string(),
                        identity: snap.identity.clone(),
                        outcome: MetadataOutcome::Usable {
                            title: scan.title.clone(),
                            header_ms: scan.header_ms,
                            stored_cwd: scan.stored_cwd,
                        },
                        activity_ms,
                        count: None,
                    },
                );
            }
            Some(Candidate {
                item: make_item(&snap.path, scan.title, modified_ms),
                name: snap.name.clone(),
                identity: snap.identity.clone(),
            })
        }
        HeadRead::ProjectMismatch(stored_cwd) => {
            if stable {
                store_entry(
                    ckey,
                    CacheEntry {
                        directory: directory.to_string(),
                        project_key: project_key.to_string(),
                        identity: snap.identity.clone(),
                        outcome: MetadataOutcome::ProjectMismatch { stored_cwd },
                        activity_ms: None,
                        count: None,
                    },
                );
            }
            None
        }
        HeadRead::Unusable => {
            if stable {
                store_entry(
                    ckey,
                    CacheEntry {
                        directory: directory.to_string(),
                        project_key: project_key.to_string(),
                        identity: snap.identity.clone(),
                        outcome: MetadataOutcome::Unusable,
                        activity_ms: None,
                        count: None,
                    },
                );
            }
            None
        }
    }
}

fn message_count_for(candidate: &Candidate, project_key: &str, directory: &str) -> usize {
    let ckey = cache_key(project_key, directory, &candidate.name);
    if let Some(hit) = cached_count(&ckey, project_key, &candidate.identity) {
        return hit;
    }
    let before = stability_identity(&candidate.item.path);
    let count = count_messages(Path::new(&candidate.item.path));
    let after = stability_identity(&candidate.item.path);
    if before.as_ref() == Some(&candidate.identity) && after.as_ref() == Some(&candidate.identity) {
        store_count(&ckey, project_key, &candidate.identity, count);
    }
    count
}

struct HeadScan {
    title: String,
    header_ms: Option<f64>,
    stored_cwd: String,
}

enum HeadRead {
    Accepted(HeadScan),
    ProjectMismatch(String),
    Unusable,
}

/// 读文件头部，按 `\n` 切片；`MAX_LINE_BYTES` (256KB) 以上的行整行丢弃但不当作坏文件。
fn scan_head(path: &Path, project: &str) -> HeadRead {
    cache().lock().unwrap().stats.head_scans += 1;
    let Ok(file) = File::open(path) else {
        return HeadRead::Unusable;
    };
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut buf: Vec<u8> = Vec::with_capacity(8192);

    let mut seen_header = false;
    let mut saw_message = false;
    let mut header_ms: Option<f64> = None;
    let mut accepted_cwd: Option<String> = None;
    let mut mismatch_cwd: Option<String> = None;
    let mut name = String::new();
    let mut first_question = String::new();
    let mut lines: usize = 0;
    let mut lines_after_first_question: usize = 0;

    loop {
        if lines >= MAX_SCAN_LINES {
            break;
        }
        buf.clear();
        let Ok(n) = read_line_capped(&mut reader, &mut buf, MAX_LINE_BYTES + 2) else {
            break;
        };
        if n == 0 {
            break;
        }
        let line = trim_line_end(&buf);
        if line.is_empty() {
            continue;
        }
        lines += 1;
        let had_question = !first_question.is_empty();

        if line.len() <= MAX_LINE_BYTES && line.len() > 1 && line[0] == b'{' {
            let skip_fast = seen_header
                && line.starts_with(br#"{"type":""#)
                && !line.starts_with(br#"{"type":"session_info""#)
                && !line.starts_with(br#"{"type":"message""#);
            if !skip_fast {
                if let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(line) {
                    if let Some(kind) = map.get("type").and_then(|v| v.as_str()) {
                        if !seen_header {
                            let id_ok = map.get("id").and_then(|v| v.as_str()).is_some();
                            let stored = map.get("cwd").and_then(|v| v.as_str());
                            if kind == "session" && id_ok {
                                if let Some(stored) = stored {
                                    if same_project(stored, project) {
                                        seen_header = true;
                                        accepted_cwd = Some(stored.to_string());
                                        header_ms = map
                                            .get("timestamp")
                                            .and_then(|v| v.as_str())
                                            .and_then(parse_iso8601_ms);
                                    } else {
                                        mismatch_cwd = Some(stored.to_string());
                                        break;
                                    }
                                } else {
                                    return HeadRead::Unusable;
                                }
                            } else {
                                return HeadRead::Unusable;
                            }
                        } else if kind == "session_info" {
                            if let Some(s) = map.get("name").and_then(|v| v.as_str()) {
                                name = s.trim().to_string();
                            }
                        } else if kind == "message" {
                            if let Some(msg) = map.get("message").and_then(|v| v.as_object()) {
                                saw_message = true;
                                if msg.get("role").and_then(|v| v.as_str()) == Some("user")
                                    && first_question.is_empty()
                                {
                                    first_question =
                                        extract_text(msg.get("content")).trim().to_string();
                                }
                            }
                        }
                    }
                }
            }
        }

        if !name.is_empty() && !first_question.is_empty() {
            break;
        }
        if had_question {
            lines_after_first_question += 1;
            if lines_after_first_question >= TAIL_SESSION_INFO_LINES {
                break;
            }
        }
    }

    if let Some(cwd) = mismatch_cwd {
        return HeadRead::ProjectMismatch(cwd);
    }
    let Some(stored_cwd) = accepted_cwd else {
        return HeadRead::Unusable;
    };
    if !seen_header || (!saw_message && name.is_empty()) {
        return HeadRead::Unusable;
    }

    let chosen = if name.is_empty() {
        &first_question
    } else {
        &name
    };
    let collapsed = collapse_whitespace(chosen);
    let title: String = collapsed.chars().take(200).collect();
    HeadRead::Accepted(HeadScan {
        title,
        header_ms,
        stored_cwd,
    })
}

/// 读一行到 `\n`；若行超过 `cap` 字节，丢弃超长内容并消耗到行尾，保证下一行从行首起。
fn read_line_capped<R: BufRead>(
    reader: &mut R,
    out: &mut Vec<u8>,
    cap: usize,
) -> std::io::Result<usize> {
    let mut total = 0usize;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(total);
        }
        if let Some(pos) = memchr(b'\n', available) {
            let chunk_len = pos + 1;
            if out.len() < cap {
                let take = chunk_len.min(cap - out.len());
                out.extend_from_slice(&available[..take]);
            }
            total += chunk_len;
            reader.consume(chunk_len);
            return Ok(total);
        }
        let avail_len = available.len();
        if out.len() < cap {
            let take = avail_len.min(cap - out.len());
            out.extend_from_slice(&available[..take]);
        }
        total += avail_len;
        reader.consume(avail_len);
    }
}

fn trim_line_end(mut line: &[u8]) -> &[u8] {
    if let Some(rest) = line.strip_suffix(b"\n") {
        line = rest;
    }
    if let Some(rest) = line.strip_suffix(b"\r") {
        line = rest;
    }
    line
}

fn collapse_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for word in s.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    out
}

fn extract_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(arr)) => {
            let mut parts: Vec<&str> = Vec::new();
            for item in arr {
                if item.get("type").and_then(|v| v.as_str()) == Some("text") {
                    if let Some(t) = item.get("text").and_then(|v| v.as_str()) {
                        parts.push(t);
                    }
                }
            }
            parts.join(" ")
        }
        _ => String::new(),
    }
}

/// 统计消息数：大块顺序扫描行首 `{"type":"message"`，不分配整文件内存也不构造 JSON。
fn count_messages(path: &Path) -> usize {
    cache().lock().unwrap().stats.message_count_reads += 1;
    let Ok(file) = File::open(path) else {
        return 0;
    };
    const NEEDLE: &[u8] = br#"{"type":"message""#;
    let mut reader = BufReader::with_capacity(128 * 1024, file);
    let mut count = 0usize;
    let mut at_line_start = true;
    let mut carry: Vec<u8> = Vec::new();

    loop {
        let buf = match reader.fill_buf() {
            Ok(b) => b,
            Err(_) => break,
        };
        if buf.is_empty() {
            if at_line_start && carry.starts_with(NEEDLE) {
                count += 1;
            }
            break;
        }
        let mut pos = 0usize;
        while pos < buf.len() {
            if at_line_start {
                if !carry.is_empty() {
                    let need = NEEDLE.len().saturating_sub(carry.len());
                    let take = need.min(buf.len() - pos);
                    carry.extend_from_slice(&buf[pos..pos + take]);
                    if carry.len() < NEEDLE.len() {
                        // 如果遇到换行，说明这行比 NEEDLE 短，清空 carry 重新开始
                        if let Some(nl) = memchr(b'\n', &carry) {
                            let consumed = take - (carry.len() - 1 - nl);
                            pos += consumed;
                            carry.clear();
                            at_line_start = true;
                            continue;
                        }
                        pos += take;
                        break;
                    }
                    if carry.as_slice() == NEEDLE {
                        count += 1;
                    }
                    carry.clear();
                    at_line_start = false;
                    // 当前行后面去找换行
                } else if buf.len() - pos >= NEEDLE.len() {
                    if &buf[pos..pos + NEEDLE.len()] == NEEDLE {
                        count += 1;
                    }
                    at_line_start = false;
                } else {
                    // 缓冲区剩余不足 NEEDLE：如果里面含换行，直接跨过；否则暂存进 carry
                    if let Some(nl) = memchr(b'\n', &buf[pos..]) {
                        pos += nl + 1;
                        at_line_start = true;
                        continue;
                    }
                    carry.extend_from_slice(&buf[pos..]);
                    pos = buf.len();
                    break;
                }
            }
            if let Some(nl) = memchr(b'\n', &buf[pos..]) {
                pos += nl + 1;
                at_line_start = true;
            } else {
                pos = buf.len();
            }
        }
        let len = buf.len();
        reader.consume(len);
    }

    count
}

/// 读文件尾部 64KB 找最后一条 message 的 timestamp（不用文件 mtime）。
fn last_activity(path: &Path) -> Option<f64> {
    cache().lock().unwrap().stats.activity_reads += 1;
    let mut file = File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let start = size.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut data = Vec::with_capacity((size - start) as usize);
    file.read_to_end(&mut data).ok()?;

    for raw in data.split(|&b| b == b'\n').rev() {
        let line = raw.strip_suffix(b"\r").unwrap_or(raw);
        if !line.starts_with(b"{") {
            continue;
        }
        let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if obj.get("type").and_then(|v| v.as_str()) != Some("message") {
            continue;
        }
        let Some(msg) = obj.get("message").and_then(|v| v.as_object()) else {
            continue;
        };
        if let Some(ms) = msg.get("timestamp").and_then(|v| v.as_f64()) {
            return Some(ms);
        }
        if let Some(iso) = obj.get("timestamp").and_then(|v| v.as_str()) {
            if let Some(ms) = parse_iso8601_ms(iso) {
                return Some(ms);
            }
        }
    }
    None
}

/// 解析 RFC3339 / ISO8601 时间戳（支持毫秒与 Z / ±HH:MM 偏移）为 epoch 毫秒
pub fn parse_iso8601_ms(s: &str) -> Option<f64> {
    let bytes = s.as_bytes();
    // YYYY-MM-DDTHH:MM:SS(.fff...)(Z|+HH:MM|-HH:MM)
    if bytes.len() < 20 {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    if bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let month: u32 = s.get(5..7)?.parse().ok()?;
    let day: u32 = s.get(8..10)?.parse().ok()?;
    if bytes[10] != b'T' && bytes[10] != b't' && bytes[10] != b' ' {
        return None;
    }
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let minute: i64 = s.get(14..16)?.parse().ok()?;
    let second: i64 = s.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=60).contains(&second)
    {
        return None;
    }

    let mut idx = 19;
    let mut millis: i64 = 0;
    if idx < bytes.len() && bytes[idx] == b'.' {
        idx += 1;
        let frac_start = idx;
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            idx += 1;
        }
        let frac = &s[frac_start..idx];
        if frac.is_empty() {
            return None;
        }
        let mut pad = String::with_capacity(3);
        for c in frac.chars().take(3) {
            pad.push(c);
        }
        while pad.len() < 3 {
            pad.push('0');
        }
        millis = pad.parse().ok()?;
    }

    let tz_offset_secs: i64 = if idx < bytes.len() {
        match bytes[idx] {
            b'Z' | b'z' => 0,
            b'+' | b'-' => {
                let sign = if bytes[idx] == b'+' { 1i64 } else { -1i64 };
                let rest = &s[idx + 1..];
                let (hh, mm) = if let Some((h, m)) = rest.split_once(':') {
                    (h.parse::<i64>().ok()?, m.parse::<i64>().ok()?)
                } else if rest.len() == 4 {
                    (
                        rest[0..2].parse::<i64>().ok()?,
                        rest[2..4].parse::<i64>().ok()?,
                    )
                } else {
                    return None;
                };
                sign * (hh * 3600 + mm * 60)
            }
            _ => return None,
        }
    } else {
        return None;
    };

    let days = days_from_civil(year, month as i64, day as i64);
    let secs = days * 86_400 + hour * 3600 + minute * 60 + second - tz_offset_secs;
    Some((secs * 1000 + millis) as f64)
}

/// Howard Hinnant civil-from-days inverse：计算距离 1970-01-01 的天数
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = y - if m <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

// ── 摘要协调器 ────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SummarySnapshot {
    pub generation: u64,
    pub summaries: HashMap<String, Summary>,
}

pub type ScannerFn = Arc<dyn Fn(&str, &dyn Fn() -> bool) -> Option<Summary> + Send + Sync>;
pub type CompletionFn = Box<dyn FnOnce(SummarySnapshot) + Send>;

struct CoordInner {
    pending: Vec<String>,
    running_projects: Vec<String>,
    running_generation: u64,
    is_running: bool,
    next_generation: u64,
    waiting: HashMap<u64, CompletionFn>,
    carry: Option<CompletionFn>,
    token: Arc<AtomicBool>,
    stopped: bool,
    worker_in_flight: usize,
    delivery_projects: Vec<String>,
    suppressed: HashMap<String, String>,
    pending_invalidations: HashMap<String, String>,
}

pub struct SummaryCoordinator {
    agent_dir: PathBuf,
    scan: ScannerFn,
    inner: Arc<Mutex<CoordInner>>,
}

impl SummaryCoordinator {
    pub fn new(agent_dir: PathBuf) -> Self {
        let dir_for_scan = agent_dir.clone();
        let scan: ScannerFn =
            Arc::new(move |project, cancelled| summary(project, &dir_for_scan, cancelled));
        Self::with_scanner(agent_dir, scan)
    }

    pub fn with_scanner(agent_dir: PathBuf, scan: ScannerFn) -> Self {
        Self {
            agent_dir,
            scan,
            inner: Arc::new(Mutex::new(CoordInner {
                pending: Vec::new(),
                running_projects: Vec::new(),
                running_generation: 0,
                is_running: false,
                next_generation: 0,
                waiting: HashMap::new(),
                carry: None,
                token: Arc::new(AtomicBool::new(false)),
                stopped: false,
                worker_in_flight: 0,
                delivery_projects: Vec::new(),
                suppressed: HashMap::new(),
                pending_invalidations: HashMap::new(),
            })),
        }
    }

    pub fn dedupe(projects: &[String]) -> Vec<String> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut out = Vec::with_capacity(projects.len());
        for p in projects {
            if seen.insert(path_key(p)) {
                out.push(p.clone());
            }
        }
        out
    }

    pub fn request<F>(&self, projects: &[String], completion: F)
    where
        F: FnOnce(SummarySnapshot) + Send + 'static,
    {
        let incoming = Self::dedupe(projects);
        let completion: CompletionFn = Box::new(completion);
        let launch = {
            let mut inner = self.inner.lock().unwrap();
            if inner.stopped {
                return;
            }
            for p in &incoming {
                let k = path_key(p);
                inner.suppressed.remove(&k);
                inner.pending_invalidations.remove(&k);
            }
            if inner.is_running {
                if incoming.is_empty() {
                    inner.token.store(true, Ordering::SeqCst);
                    inner.pending.clear();
                    inner.waiting.clear();
                    inner.carry = Some(completion);
                    return;
                }
                let mut combined = Vec::with_capacity(
                    inner.running_projects.len() + inner.pending.len() + incoming.len(),
                );
                combined.extend(inner.running_projects.iter().cloned());
                combined.extend(inner.pending.iter().cloned());
                combined.extend(incoming);
                inner.pending = Self::dedupe(&combined);
                let rg = inner.running_generation;
                inner.waiting.remove(&rg);
                inner.carry = Some(completion);
                inner.token.store(true, Ordering::SeqCst);
                return;
            }

            let mut combined = Vec::with_capacity(inner.pending.len() + incoming.len());
            combined.extend(inner.pending.drain(..));
            combined.extend(incoming);
            let jobs = Self::dedupe(&combined);
            inner.next_generation += 1;
            let generation = inner.next_generation;
            let round_token = Arc::new(AtomicBool::new(false));
            inner.running_projects = jobs.clone();
            inner.running_generation = generation;
            inner.is_running = true;
            inner.token = round_token.clone();
            inner.waiting.insert(generation, completion);
            inner.worker_in_flight += 1;
            (generation, jobs, round_token)
        };

        self.spawn_round(launch.0, launch.1, launch.2);
    }

    pub fn cancel_all(&self) {
        let invalidations = {
            let mut inner = self.inner.lock().unwrap();
            reset_locked(&mut inner);
            let list: Vec<String> = inner.pending_invalidations.values().cloned().collect();
            if inner.worker_in_flight == 0 {
                inner.pending_invalidations.clear();
                inner.suppressed.clear();
            }
            list
        };
        for p in invalidations {
            invalidate_project(&p, &self.agent_dir);
        }
    }

    pub fn shutdown(&self) {
        let invalidations = {
            let mut inner = self.inner.lock().unwrap();
            inner.stopped = true;
            reset_locked(&mut inner);
            let list: Vec<String> = inner.pending_invalidations.values().cloned().collect();
            if inner.worker_in_flight == 0 {
                inner.pending_invalidations.clear();
                inner.suppressed.clear();
            }
            list
        };
        for p in invalidations {
            invalidate_project(&p, &self.agent_dir);
        }
    }

    pub fn remove(&self, project: &str) {
        let key = path_key(project);
        {
            let mut inner = self.inner.lock().unwrap();
            let live = inner
                .running_projects
                .iter()
                .chain(inner.pending.iter())
                .chain(inner.delivery_projects.iter())
                .any(|p| path_key(p) == key);
            if live || inner.worker_in_flight > 0 {
                inner.suppressed.insert(key.clone(), project.to_string());
                inner
                    .pending_invalidations
                    .insert(key.clone(), project.to_string());
                inner.pending.retain(|p| path_key(p) != key);
            } else {
                inner.suppressed.remove(&key);
                inner.pending_invalidations.remove(&key);
            }
        }
        invalidate_project(project, &self.agent_dir);
    }

    fn spawn_round(&self, generation: u64, jobs: Vec<String>, token: Arc<AtomicBool>) {
        let inner = self.inner.clone();
        let scan = self.scan.clone();
        let agent_dir = self.agent_dir.clone();
        std::thread::spawn(move || {
            run_round(inner, scan, agent_dir, generation, jobs, token);
        });
    }
}

fn reset_locked(inner: &mut CoordInner) {
    inner.pending.clear();
    inner.running_projects.clear();
    inner.delivery_projects.clear();
    inner.waiting.clear();
    inner.carry = None;
    inner.token.store(true, Ordering::SeqCst);
    inner.is_running = false;
}

fn reclaim_locked(inner: &mut CoordInner) {
    let live: HashSet<String> = inner
        .running_projects
        .iter()
        .chain(inner.pending.iter())
        .chain(inner.delivery_projects.iter())
        .map(|p| path_key(p))
        .collect();
    inner.suppressed.retain(|k, _| live.contains(k));
}

fn run_round(
    inner: Arc<Mutex<CoordInner>>,
    scan: ScannerFn,
    agent_dir: PathBuf,
    generation: u64,
    jobs: Vec<String>,
    token: Arc<AtomicBool>,
) {
    let mut round_summaries: HashMap<String, Summary> = HashMap::new();
    for project in &jobs {
        if token.load(Ordering::SeqCst) {
            break;
        }
        let skip = {
            let guard = inner.lock().unwrap();
            guard.suppressed.contains_key(&path_key(project))
        };
        if skip {
            continue;
        }
        let tok_ref = &token;
        let is_cancelled = || tok_ref.load(Ordering::SeqCst);
        if let Some(val) = scan(project, &is_cancelled) {
            round_summaries.insert(project.clone(), val);
        }
    }

    let (invalidations, completion, next_round) = {
        let mut guard = inner.lock().unwrap();
        if guard.worker_in_flight > 0 {
            guard.worker_in_flight -= 1;
        }
        let invalidations: Vec<String> = guard.pending_invalidations.drain().map(|(_, v)| v).collect();
        if !guard.is_running || guard.running_generation != generation {
            reclaim_locked(&mut guard);
            drop(guard);
            for p in invalidations {
                invalidate_project(&p, &agent_dir);
            }
            return;
        }
        let was_cancelled = token.load(Ordering::SeqCst);
        guard.is_running = false;
        guard.running_projects.clear();
        if !guard.suppressed.is_empty() {
            round_summaries.retain(|k, _| !guard.suppressed.contains_key(&path_key(k)));
        }
        let completion = if !was_cancelled {
            guard.waiting.remove(&generation)
        } else {
            None
        };
        guard.delivery_projects = if completion.is_some() {
            jobs
        } else {
            Vec::new()
        };

        let next_round = if !guard.pending.is_empty() || guard.carry.is_some() {
            guard.next_generation += 1;
            let next = guard.next_generation;
            let round_token = Arc::new(AtomicBool::new(false));
            let round_jobs = std::mem::take(&mut guard.pending);
            guard.running_generation = next;
            guard.running_projects = round_jobs.clone();
            guard.is_running = true;
            guard.token = round_token.clone();
            if let Some(cb) = guard.carry.take() {
                guard.waiting.insert(next, cb);
            }
            guard.worker_in_flight += 1;
            Some((next, round_jobs, round_token))
        } else {
            None
        };
        reclaim_locked(&mut guard);
        (invalidations, completion, next_round)
    };

    for p in invalidations {
        invalidate_project(&p, &agent_dir);
    }

    if let Some(cb) = completion {
        let delivered = {
            let guard = inner.lock().unwrap();
            if !guard.stopped
                && !token.load(Ordering::SeqCst)
                && guard.running_generation == generation
                && guard.next_generation == generation
            {
                let mut map = round_summaries;
                if !guard.suppressed.is_empty() {
                    map.retain(|k, _| !guard.suppressed.contains_key(&path_key(k)));
                }
                Some(map)
            } else {
                None
            }
        };
        if let Some(map) = delivered {
            cb(SummarySnapshot {
                generation,
                summaries: map,
            });
        }
        let late_invalidations: Vec<String> = {
            let mut guard = inner.lock().unwrap();
            guard.delivery_projects.clear();
            let list: Vec<String> = guard.pending_invalidations.drain().map(|(_, v)| v).collect();
            reclaim_locked(&mut guard);
            list
        };
        for p in late_invalidations {
            invalidate_project(&p, &agent_dir);
        }
    }

    if let Some((next_gen, next_jobs, next_tok)) = next_round {
        std::thread::spawn(move || {
            run_round(inner, scan, agent_dir, next_gen, next_jobs, next_tok);
        });
    }
}

/// 接入层投影：把一轮快照投影到本地字典（对齐 Swift 的 ProcessProbe.RuntimeProjection）
pub fn apply_runtime_projection(
    meta: &mut HashMap<String, Summary>,
    requested: &HashSet<String>,
    snapshot: &HashMap<String, Summary>,
    replace_all: bool,
    current: &HashSet<String>,
) {
    if replace_all {
        meta.clear();
    }
    let mut by_key: HashMap<String, Summary> = HashMap::new();
    for (k, v) in snapshot {
        by_key.insert(path_key(k), *v);
    }
    for req in requested {
        let nk = path_key(req);
        if let Some(val) = by_key.get(&nk).copied() {
            let existing_keys: Vec<String> = meta
                .keys()
                .filter(|k| path_key(k) == nk)
                .cloned()
                .collect();
            for ek in existing_keys {
                meta.insert(ek, val);
            }
            meta.insert(req.clone(), val);
        } else {
            meta.retain(|k, _| path_key(k) != nk);
        }
    }
    meta.retain(|k, _| current.contains(&path_key(k)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::mpsc;

    fn temp_root(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "pi-launcher-history-{}-{}",
            tag,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        base
    }

    fn header_line(id: &str, cwd: &str, ts: &str) -> String {
        let cwd_json = serde_json::to_string(cwd).unwrap();
        format!(r#"{{"type":"session","version":3,"id":"{id}","timestamp":"{ts}","cwd":{cwd_json}}}"#)
    }

    fn msg_line(role: &str, text: &str, ms: i64) -> String {
        let text_json = serde_json::to_string(text).unwrap();
        format!(
            r#"{{"type":"message","id":"m-{ms}","message":{{"role":"{role}","content":{text_json},"timestamp":{ms}}},"timestamp":"2026-09-21T17:30:53.000Z"}}"#
        )
    }

    #[test]
    fn encode_and_drive_case_candidates() {
        assert_eq!(encode_cwd(r"C:\Users\x\proj"), "--C--Users-x-proj--");
        assert_eq!(encode_cwd(r"c:\Users\x\proj"), "--c--Users-x-proj--");
        assert_eq!(encode_cwd("/tmp/我的 项目.v2"), "--tmp-我的 项目.v2--");

        let root = temp_root("drive");
        let agent = root.join("agent");
        let cands = candidate_directories(r"C:\Users\demo\proj", &agent);
        let names: Vec<String> = cands
            .iter()
            .filter_map(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
            .collect();
        assert!(names.contains(&"--C--Users-demo-proj--".to_string()));
        assert!(names.contains(&"--c--Users-demo-proj--".to_string()));

        // Windows 同一位置：C:\ ↔ c:\、尾斜杠与正斜杠等价
        assert!(same_project(r"C:\Users\Demo\Proj\", r"c:/users/demo/proj"));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn list_latest_validated_long_line_and_limits() {
        invalidate_all();
        let root = temp_root("list");
        let agent = root.join("agent");
        let project_dir = root.join("history 项目.x");
        fs::create_dir_all(&project_dir).unwrap();
        let project = project_dir.to_string_lossy().into_owned();
        let sessions = directory_for(&project, &agent);
        fs::create_dir_all(&sessions).unwrap();

        let write = |name: &str, lines: Vec<String>| {
            fs::write(sessions.join(name), lines.join("\n") + "\n").unwrap();
        };

        let base: i64 = 1_790_000_000_000;
        write(
            "a.jsonl",
            vec![
                header_line("id-a", &project, "2026-09-21T17:30:53.438Z"),
                msg_line("user", "第一条提问", base),
                r#"{"type":"session_info","name":"  重构   启动器  ","timestamp":"2026-09-21T18:00:00.000Z"}"#
                    .to_string(),
                msg_line("assistant", "回答", base + 5_000_000),
            ],
        );
        write(
            "b.jsonl",
            vec![
                header_line("id-b", &project, "2026-09-20T10:00:00.000Z"),
                msg_line("user", "  帮我\n换行   折叠  ", base + 300_000),
                msg_line("assistant", "这段回答不该进标题", base + 900_000),
            ],
        );
        write(
            "c.jsonl",
            vec![
                header_line(
                    "id-c",
                    &root.join("别的项目").to_string_lossy(),
                    "2026-09-21T17:00:00.000Z",
                ),
                msg_line("user", "别的项目的问题", base + 100_000),
            ],
        );
        write(
            "d.jsonl",
            vec![header_line("id-d", &project, "2026-09-21T17:00:00.000Z")],
        );
        // 超 256KB 行在末尾与中间：>256KB 丢弃而不破坏前后读取，<=256KB（含 45KB 首问）正常保留
        let huge = msg_line("assistant", &"x".repeat(300 * 1024), base + 1_200_000);
        write(
            "e.jsonl",
            vec![
                header_line("id-e", &project, "2026-09-21T17:00:00.000Z"),
                "{ 这不是合法 JSON".to_string(),
                huge,
                msg_line("user", "超大行之后仍要能读到这条", base + 1_800_000),
            ],
        );
        let big_user_q = "问".repeat(15_000); // ~45KB UTF-8（<256KB，曾被 8KB 截断）
        write(
            "bigq.jsonl",
            vec![
                header_line("id-bigq", &project, "2026-09-21T17:00:00.000Z"),
                msg_line("user", &big_user_q, base + 2_100_000),
            ],
        );
        for i in 0..11 {
            write(
                &format!("fill-{i}.jsonl"),
                vec![
                    header_line(&format!("id-f{i}"), &project, "2026-09-19T10:00:00.000Z"),
                    msg_line(
                        "user",
                        &format!("填充会话 {i}"),
                        base - 10_000_000 - (i as i64) * 1_000_000,
                    ),
                ],
            );
        }
        write(
            "g.jsonl",
            vec![
                header_line("id-g", &project, "2026-09-18T10:00:00.000Z"),
                msg_line("user", &"长".repeat(300), base + 400_000),
            ],
        );
        let mut prelude = vec![header_line("id-h", &project, "2026-09-21T19:00:00.000Z")];
        for i in 0..24 {
            prelude.push(format!(
                r#"{{"type":"thinking_level_change","id":"t{i}","thinkingLevel":"high","timestamp":"2026-09-21T19:00:00.000Z"}}"#
            ));
        }
        prelude.push(msg_line("system", "系统提示", base + 6_000_000));
        prelude.push(msg_line("user", "切了很多次思考等级后的最新会话", base + 6_000_000));
        prelude.push(msg_line("assistant", "收到", base + 6_001_000));
        write("h.jsonl", prelude);
        fs::write(sessions.join("ignore.txt"), "not a session\n").unwrap();

        let found = list(&project, &agent).unwrap();
        assert_eq!(found.len(), 10);
        let titles: Vec<&str> = found.iter().take(3).map(|s| s.title.as_str()).collect();
        assert_eq!(
            titles,
            vec!["切了很多次思考等级后的最新会话", "重构 启动器", &"问".repeat(200)]
        );
        assert!(found[0].path.ends_with("h.jsonl"));
        assert!(found.iter().any(|s| s.title == "帮我 换行 折叠"));
        assert!(found.iter().any(|s| s.title == "超大行之后仍要能读到这条"));
        assert!(!found.iter().any(|s| s.title.contains("不该进标题")));
        assert!(!found.iter().any(|s| s.path.ends_with("c.jsonl")));
        assert!(!found.iter().any(|s| s.path.ends_with("d.jsonl")));
        assert!(!found.iter().any(|s| s.path.ends_with("ignore.txt")));
        assert!(found.iter().any(|s| s.title == "长".repeat(200)));

        for w in found.windows(2) {
            assert!(w[0].modified_ms >= w[1].modified_ms);
        }

        // latest 与 list 第一条一致
        let top = latest(&project, &agent).unwrap();
        assert_eq!(top.path, found[0].path);

        // validated 回核
        let valid_a = sessions.join("a.jsonl").to_string_lossy().into_owned();
        assert!(validated(&valid_a, &project, &agent).is_some());
        assert!(validated("/etc/hosts", &project, &agent).is_none());
        let traversal = sessions
            .join("..")
            .join("..")
            .join("a.jsonl")
            .to_string_lossy()
            .into_owned();
        assert!(validated(&traversal, &project, &agent).is_none());
        assert!(validated(
            &sessions.join("d.jsonl").to_string_lossy(),
            &project,
            &agent
        )
        .is_none());

        // 计数校验
        assert_eq!(
            found.iter().find(|s| s.path.ends_with("h.jsonl")).unwrap().message_count,
            3
        );
        assert_eq!(
            found.iter().find(|s| s.path.ends_with("a.jsonl")).unwrap().message_count,
            2
        );
        assert_eq!(
            found.iter().find(|s| s.path.ends_with("b.jsonl")).unwrap().message_count,
            2
        );

        let sum = summary(&project, &agent, &|| false).unwrap();
        assert_eq!(sum.count, 19);
        assert!(sum.last_ms.unwrap() >= (base + 6_001_000) as f64);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn collision_mutation_and_tail_activity() {
        invalidate_all();
        let root = temp_root("col");
        let agent = root.join("agent");
        let p_a = root.join("a-b");
        let p_b = root.join("a").join("b");
        fs::create_dir_all(&p_a).unwrap();
        fs::create_dir_all(&p_b).unwrap();
        let sa = p_a.to_string_lossy().into_owned();
        let sb = p_b.to_string_lossy().into_owned();
        let da = directory_for(&sa, &agent);
        fs::create_dir_all(&da).unwrap();
        let base: i64 = 1_790_000_000_000;
        fs::write(
            da.join("shared.jsonl"),
            format!(
                "{}\n{}\n",
                header_line("col-1", &sa, "2026-09-21T17:00:00.000Z"),
                msg_line("user", "只属于 A", base)
            ),
        )
        .unwrap();

        assert!(list(&sb, &agent).unwrap().is_empty());
        assert_eq!(list(&sa, &agent).unwrap().len(), 1);
        assert!(list(&sb, &agent).unwrap().is_empty());

        // 读取中修改不写缓存
        let mut_dir = root.join("mut");
        fs::create_dir_all(&mut_dir).unwrap();
        let mp = mut_dir.to_string_lossy().into_owned();
        let md = directory_for(&mp, &agent);
        fs::create_dir_all(&md).unwrap();
        let mf = md.join("only.jsonl");
        fs::write(
            &mf,
            format!(
                "{}\n{}\n{}\n",
                header_line("mut-1", &mp, "2026-09-21T17:00:00.000Z"),
                msg_line("user", "读中变化", base),
                msg_line("assistant", "答", base + 1_000)
            ),
        )
        .unwrap();
        invalidate_project(&mp, &agent);
        reset_statistics();
        let mf_clone = mf.clone();
        set_read_mutation_hook(Some(move || {
            let mut f = fs::OpenOptions::new().append(true).open(&mf_clone).unwrap();
            writeln!(f, "{}", msg_line("user", "追加", base + 2_000_000)).unwrap();
        }));
        let _ = list(&mp, &agent).unwrap();
        assert_eq!(statistics().cache_stores, 0);
        let settled = list(&mp, &agent).unwrap();
        assert_eq!(settled[0].message_count, 3);

        // iso8601 解析
        assert!(parse_iso8601_ms("2026-09-21T17:30:53.438Z").is_some());
        assert!(parse_iso8601_ms("2026-09-21T17:30:53+08:00").is_some());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn coordinator_dedup_merge_and_shutdown() {
        let root = temp_root("coord");
        let agent = root.join("agent");
        let coord = SummaryCoordinator::with_scanner(
            agent,
            Arc::new(|project, cancelled| {
                if cancelled() {
                    return None;
                }
                Some(Summary {
                    count: project.len(),
                    last_ms: Some(1_700_000_000_000.0),
                })
            }),
        );
        let (tx, rx) = mpsc::channel();
        coord.request(&["/a".into(), "/a/".into(), "/b".into()], move |snap| {
            let _ = tx.send(snap);
        });
        let snap = rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(snap.summaries.len(), 2);

        coord.shutdown();
        let (tx2, rx2) = mpsc::channel();
        coord.request(&["/c".into()], move |s| {
            let _ = tx2.send(s);
        });
        assert!(rx2.recv_timeout(Duration::from_millis(200)).is_err());

        let _ = fs::remove_dir_all(&root);
    }
}
