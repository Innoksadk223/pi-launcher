#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod history;
mod launcher;
mod probe;
mod store;
mod terminal;

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::window::Color;
use tauri::{AppHandle, Manager, RunEvent};
use tauri_plugin_dialog::DialogExt;

use crate::history::{Summary, SummaryCoordinator};
use crate::probe::{ActionQueue, LifecycleGuard, MonitorResult, ProcessMonitor};
use crate::terminal::TerminalKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StatusPhase {
    Start,
    Done,
    Error,
}

impl StatusPhase {
    fn as_str(self) -> &'static str {
        match self {
            StatusPhase::Start => "start",
            StatusPhase::Done => "done",
            StatusPhase::Error => "error",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StatusScope {
    Launch,
    Operation,
}

impl StatusScope {
    fn as_str(self) -> &'static str {
        match self {
            StatusScope::Launch => "launch",
            StatusScope::Operation => "operation",
        }
    }
}

#[derive(Debug, Clone)]
struct LastStatus {
    text: String,
    tone: Option<String>,
    phase: Option<StatusPhase>,
    scope: StatusScope,
    project: Option<String>,
    mode: Option<String>,
    request_id: Option<String>,
    origin: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LaunchIdentity {
    page_id: String,
    seq: u64,
}

#[derive(Debug, Clone)]
struct ActiveLaunch {
    project: String,
    mode: String,
    display_request_id: String,
}

#[derive(Default)]
struct PushArgs {
    status: Option<String>,
    tone: Option<String>,
    phase: Option<StatusPhase>,
    scope: Option<StatusScope>,
    project: Option<String>,
    mode: Option<String>,
    request_id: Option<String>,
    origin: Option<String>,
    snapshot: bool,
    replay: bool,
}

struct BridgeState {
    favorites: Vec<String>,
    recents: Vec<String>,
    meta: HashMap<String, Summary>,
    terminals: Vec<&'static TerminalKind>,
    selected_terminal: Option<&'static TerminalKind>,

    meta_generation: u64,
    meta_ready: bool,
    store_loaded: bool,
    terminals_loaded: bool,
    page_ready: bool,
    bootstrapped: bool,
    pending_actions: ActionQueue,
    fallback_notice: Option<String>,

    last_data_fingerprint: Option<String>,
    last_status_fingerprint: Option<String>,
    last_status: Option<LastStatus>,

    current_page_id: Option<String>,
    pending_snapshot: bool,
    active_launches: HashMap<String, ActiveLaunch>,
    latest_intent_by_path: HashMap<String, LaunchIdentity>,
    meta_requested: HashSet<String>,
    meta_replace_all_pending: bool,
    meta_request_version: u64,
    latest_launch_request: HashMap<String, String>,
    seq_gen: AtomicU64,
}

impl BridgeState {
    fn new() -> Self {
        Self {
            favorites: Vec::new(),
            recents: Vec::new(),
            meta: HashMap::new(),
            terminals: Vec::new(),
            selected_terminal: None,
            meta_generation: 0,
            meta_ready: false,
            store_loaded: false,
            terminals_loaded: false,
            page_ready: false,
            bootstrapped: false,
            pending_actions: ActionQueue::new(),
            fallback_notice: None,
            last_data_fingerprint: None,
            last_status_fingerprint: None,
            last_status: None,
            current_page_id: None,
            pending_snapshot: false,
            active_launches: HashMap::new(),
            latest_intent_by_path: HashMap::new(),
            meta_requested: HashSet::new(),
            meta_replace_all_pending: false,
            meta_request_version: 0,
            latest_launch_request: HashMap::new(),
            seq_gen: AtomicU64::new(1),
        }
    }

    fn next_fallback_key(&self) -> String {
        let n = self.seq_gen.fetch_add(1, Ordering::SeqCst);
        format!("anon-{n}")
    }

    fn launch_terminal(&self) -> &'static TerminalKind {
        self.selected_terminal
            .or_else(|| terminal::kind("wt"))
            .unwrap_or_else(|| &terminal::known()[0])
    }
}

struct AppBridge {
    app: AppHandle,
    state: Mutex<BridgeState>,
    summary_coordinator: SummaryCoordinator,
    process_monitor: ProcessMonitor,
    lifecycle: LifecycleGuard,
}

impl AppBridge {
    fn new(app: AppHandle) -> Self {
        let agent_dir = history::default_agent_dir();
        Self {
            app,
            state: Mutex::new(BridgeState::new()),
            summary_coordinator: SummaryCoordinator::new(agent_dir),
            process_monitor: ProcessMonitor::new(),
            lifecycle: LifecycleGuard::new(),
        }
    }

