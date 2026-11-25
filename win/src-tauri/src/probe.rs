use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

/// Windows 上统一步调比较工作目录：
/// - 去掉可能由 Win32 PEB 返回的 `\\?\` / `\\?\UNC\` 前缀
/// - 把 `/` 变成 `\`
/// - 去掉结尾 `\`（保留盘符根目录如 `c:\` 与 POSIX `/`）
/// - Windows 路径统一小写（盘符 `C:\` 与 `c:\` 等价、目录不区分大小写）
pub fn normalize_cwd_for_compare(raw: &str) -> String {
    let stripped = if let Some(rest) = raw.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = raw.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        raw.to_string()
    };

    let bytes = stripped.as_bytes();
    let is_win = (bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':')
        || (bytes.len() >= 2
            && (bytes[0] == b'\\' || bytes[0] == b'/')
            && (bytes[1] == b'\\' || bytes[1] == b'/'));

    if is_win {
        let mut s = stripped.replace('/', "\\");
        while s.len() > 3 && s.ends_with('\\') {
            s.pop();
        }
        s.to_ascii_lowercase()
    } else {
        let mut s = stripped;
        while s.len() > 1 && s.ends_with('/') {
            s.pop();
        }
        s
    }
}

pub fn build_targets(project_path: &str) -> HashSet<String> {
    let mut targets = HashSet::new();
    targets.insert(normalize_cwd_for_compare(project_path));
    if let Ok(canon) = std::fs::canonicalize(project_path) {
        targets.insert(normalize_cwd_for_compare(&canon.to_string_lossy()));
    }
    targets
}

/// 进程身份判断：匹配真 `pi` 或测试替身命令。
/// Windows 上通过 `install.ps1` 或 `npm i -g` 安装的 `pi` 最终是：
/// `node.exe <...>\pi-coding-agent\dist\cli.js` 或 `node.exe <...>\pi-launcher.js` 或 `...\pi(.exe|.cmd)`。
pub fn matches_command(
    expected: Option<&str>,
    proc_name: &str,
    exe: Option<&Path>,
    cmd: &[String],
) -> bool {
    let Some(expected) = expected else {
        return true;
    };
    let needle = expected.trim();
    if needle.is_empty() {
        return true;
    }
    let needle_lower = needle.to_ascii_lowercase();

    if needle_lower == "pi" {
        let exe_is_node = exe
            .and_then(|p| p.file_stem())
            .and_then(|s| s.to_str())
            .map(|s| s.eq_ignore_ascii_case("node"))
            .unwrap_or_else(|| proc_name.eq_ignore_ascii_case("node") || proc_name.eq_ignore_ascii_case("node.exe"));

        if exe_is_node {
            for arg in cmd {
                let low = arg.to_ascii_lowercase();
                if low.contains("pi-coding-agent") || low.ends_with("pi-launcher.js") {
                    return true;
                }
                if low.ends_with("\\pi")
                    || low.ends_with("/pi")
                    || low.ends_with("\\pi.js")
                    || low.ends_with("/pi.js")
                {
                    return true;
                }
            }
        }

        // 也允许直接是名为 pi / pi.exe / pi.cmd 的进程或第一参数
        if matches_basename(proc_name, "pi") {
            return true;
        }
        if let Some(ex) = exe {
            if matches_exe_stem(ex, "pi") {
                return true;
            }
        }
        if let Some(first) = cmd.first() {
            if matches_path_basename(first, "pi") {
                return true;
            }
        }
        return false;
    }

    if matches_basename(proc_name, &needle_lower) {
        return true;
    }
    if let Some(ex) = exe {
        if matches_exe_stem(ex, &needle_lower) {
            return true;
        }
    }
    if let Some(first) = cmd.first() {
        if matches_path_basename(first, &needle_lower) {
            return true;
        }
    }
    false
}

fn matches_basename(name: &str, needle_lower: &str) -> bool {
    let low = name.to_ascii_lowercase();
    let stem = low.strip_suffix(".exe").unwrap_or(&low);
    low == needle_lower || stem == needle_lower
}