    fn start_preparation(self: &Arc<Self>) {
        if !self.lifecycle.is_active() {
            return;
        }

        // Store 在后台读取
        let bridge_bg = Arc::clone(self);
        std::thread::spawn(move || {
            let loaded = store::load();
            if !bridge_bg.lifecycle.is_active() {
                return;
            }
            {
                let mut st = bridge_bg.state.lock().unwrap();
                st.favorites = loaded.favorites;
                st.recents = loaded.recents;
                st.store_loaded = true;
            }
            bridge_bg.maybe_bootstrap();
        });

        // 终端检测
        {
            let mut st = self.state.lock().unwrap();
            let saved = terminal::saved_selection();
            let installed = terminal::installed();
            let (picked, fell_back) = terminal::resolve(saved.as_deref(), &installed);
            st.terminals = installed.clone();
            st.selected_terminal = picked;
            // 连一个能用的终端都没有：启动前就说清楚，不让用户点了卡片才失败
            if installed.is_empty() {
                st.fallback_notice = Some(
                    "没找到 Windows Terminal，请先在 Microsoft Store 安装".to_string(),
                );
            } else if fell_back {
                if let Some(kind) = picked {
                    let saved_name = saved
                        .as_deref()
                        .and_then(|id| terminal::kind(id).map(|k| k.name.to_string()).or(Some(id.to_string())))
                        .unwrap_or_else(|| "之前选的终端".to_string());
                    st.fallback_notice = Some(format!("没找到 {saved_name}，已用 {}", kind.name));
                }
            }
            st.terminals_loaded = true;
        }
        self.maybe_bootstrap();
    }

    fn page_became_ready(self: &Arc<Self>, page_id: &str) {
        if !self.lifecycle.is_active() || page_id.is_empty() {
            return;
        }
        let should_send_snapshot = {
            let mut st = self.state.lock().unwrap();
            let new_gen = match &st.current_page_id {
                Some(old) => old != page_id,
                None => true,
            };
            if !new_gen {
                return;
            }
            st.current_page_id = Some(page_id.to_string());
            st.page_ready = true;
            st.last_data_fingerprint = None;
            st.last_status_fingerprint = None;
            st.latest_intent_by_path.clear();
            st.pending_snapshot = true;
            st.bootstrapped
        };

        if should_send_snapshot {
            self.send_snapshot();
        } else {
            self.maybe_bootstrap();
        }
    }

    fn maybe_bootstrap(self: &Arc<Self>) {
        let queued = {
            let mut st = self.state.lock().unwrap();
            if !self.lifecycle.is_active()
                || st.bootstrapped
                || !st.store_loaded
                || !st.terminals_loaded
                || !st.page_ready
            {
                return;
            }
            st.bootstrapped = true;
            st.pending_actions.take_all()
        };
        self.send_snapshot();
        self.refresh_meta(None);
        for action in queued {
            action();
        }
    }

    fn when_ready<F: FnOnce() + Send + 'static>(self: &Arc<Self>, action: F) {
        if !self.lifecycle.is_active() {
            return;
        }
        let bootstrapped = {
            let mut st = self.state.lock().unwrap();
            if st.bootstrapped {
                true
            } else {
                st.pending_actions.enqueue(action);
                return;
            }
        };
        if bootstrapped {
            action();
        }
    }

    fn send_snapshot(self: &Arc<Self>) {
        let args = {
            let mut st = self.state.lock().unwrap();
            let snapshot = st.pending_snapshot;
            st.pending_snapshot = false;
            if let Some(last) = st.last_status.clone() {
                PushArgs {
                    status: Some(last.text),
                    tone: last.tone,
                    phase: last.phase,
                    scope: Some(last.scope),
                    project: last.project,
                    mode: last.mode,
                    request_id: last.request_id,
                    origin: last.origin,
                    snapshot,
                    replay: true,
                }
            } else if let Some(notice) = st.fallback_notice.clone() {
                PushArgs {
                    status: Some(notice),
                    phase: Some(StatusPhase::Done),
                    snapshot,
                    ..Default::default()
                }
            } else {
                PushArgs {
                    snapshot,
                    ..Default::default()
                }
            }
        };
        self.push(args);
    }

    fn refresh_meta(self: &Arc<Self>, requested: Option<Vec<String>>) {
        if !self.lifecycle.is_active() {
            return;
        }
        let (targets, version) = {
            let mut st = self.state.lock().unwrap();
            let replace_all =
                requested.is_none() || (!st.meta_ready && st.meta_requested.is_empty());
            let targets: Vec<String> = if replace_all {
                let mut list = st.favorites.clone();
                list.extend(st.recents.clone());
                list
            } else {
                requested.unwrap_or_default()
            };
            if targets.is_empty() {
                st.meta_request_version += 1;
                self.summary_coordinator.cancel_all();
                st.meta.clear();
                st.meta_requested.clear();
                st.meta_replace_all_pending = false;
                st.meta_ready = true;
                drop(st);
                self.push(PushArgs::default());
                return;
            }
            st.meta_request_version += 1;
            let version = st.meta_request_version;
            for t in &targets {
                st.meta_requested.insert(t.clone());
            }
            if replace_all {
                st.meta_replace_all_pending = true;
            }
            (targets, version)
        };

        let bridge = Arc::clone(self);
        self.summary_coordinator.request(&targets, move |snapshot| {
            if !bridge.lifecycle.is_active() {
                return;
            }
            let changed = {
                let mut st = bridge.state.lock().unwrap();
                if version != st.meta_request_version || snapshot.generation <= st.meta_generation {
                    return;
                }
                st.meta_generation = snapshot.generation;
                let applied = std::mem::take(&mut st.meta_requested);
                let replace = st.meta_replace_all_pending;
                st.meta_replace_all_pending = false;
                let current: HashSet<String> = st
                    .favorites
                    .iter()
                    .chain(st.recents.iter())
                    .map(|p| history::path_key(p))
                    .collect();
                history::apply_runtime_projection(
                    &mut st.meta,
                    &applied,
                    &snapshot.summaries,
                    replace,
                    &current,
                );
                st.meta_ready = true;
                true
            };
            if changed {
                bridge.push(PushArgs::default());
            }
        });
    }

    fn push(&self, args: PushArgs) {
        if !self.lifecycle.is_active() {
            return;
        }
        let scope = args.scope.unwrap_or(StatusScope::Operation);
        let has_status = args.status.is_some();

        let payload = {
            let mut st = self.state.lock().unwrap();
            reconcile_display_state_locked(&mut st);
            let Some(page_id) = st.current_page_id.clone() else {
                return;
            };

            let mut projects: Vec<Value> = Vec::new();
            let mut seen_fav_keys: HashSet<String> = HashSet::new();
            for p in &st.favorites {
                seen_fav_keys.insert(history::path_key(p));
                projects.push(build_project_item(p, true, &st.meta));
            }
            for p in &st.recents {
                if !seen_fav_keys.contains(&history::path_key(p)) {
                    projects.push(build_project_item(p, false, &st.meta));
                }
            }

            let terminals: Vec<Value> = st
                .terminals
                .iter()
                .map(|k| {
                    serde_json::json!({
                        "id": k.id,
                        "name": k.name,
                        "note": k.note,
                        "supported": k.supported,
                        "selected": st.selected_terminal.map(|s| s.id == k.id).unwrap_or(false),
                    })
                })
                .collect();

            let home = dirs::home_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();

            let mut data_map = serde_json::Map::new();
            data_map.insert("projects".into(), Value::Array(projects));
            data_map.insert("home".into(), Value::String(home));
            data_map.insert("terminals".into(), Value::Array(terminals));
            let data_fp = serde_json::to_string(&Value::Object(data_map.clone())).unwrap_or_default();

            let status_fp = format!(
                "{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}\x1f{}",
                args.status.as_deref().unwrap_or(""),
                args.tone.as_deref().unwrap_or(""),
                args.phase.map(|p| p.as_str()).unwrap_or(""),
                if has_status { scope.as_str() } else { "" },
                args.project.as_deref().unwrap_or(""),
                args.mode.as_deref().unwrap_or(""),
                args.request_id.as_deref().unwrap_or(""),
                args.origin.as_deref().unwrap_or(""),
                if args.replay { "1" } else { "0" }
            );

            if let Some(ref text) = args.status {
                st.last_status = Some(LastStatus {
                    text: text.clone(),
                    tone: args.tone.clone(),
                    phase: args.phase,
                    scope,
                    project: args.project.clone(),
                    mode: args.mode.clone(),
                    request_id: args.request_id.clone(),
                    origin: args.origin.clone(),
                });
            }

            let data_changed = st
                .last_data_fingerprint
                .as_ref()
                .map(|p| p != &data_fp)
                .unwrap_or(true);
            let status_changed = st
                .last_status_fingerprint
                .as_ref()
                .map(|p| p != &status_fp)
                .unwrap_or(true);
            if !data_changed && (!has_status || !status_changed) && !args.snapshot {
                return;
            }
            st.last_data_fingerprint = Some(data_fp);
            st.last_status_fingerprint = Some(status_fp);

            let mut full_map = data_map;
            full_map.insert("pageID".into(), Value::String(page_id));
            if let Some(s) = args.status {
                full_map.insert("status".into(), Value::String(s));
                full_map.insert("statusScope".into(), Value::String(scope.as_str().into()));
            }
            if let Some(t) = args.tone {
                full_map.insert("statusTone".into(), Value::String(t));
            }
            if let Some(ph) = args.phase {
                full_map.insert("statusPhase".into(), Value::String(ph.as_str().into()));
            }
            if let Some(pr) = args.project {
                full_map.insert("statusProject".into(), Value::String(pr));
            }
            if let Some(m) = args.mode {
                full_map.insert("statusMode".into(), Value::String(m));
            }
            if let Some(r) = args.request_id {
                full_map.insert("statusRequestID".into(), Value::String(r));
            }
            if let Some(o) = args.origin {
                full_map.insert("statusOrigin".into(), Value::String(o));
            }
            if args.replay {
                full_map.insert("statusReplay".into(), Value::Bool(true));
            }
            if args.snapshot {
                full_map.insert("snapshot".into(), Value::Bool(true));
                let active_arr = active_requests_payload_locked(&st);
                full_map.insert("activeRequests".into(), Value::Array(active_arr));
            }
            Value::Object(full_map)
        };

        self.eval_fn("window.__render", &payload);
    }

    fn toast(&self, msg: &str) {
        self.eval_fn("window.__toast", &Value::String(msg.to_string()));
    }

    fn push_history(
        &self,
        project: &str,
        sessions: &[history::SessionItem],
        error: Option<&str>,
        ticket: Option<i64>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        let mut map = serde_json::Map::new();
        map.insert("project".into(), Value::String(project.to_string()));
        map.insert(
            "sessions".into(),
            serde_json::to_value(sessions).unwrap_or_else(|_| Value::Array(Vec::new())),
        );
        if let Some(err) = error {
            map.insert("error".into(), Value::String(err.to_string()));
        }
        if let Some(tk) = ticket {
            map.insert("ticket".into(), serde_json::json!(tk));
        }
        self.eval_fn("window.__history", &Value::Object(map));
    }