fn matches_exe_stem(path: &Path, needle_lower: &str) -> bool {
    let file_name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    file_name.eq_ignore_ascii_case(needle_lower) || stem.eq_ignore_ascii_case(needle_lower)
}

fn matches_path_basename(arg: &str, needle_lower: &str) -> bool {
    let base = arg.rsplit(['/', '\\']).next().unwrap_or(arg);
    let low = base.to_ascii_lowercase();
    let stem = low
        .strip_suffix(".exe")
        .or_else(|| low.strip_suffix(".cmd"))
        .or_else(|| low.strip_suffix(".bat"))
        .unwrap_or(&low);
    low == needle_lower || stem == needle_lower
}

// ── 生命周期门（对齐 Swift LifecycleGuard）─────────────────────

#[derive(Clone, Default)]
pub struct LifecycleGuard {
    active: Arc<AtomicBool>,
}

impl LifecycleGuard {
    pub fn new() -> Self {
        Self {
            active: Arc::new(AtomicBool::new(true)),
        }
    }

    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::SeqCst)
    }

    pub fn shutdown(&self) {
        self.active.store(false, Ordering::SeqCst);
    }

    pub fn perform_if_active<F: FnOnce()>(&self, f: F) -> bool {
        if !self.is_active() {
            return false;
        }
        f();
        true
    }
}

// ── 准备期动作队列（对齐 Swift ActionQueue）────────────────────

#[derive(Default)]
pub struct ActionQueue {
    actions: Vec<Box<dyn FnOnce() + Send>>,
    open: bool,
}

impl ActionQueue {
    pub fn new() -> Self {
        Self {
            actions: Vec::new(),
            open: true,
        }
    }

    pub fn enqueue<F: FnOnce() + Send + 'static>(&mut self, action: F) {
        if self.open {
            self.actions.push(Box::new(action));
        }
    }

    pub fn take_all(&mut self) -> Vec<Box<dyn FnOnce() + Send>> {
        std::mem::take(&mut self.actions)
    }

    pub fn close(&mut self) {
        self.open = false;
        self.actions.clear();
    }
}

// ── 共享启动监测器（对齐 Swift ProcessProbe.Monitor）──────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MonitorResult {
    Running,
    TimedOut,
}

#[derive(Debug, Clone)]
pub struct ProcRecord {
    pub start_secs: u64,
    pub cwd: Option<String>,
    pub name: String,
    pub exe: Option<String>,
    pub cmd: Vec<String>,
}

pub type SnapshotFn = Arc<dyn Fn() -> Vec<ProcRecord> + Send + Sync>;

struct MonitorRequest {
    targets: HashSet<String>,
    since_secs: u64,
    expected_command: Option<String>,
    deadline_ms: u128,
    completion: Box<dyn FnOnce(MonitorResult) + Send>,
}

struct MonitorInner {
    requests: HashMap<String, MonitorRequest>,
    stopped: bool,
    worker_running: bool,
}

pub struct ProcessMonitor {
    interval: Duration,
    snapshot: SnapshotFn,
    inner: Arc<Mutex<MonitorInner>>,
}

impl ProcessMonitor {
    pub fn new() -> Self {
        Self::with_snapshot(Duration::from_millis(400), Arc::new(collect_sysinfo_snapshot))
    }

    pub fn with_snapshot(interval: Duration, snapshot: SnapshotFn) -> Self {
        Self {
            interval: interval.max(Duration::from_millis(10)),
            snapshot,
            inner: Arc::new(Mutex::new(MonitorInner {
                requests: HashMap::new(),
                stopped: false,
                worker_running: false,
            })),
        }
    }