    fn eval_fn<T: Serialize>(&self, fn_name: &str, arg: &T) {
        if !self.lifecycle.is_active() {
            return;
        }
        let Ok(json) = serde_json::to_string(arg) else {
            return;
        };
        let script = format!("{fn_name}({json});");
        let app = self.app.clone();
        let lifecycle = self.lifecycle.clone();
        let _ = self.app.run_on_main_thread(move || {
            if !lifecycle.is_active() {
                return;
            }
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.eval(&script);
            }
        });
    }

    fn handle_message(self: &Arc<Self>, body: Value) {
        let Some(action) = body.get("action").and_then(|v| v.as_str()) else {
            return;
        };
        match action {
            "open" | "continue" | "new" => {
                let Some(id) = body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
                    return;
                };
                let mode = body
                    .get("mode")
                    .and_then(|v| v.as_str())
                    .unwrap_or(action)
                    .to_string();
                let request_id = extract_request_id(&body);
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.open_project(&id, &mode, request_id, false));
            }
            "history" => {
                let Some(id) = body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
                    return;
                };
                let ticket = body.get("ticket").and_then(|v| v.as_i64());
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.load_history(&id, ticket));
            }
            "resume" => {
                let (Some(id), Some(session)) = (
                    body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()),
                    body.get("session").and_then(|v| v.as_str()).map(|s| s.to_string()),
                ) else {
                    return;
                };
                let request_id = extract_request_id(&body);
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.resume_session(&id, &session, request_id));
            }
            "toggleFavorite" => {
                let Some(id) = body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
                    return;
                };
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.toggle_favorite(&id));
            }
            "remove" => {
                let Some(id) = body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
                    return;
                };
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.remove_recent(&id));
            }
            "ready" => {
                if let Some(page_id) = body.get("pageID").and_then(|v| v.as_str()) {
                    self.page_became_ready(page_id);
                }
            }
            "pickFolder" => {
                let then = body
                    .get("then")
                    .and_then(|v| v.as_str())
                    .unwrap_or("open")
                    .to_string();
                let request_id = extract_request_id(&body);
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.pick_folder(&then, request_id));
            }
            "setTerminal" => {
                let Some(id) = body.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()) else {
                    return;
                };
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.choose_terminal(&id));
            }
            "detectTerminals" => {
                let bridge = Arc::clone(self);
                self.when_ready(move || bridge.detect_terminals());
            }
            "theme" => {
                let night = body.get("value").and_then(|v| v.as_str()) == Some("night");
                self.apply_window_theme(night);
            }
            "quit" => {
                self.shutdown();
                self.app.exit(0);
            }
            _ => {}
        }
    }

    fn apply_window_theme(&self, night: bool) {
        let color = if night {
            Color(18, 17, 12, 255)
        } else {
            Color(238, 232, 218, 255)
        };
        let app = self.app.clone();
        let _ = self.app.run_on_main_thread(move || {
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.set_background_color(Some(color));
            }
        });
    }

    fn open_project(
        self: &Arc<Self>,
        path: &str,
        mode: &str,
        request_id: Option<String>,
        announced: bool,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        let (launch_key, display, terminal) = {
            let mut st = self.state.lock().unwrap();
            let launch_key = request_id
                .clone()
                .unwrap_or_else(|| st.next_fallback_key());
            let display = should_display_locked(&st, path, request_id.as_deref());
            if !store::is_directory(path) {
                drop(st);
                if display {
                    self.toast("这个文件夹已不存在，请重新选择。");
                    self.push(PushArgs {
                        status: Some("打开失败：文件夹不在了".into()),
                        tone: Some("error".into()),
                        phase: Some(StatusPhase::Error),
                        scope: Some(StatusScope::Launch),
                        project: Some(path.into()),
                        request_id,
                        ..Default::default()
                    });
                } else if let Some(ref rid) = request_id {
                    self.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
                }
                return;
            }
            if display {
                if let Some(ident) = request_id.as_deref().and_then(parse_launch_identity) {
                    st.latest_intent_by_path.insert(path.to_string(), ident);
                    remove_active_launches_for_locked(&mut st, path);
                    st.active_launches.insert(
                        launch_key.clone(),
                        ActiveLaunch {
                            project: path.to_string(),
                            mode: mode.to_string(),
                            display_request_id: request_id.clone().unwrap_or_default(),
                        },
                    );
                }
                st.latest_launch_request
                    .insert(path.to_string(), launch_key.clone());
            } else if let Some(ref rid) = request_id {
                self.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
            }
            let terminal = st.launch_terminal();
            (launch_key, display, terminal)
        };

        if announced && display {
            let folder_name = Path::new(path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(path);
            self.push(PushArgs {
                status: Some(format!("正在打开 {folder_name}…")),
                phase: Some(StatusPhase::Start),
                scope: Some(StatusScope::Launch),
                project: Some(path.into()),
                mode: Some(mode.into()),
                request_id: request_id.clone(),
                origin: Some("panel".into()),
                ..Default::default()
            });
        }

        if mode == "new" {
            self.launch(
                path,
                None,
                LaunchIntent::New,
                terminal,
                &launch_key,
                request_id.as_deref(),
            );
            return;
        }

        let bridge = Arc::clone(self);
        let path_owned = path.to_string();
        std::thread::spawn(move || {
            let agent_dir = history::default_agent_dir();
            let session = history::latest(&path_owned, &agent_dir).map(|s| s.path);
            if !bridge.lifecycle.is_active() {
                return;
            }
            let intent = if session.is_some() {
                LaunchIntent::Latest
            } else {
                LaunchIntent::New
            };
            bridge.launch(
                &path_owned,
                session.as_deref(),
                intent,
                terminal,
                &launch_key,
                request_id.as_deref(),
            );
        });
    }

    fn launch(
        self: &Arc<Self>,
        path: &str,
        session: Option<&str>,
        intent: LaunchIntent,
        terminal: &'static TerminalKind,
        launch_key: &str,
        echo_request_id: Option<&str>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        let started_secs = probe::now_secs();
        if let Err(err) = launcher::open(path, session, terminal, "pi") {
            self.fail_launch(path, &err.to_string(), launch_key, echo_request_id);
            return;
        }
        match intent {
            LaunchIntent::New => {
                self.await_new_session(path, started_secs, terminal, launch_key, echo_request_id);
            }
            LaunchIntent::Latest => {
                self.complete_launch(path, "已继续上次会话", launch_key, echo_request_id);
            }
            LaunchIntent::Specific => {
                self.complete_launch(path, "已继续这个会话", launch_key, echo_request_id);
            }
        }
    }

    fn await_new_session(
        self: &Arc<Self>,
        path: &str,
        started_secs: u64,
        terminal: &'static TerminalKind,
        launch_key: &str,
        echo_request_id: Option<&str>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        self.note_recent(path);
        if !self.is_current_launch(path, launch_key) {
            self.release_display(path, echo_request_id);
            return;
        }
        self.push(PushArgs {
            status: Some(format!("已在 {} 开窗口，等 pi 起来…", terminal.name)),
            phase: Some(StatusPhase::Start),
            scope: Some(StatusScope::Launch),
            project: Some(path.into()),
            request_id: echo_request_id.map(|s| s.to_string()),
            ..Default::default()
        });

        let bridge = Arc::clone(self);
        let path_owned = path.to_string();
        let launch_key_owned = launch_key.to_string();
        let echo_owned = echo_request_id.map(|s| s.to_string());

        self.process_monitor.add(
            launch_key.to_string(),
            path,
            started_secs,
            Some("pi".to_string()),
            Duration::from_secs(12),
            move |res| {
                if !bridge.lifecycle.is_active() {
                    return;
                }
                match res {
                    MonitorResult::Running => {
                        bridge.complete_launch(
                            &path_owned,
                            "已开好新会话",
                            &launch_key_owned,
                            echo_owned.as_deref(),
                        );
                    }
                    MonitorResult::TimedOut => {
                        if !bridge.is_current_launch(&path_owned, &launch_key_owned) {
                            bridge.release_display(&path_owned, echo_owned.as_deref());
                            return;
                        }
                        bridge.push(PushArgs {
                            status: Some("已开窗口，但没等到 pi".into()),
                            phase: Some(StatusPhase::Done),
                            scope: Some(StatusScope::Launch),
                            project: Some(path_owned.clone()),
                            request_id: echo_owned.clone(),
                            ..Default::default()
                        });
                        bridge.clear_launch_request(&path_owned, &launch_key_owned);
                    }
                }
            },
        );
    }

    fn fail_launch(
        self: &Arc<Self>,
        path: &str,
        message: &str,
        launch_key: &str,
        echo_request_id: Option<&str>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        if !self.is_current_launch(path, launch_key) {
            self.release_display(path, echo_request_id);
            return;
        }
        self.toast(message);
        self.push(PushArgs {
            status: Some("打开失败".into()),
            tone: Some("error".into()),
            phase: Some(StatusPhase::Error),
            scope: Some(StatusScope::Launch),
            project: Some(path.into()),
            request_id: echo_request_id.map(|s| s.to_string()),
            ..Default::default()
        });
        self.clear_launch_request(path, launch_key);
    }

    fn complete_launch(
        self: &Arc<Self>,
        path: &str,
        status: &str,
        launch_key: &str,
        echo_request_id: Option<&str>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        self.note_recent(path);
        self.refresh_meta(Some(vec![path.to_string()]));
        if !self.is_current_launch(path, launch_key) {
            self.release_display(path, echo_request_id);
            return;
        }
        self.push(PushArgs {
            status: Some(status.to_string()),
            tone: Some("ok".into()),
            phase: Some(StatusPhase::Done),
            scope: Some(StatusScope::Launch),
            project: Some(path.into()),
            request_id: echo_request_id.map(|s| s.to_string()),
            ..Default::default()
        });
        self.clear_launch_request(path, launch_key);
    }

    fn is_current_launch(&self, path: &str, launch_key: &str) -> bool {
        let st = self.state.lock().unwrap();
        st.latest_launch_request
            .get(path)
            .map(|k| k == launch_key)
            .unwrap_or(false)
    }

    fn clear_launch_request(&self, path: &str, launch_key: &str) {
        let mut st = self.state.lock().unwrap();
        if st.latest_launch_request.get(path).map(|k| k == launch_key).unwrap_or(false) {
            st.latest_launch_request.remove(path);
        }
        st.active_launches.remove(launch_key);
        reconcile_display_state_locked(&mut st);
    }

    fn release_display(&self, path: &str, request_id: Option<&str>) {
        let Some(rid) = request_id else {
            return;
        };
        let display = {
            let st = self.state.lock().unwrap();
            should_display_locked(&st, path, Some(rid))
        };
        if !display {
            self.eval_fn("window.__intentReleased", &Value::String(rid.to_string()));
        }
    }

    fn note_recent(&self, path: &str) {
        if !self.lifecycle.is_active() {
            return;
        }
        let saved = {
            let mut st = self.state.lock().unwrap();
            st.recents = store::push_recent(path, &st.recents, store::MAX_RECENT);
            reconcile_display_state_locked(&mut st);
            store::save(&st.favorites, &st.recents)
        };
        if !saved {
            self.toast("已打开，但项目列表保存失败（下次可能不记录）。");
        }
    }

    fn load_history(self: &Arc<Self>, path: &str, ticket: Option<i64>) {
        if !self.lifecycle.is_active() {
            return;
        }
        if !store::is_directory(path) {
            self.push_history(path, &[], Some("这个文件夹已不存在。"), ticket);
            return;
        }
        let bridge = Arc::clone(self);
        let path_owned = path.to_string();
        std::thread::spawn(move || {
            if !bridge.lifecycle.is_active() {
                return;
            }
            let agent_dir = history::default_agent_dir();
            match history::list(&path_owned, &agent_dir) {
                Ok(items) => bridge.push_history(&path_owned, &items, None, ticket),
                Err(_) => bridge.push_history(&path_owned, &[], Some("读取会话列表失败。"), ticket),
            }
        });
    }

    fn resume_session(
        self: &Arc<Self>,
        path: &str,
        session: &str,
        request_id: Option<String>,
    ) {
        if !self.lifecycle.is_active() {
            return;
        }
        let (launch_key, terminal) = {
            let mut st = self.state.lock().unwrap();
            let launch_key = request_id
                .clone()
                .unwrap_or_else(|| st.next_fallback_key());
            let display = should_display_locked(&st, path, request_id.as_deref());
            if !store::is_directory(path) {
                drop(st);
                if display {
                    self.toast("这个文件夹已不存在，请重新选择。");
                    self.push(PushArgs {
                        status: Some("打开失败：文件夹不在了".into()),
                        tone: Some("error".into()),
                        phase: Some(StatusPhase::Error),
                        scope: Some(StatusScope::Launch),
                        project: Some(path.into()),
                        request_id,
                        ..Default::default()
                    });
                } else if let Some(ref rid) = request_id {
                    self.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
                }
                return;
            }
            if display {
                if let Some(ident) = request_id.as_deref().and_then(parse_launch_identity) {
                    st.latest_intent_by_path.insert(path.to_string(), ident);
                    remove_active_launches_for_locked(&mut st, path);
                    st.active_launches.insert(
                        launch_key.clone(),
                        ActiveLaunch {
                            project: path.to_string(),
                            mode: "continue".to_string(),
                            display_request_id: request_id.clone().unwrap_or_default(),
                        },
                    );
                }
                st.latest_launch_request
                    .insert(path.to_string(), launch_key.clone());
            } else if let Some(ref rid) = request_id {
                self.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
            }
            let terminal = st.launch_terminal();
            (launch_key, terminal)
        };

        let bridge = Arc::clone(self);
        let path_owned = path.to_string();
        let session_owned = session.to_string();
        std::thread::spawn(move || {
            let agent_dir = history::default_agent_dir();
            let verified = history::validated(&session_owned, &path_owned, &agent_dir);
            if !bridge.lifecycle.is_active() {
                return;
            }
            let Some(verified_path) = verified else {
                if !bridge.is_current_launch(&path_owned, &launch_key) {
                    bridge.release_display(&path_owned, request_id.as_deref());
                    return;
                }
                bridge.toast("这个会话已不可用，请返回历史列表重选。");
                bridge.push(PushArgs {
                    status: Some("这个会话已不可用".into()),
                    tone: Some("error".into()),
                    phase: Some(StatusPhase::Error),
                    scope: Some(StatusScope::Launch),
                    project: Some(path_owned.clone()),
                    request_id: request_id.clone(),
                    ..Default::default()
                });
                bridge.clear_launch_request(&path_owned, &launch_key);
                return;
            };
            bridge.launch(
                &path_owned,
                Some(&verified_path),
                LaunchIntent::Specific,
                terminal,
                &launch_key,
                request_id.as_deref(),
            );
        });
    }

    fn choose_terminal(&self, id: &str) {
        if !self.lifecycle.is_active() {
            return;
        }
        let Some(kind) = terminal::kind(id) else {
            return;
        };
        if !kind.supported {
            self.toast(&format!("{} 还不支持自动启动。", kind.name));
            self.push(PushArgs::default());
            return;
        }
        if !terminal::is_installed(kind) {
            self.toast(&format!("没找到 {}。", kind.name));
            self.push(PushArgs::default());
            return;
        }
        if !terminal::save_selection(kind.id) {
            self.toast("保存失败，终端没有切换。");
            self.push(PushArgs::default());
            return;
        }
        self.state.lock().unwrap().selected_terminal = Some(kind);
        self.push(PushArgs {
            status: Some(format!("已切换到 {}", kind.name)),
            tone: Some("ok".into()),
            phase: Some(StatusPhase::Done),
            ..Default::default()
        });
    }

    fn detect_terminals(&self) {
        if !self.lifecycle.is_active() {
            return;
        }
        let installed = terminal::installed();
        let notice = {
            let mut st = self.state.lock().unwrap();
            let prev = st.selected_terminal;
            st.terminals = installed.clone();
            if let Some(cur) = prev {
                if !installed.iter().any(|k| k.id == cur.id) {
                    let saved = terminal::saved_selection();
                    let (picked, _) = terminal::resolve(saved.as_deref(), &installed);
                    st.selected_terminal = picked;
                    picked.map(|p| format!("没找到 {}，已用 {}", cur.name, p.name))
                } else {
                    None
                }
            } else {
                None
            }
        };
        if let Some(msg) = notice {
            self.push(PushArgs {
                status: Some(msg),
                phase: Some(StatusPhase::Done),
                ..Default::default()
            });
        } else {
            self.push(PushArgs::default());
        }
    }

    fn pick_folder(self: &Arc<Self>, then: &str, request_id: Option<String>) {
        if !self.lifecycle.is_active() {
            return;
        }
        let title = if then == "favorite" {
            "选择要固定到常用区的项目文件夹"
        } else {
            "选择要用 PI 打开的项目文件夹"
        };
        let bridge = Arc::clone(self);
        let then_owned = then.to_string();
        let mut builder = self.app.dialog().file().set_title(title);
        if let Some(win) = self.app.get_webview_window("main") {
            builder = builder.set_parent(&win);
        }
        builder.pick_folder(move |picked| {
            if !bridge.lifecycle.is_active() {
                return;
            }
            let Some(file_path) = picked else {
                if let Some(ref rid) = request_id {
                    bridge.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
                }
                return;
            };
            let Ok(path_buf) = file_path.into_path() else {
                if let Some(ref rid) = request_id {
                    bridge.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
                }
                return;
            };
            let path_str = path_buf.to_string_lossy().into_owned();
            if then_owned == "favorite" {
                if let Some(ref rid) = request_id {
                    bridge.eval_fn("window.__intentReleased", &Value::String(rid.clone()));
                }
                bridge.add_favorite(&path_str);
            } else {
                let rid = request_id.unwrap_or_else(|| {
                    bridge.state.lock().unwrap().next_fallback_key()
                });
                bridge.open_project(&path_str, "continue", Some(rid), true);
            }
        });
    }

    fn add_favorite(self: &Arc<Self>, path: &str) {
        if !self.lifecycle.is_active() {
            return;
        }
        if !store::is_directory(path) {
            self.toast("这个文件夹已不存在，无法加入常用。");
            return;
        }
        let previously_recorded = {
            let mut st = self.state.lock().unwrap();
            let prev_rec = st
                .favorites
                .iter()
                .chain(st.recents.iter())
                .any(|p| history::path_key(p) == history::path_key(path));
            let res = store::adding_favorite(path, &st.favorites, &st.recents);
            if !res.added {
                drop(st);
                self.push(PushArgs {
                    status: Some("这个项目已经在常用里了".into()),
                    tone: Some("ok".into()),
                    ..Default::default()
                });
                return;
            }
            let prev_favs = st.favorites.clone();
            let prev_recs = st.recents.clone();
            st.favorites = res.favorites;
            st.recents = res.recents;
            if !store::save(&st.favorites, &st.recents) {
                st.favorites = prev_favs;
                st.recents = prev_recs;
                drop(st);
                self.toast("保存失败，没有加入常用。");
                self.push(PushArgs::default());
                return;
            }
            prev_rec
        };
        self.push(PushArgs {
            status: Some("已加入常用项目".into()),
            tone: Some("ok".into()),
            ..Default::default()
        });
        if !previously_recorded {
            self.refresh_meta(Some(vec![path.to_string()]));
        }
    }

    fn remove_recent(&self, path: &str) {
        if !self.lifecycle.is_active() {
            return;
        }
        let now_empty = {
            let mut st = self.state.lock().unwrap();
            if st.favorites.iter().any(|p| p == path) {
                drop(st);
                self.push(PushArgs {
                    status: Some("常用项目请先取消星标".into()),
                    tone: Some("ok".into()),
                    ..Default::default()
                });
                return;
            }
            let prev = st.recents.clone();
            let res = store::removing_recent(path, &st.favorites, &st.recents);
            st.recents = res.recents;
            if !store::save(&st.favorites, &st.recents) {
                st.recents = prev;
                drop(st);
                self.toast("保存失败，没有移除。");
                self.push(PushArgs::default());
                return;
            }
            st.meta.remove(path);
            self.summary_coordinator.remove(path);
            st.latest_intent_by_path.remove(path);
            st.latest_launch_request.remove(path);
            remove_active_launches_for_locked(&mut st, path);
            reconcile_display_state_locked(&mut st);
            st.favorites.is_empty() && st.recents.is_empty()
        };
        self.push(PushArgs {
            status: Some("已从最近项目里移除".into()),
            tone: Some("ok".into()),
            ..Default::default()
        });
        if now_empty {
            let mut st = self.state.lock().unwrap();
            st.meta_request_version += 1;
            self.summary_coordinator.cancel_all();
            st.meta.clear();
            st.meta_requested.clear();
            st.meta_replace_all_pending = false;
            st.meta_ready = true;
        }
    }

    fn toggle_favorite(&self, path: &str) {
        if !self.lifecycle.is_active() {
            return;
        }
        let made_fav = {
            let mut st = self.state.lock().unwrap();
            if !st.favorites.iter().any(|p| p == path) && !store::is_directory(path) {
                drop(st);
                self.toast("这个文件夹已不存在，无法设为常用。");
                return;
            }
            let res = store::toggling_favorite(path, &st.favorites, &st.recents);
            let prev_favs = st.favorites.clone();
            let prev_recs = st.recents.clone();
            st.favorites = res.favorites;
            st.recents = res.recents;
            if !store::save(&st.favorites, &st.recents) {
                st.favorites = prev_favs;
                st.recents = prev_recs;
                drop(st);
                self.toast("保存失败，改动未生效。");
                self.push(PushArgs::default());
                return;
            }
            res.made_favorite
        };
        self.push(PushArgs {
            status: Some(if made_fav {
                "已设为常用".into()
            } else {
                "已取消常用，保留在最近项目中".into()
            }),
            tone: Some("ok".into()),
            ..Default::default()
        });
    }

    fn shutdown(&self) {
        if !self.lifecycle.is_active() {
            return;
        }
        self.lifecycle.shutdown();
        {
            let mut st = self.state.lock().unwrap();
            st.pending_actions.close();
            st.meta_request_version += 1;
            st.meta_requested.clear();
            st.meta_replace_all_pending = false;
            st.latest_launch_request.clear();
            st.latest_intent_by_path.clear();
            st.active_launches.clear();
            st.current_page_id = None;
            st.pending_snapshot = false;
            st.fallback_notice = None;
            st.meta.clear();
        }
        self.summary_coordinator.shutdown();
        self.process_monitor.shutdown();
    }
}

#[derive(Debug, Clone, Copy)]
enum LaunchIntent {
    New,
    Latest,
    Specific,
}

fn extract_request_id(body: &Value) -> Option<String> {
    let raw = body.get("requestId").and_then(|v| v.as_str())?.trim();
    if raw.is_empty() {
        None
    } else {
        Some(raw.to_string())
    }
}

fn parse_launch_identity(request_id: &str) -> Option<LaunchIdentity> {
    let mut parts = request_id.split('-');
    let p0 = parts.next()?;
    let p1 = parts.next()?;
    let p2 = parts.next()?;
    if parts.next().is_some() || p0 != "launch" || !p1.starts_with('p') {
        return None;
    }
    let seq = p2.parse::<u64>().ok()?;
    Some(LaunchIdentity {
        page_id: p1.to_string(),
        seq,
    })
}

fn should_display_locked(st: &BridgeState, path: &str, request_id: Option<&str>) -> bool {
    let Some(rid) = request_id else {
        return true;
    };
    let Some(identity) = parse_launch_identity(rid) else {
        return true;
    };
    let Some(ref cur_page) = st.current_page_id else {
        return false;
    };
    if &identity.page_id != cur_page {
        return false;
    }
    if let Some(latest) = st.latest_intent_by_path.get(path) {
        if latest.page_id == identity.page_id && identity.seq < latest.seq {
            return false;
        }
    }
    true
}