    pub fn add<F>(
        &self,
        id: String,
        project_path: &str,
        since_secs: u64,
        expected_command: Option<String>,
        timeout: Duration,
        completion: F,
    ) where
        F: FnOnce(MonitorResult) + Send + 'static,
    {
        let targets = build_targets(project_path);
        let deadline_ms = now_ms() + timeout.as_millis();
        let req = MonitorRequest {
            targets,
            since_secs,
            expected_command,
            deadline_ms,
            completion: Box::new(completion),
        };

        let should_spawn = {
            let mut inner = self.inner.lock().unwrap();
            if inner.stopped {
                return;
            }
            inner.requests.insert(id, req);
            // 立即在工作线程首检，由工作线程维护轮询周期
            if !inner.worker_running {
                inner.worker_running = true;
                true
            } else {
                false
            }
        };

        if should_spawn {
            let inner = self.inner.clone();
            let snapshot = self.snapshot.clone();
            let interval = self.interval;
            std::thread::spawn(move || {
                monitor_loop(inner, snapshot, interval);
            });
        }
    }

    pub fn cancel(&self, id: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.requests.remove(id);
    }

    pub fn shutdown(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.stopped = true;
        inner.requests.clear();
    }
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn monitor_loop(inner: Arc<Mutex<MonitorInner>>, snapshot: SnapshotFn, interval: Duration) {
    let mut first = true;
    loop {
        if !first {
            std::thread::sleep(interval);
        }
        first = false;

        let active = {
            let mut guard = inner.lock().unwrap();
            if guard.stopped || guard.requests.is_empty() {
                guard.worker_running = false;
                return;
            }
            true
        };
        if !active {
            return;
        }

        let procs = snapshot();
        let now = now_ms();

        let callbacks: Vec<(Box<dyn FnOnce(MonitorResult) + Send>, MonitorResult)> = {
            let mut guard = inner.lock().unwrap();
            if guard.stopped || guard.requests.is_empty() {
                guard.worker_running = false;
                return;
            }

            let mut matched_ids: Vec<String> = Vec::new();
            for proc_rec in &procs {
                let Some(raw_cwd) = &proc_rec.cwd else {
                    continue;
                };
                let cwd_norm = normalize_cwd_for_compare(raw_cwd);
                for (req_id, req) in &guard.requests {
                    if matched_ids.contains(req_id) {
                        continue;
                    }
                    // 允许 1 秒时钟/粒度余量（对齐 Swift）
                    if proc_rec.start_secs + 1 < req.since_secs {
                        continue;
                    }
                    if !req.targets.contains(&cwd_norm) {
                        continue;
                    }
                    let exe_path = proc_rec.exe.as_deref().map(Path::new);
                    if !matches_command(
                        req.expected_command.as_deref(),
                        &proc_rec.name,
                        exe_path,
                        &proc_rec.cmd,
                    ) {
                        continue;
                    }
                    matched_ids.push(req_id.clone());
                }
            }

            let mut out = Vec::new();
            for id in matched_ids {
                if let Some(req) = guard.requests.remove(&id) {
                    out.push((req.completion, MonitorResult::Running));
                }
            }

            let expired_ids: Vec<String> = guard
                .requests
                .iter()
                .filter(|(_, req)| now >= req.deadline_ms)
                .map(|(id, _)| id.clone())
                .collect();
            for id in expired_ids {
                if let Some(req) = guard.requests.remove(&id) {
                    out.push((req.completion, MonitorResult::TimedOut));
                }
            }

            out
        };

        for (cb, res) in callbacks {
            cb(res);
        }

        let mut guard = inner.lock().unwrap();
        if guard.stopped || guard.requests.is_empty() {
            guard.worker_running = false;
            return;
        }
    }
}

fn collect_sysinfo_snapshot() -> Vec<ProcRecord> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing()
            .with_cwd(UpdateKind::Always)
            .with_cmd(UpdateKind::Always)
            .with_exe(UpdateKind::Always),
    );
    sys.processes()
        .values()
        .map(|p| ProcRecord {
            start_secs: p.start_time(),
            cwd: p.cwd().map(|d| d.to_string_lossy().into_owned()),
            name: p.name().to_string_lossy().into_owned(),
            exe: p.exe().map(|e| e.to_string_lossy().into_owned()),
            cmd: p
                .cmd()
                .iter()
                .map(|s| s.to_string_lossy().into_owned())
                .collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn cwd_normalization_and_identity_matching() {
        assert_eq!(
            normalize_cwd_for_compare(r"C:\Users\Demo\Proj\"),
            r"c:\users\demo\proj"
        );
        assert_eq!(
            normalize_cwd_for_compare(r"\\?\C:\Users\Demo\Proj\"),
            r"c:\users\demo\proj"
        );
        assert_eq!(normalize_cwd_for_compare(r"c:\"), r"c:\");
        assert_eq!(normalize_cwd_for_compare(r"\\?\UNC\nas\share\a\"), r"\\nas\share\a");

        // Windows pi：node.exe 跑 pi-coding-agent 或 pi-launcher.js
        assert!(matches_command(
            Some("pi"),
            "node.exe",
            Some(Path::new(r"C:\Program Files\nodejs\node.exe")),
            &[
                r"C:\Program Files\nodejs\node.exe".into(),
                r"C:\Users\u\.pi\agent\install\node_modules\@earendil-works\pi-coding-agent\dist\cli.js".into(),
            ]
        ));
        assert!(matches_command(
            Some("pi"),
            "node.exe",
            Some(Path::new(r"C:\Users\u\AppData\Local\pi-node\current\node.exe")),
            &[
                "node.exe".into(),
                r"C:\Users\u\.pi\agent\bin\pi-launcher.js".into(),
            ]
        ));
        // 包装 cmd.exe 不算 pi
        assert!(!matches_command(
            Some("pi"),
            "cmd.exe",
            Some(Path::new(r"C:\Windows\System32\cmd.exe")),
            &["cmd.exe".into(), "/c".into(), "pi".into()]
        ));
    }

    #[test]
    fn monitor_matches_and_times_out_cleanly() {
        let now = now_secs();
        let dir = r"C:\Work\项目 A";
        let snapshot: SnapshotFn = Arc::new(move || {
            vec![ProcRecord {
                start_secs: now,
                cwd: Some(r"c:\work\项目 a\".into()),
                name: "node.exe".into(),
                exe: Some(r"C:\nodejs\node.exe".into()),
                cmd: vec![
                    "node.exe".into(),
                    r"C:\Users\x\.pi\agent\bin\pi-launcher.js".into(),
                ],
            }]
        });
        let monitor = ProcessMonitor::with_snapshot(Duration::from_millis(20), snapshot);
        let (tx, rx) = mpsc::channel();
        monitor.add(
            "r1".into(),
            dir,
            now,
            Some("pi".into()),
            Duration::from_secs(2),
            move |res| {
                let _ = tx.send(res);
            },
        );
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(2)).unwrap(),
            MonitorResult::Running
        );
        monitor.shutdown();

        // 超时情况
        let empty: SnapshotFn = Arc::new(Vec::new);
        let m2 = ProcessMonitor::with_snapshot(Duration::from_millis(20), empty);
        let (tx2, rx2) = mpsc::channel();
        m2.add(
            "r2".into(),
            dir,
            now,
            Some("pi".into()),
            Duration::from_millis(80),
            move |res| {
                let _ = tx2.send(res);
            },
        );
        assert_eq!(
            rx2.recv_timeout(Duration::from_secs(2)).unwrap(),
            MonitorResult::TimedOut
        );
        m2.shutdown();
    }

    #[test]
    fn lifecycle_and_action_queue() {
        let guard = LifecycleGuard::new();
        let mut ran = 0;
        assert!(guard.perform_if_active(|| ran += 1));
        guard.shutdown();
        assert!(!guard.perform_if_active(|| ran += 1));
        assert_eq!(ran, 1);

        let mut q = ActionQueue::new();
        let count = Arc::new(Mutex::new(0));
        let c1 = count.clone();
        q.enqueue(move || *c1.lock().unwrap() += 1);
        assert_eq!(*count.lock().unwrap(), 0);
        for f in q.take_all() {
            f();
        }
        assert_eq!(*count.lock().unwrap(), 1);
        q.close();
        let c2 = count.clone();
        q.enqueue(move || *c2.lock().unwrap() += 10);
        assert!(q.take_all().is_empty());
        assert_eq!(*count.lock().unwrap(), 1);
    }
}