fn remove_active_launches_for_locked(st: &mut BridgeState, path: &str) {
    st.active_launches.retain(|_, v| v.project != path);
}

fn reconcile_display_state_locked(st: &mut BridgeState) {
    let current: HashSet<String> = st
        .favorites
        .iter()
        .chain(st.recents.iter())
        .map(|p| history::path_key(p))
        .collect();
    let mut in_flight: HashSet<String> = st
        .latest_launch_request
        .keys()
        .map(|p| history::path_key(p))
        .collect();
    for active in st.active_launches.values() {
        in_flight.insert(history::path_key(&active.project));
    }
    st.latest_intent_by_path.retain(|path, _| {
        let key = history::path_key(path);
        current.contains(&key) || in_flight.contains(&key)
    });
}

fn active_requests_payload_locked(st: &BridgeState) -> Vec<Value> {
    let mut keys: Vec<&String> = st.active_launches.keys().collect();
    keys.sort();
    keys.into_iter()
        .filter_map(|k| st.active_launches.get(k))
        .map(|a| {
            serde_json::json!({
                "requestId": a.display_request_id,
                "project": a.project,
                "mode": a.mode,
            })
        })
        .collect()
}

fn build_project_item(path: &str, favorite: bool, meta: &HashMap<String, Summary>) -> Value {
    let mut item = serde_json::Map::new();
    item.insert("id".into(), Value::String(path.to_string()));
    item.insert("path".into(), Value::String(path.to_string()));
    item.insert("favorite".into(), Value::Bool(favorite));
    item.insert("missing".into(), Value::Bool(!store::is_directory(path)));

    let summary = meta.get(path).copied().or_else(|| {
        let target = history::path_key(path);
        meta.iter()
            .find(|(k, _)| history::path_key(k) == target)
            .map(|(_, v)| *v)
    });
    if let Some(sum) = summary {
        item.insert("sessionCount".into(), serde_json::json!(sum.count));
        if let Some(last) = sum.last_ms {
            item.insert("lastActivity".into(), serde_json::json!(last));
        }
    }
    Value::Object(item)
}

#[tauri::command]
fn message(bridge: tauri::State<'_, Arc<AppBridge>>, body: Value) {
    bridge.handle_message(body);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let bridge = Arc::new(AppBridge::new(app.handle().clone()));
            app.manage(bridge.clone());
            bridge.start_preparation();
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![message])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if matches!(event, RunEvent::Exit) {
                if let Some(bridge) = app.try_state::<Arc<AppBridge>>() {
                    bridge.shutdown();
                }
            }
        });
}
