/* PI 项目启动器 · v3 界面层
 *
 * 两个宿主共用这一份界面：
 *   Mac 版  → WKWebView，桥是 window.webkit.messageHandlers.launcher
 *   Win 版  → Tauri 2 / WebView2，桥是 window.__TAURI__.core.invoke("message")
 * 差别只在 post() 一处与 platform-win 那层样式，其余逻辑两边完全一致。
 *
 * 与原生（Swift / Rust）的契约：
 *   window.__render({ projects, terminals, status, statusTone, statusPhase,
 *                     statusScope, statusProject, statusRequestID,
 *                     statusOrigin, pageID, snapshot, activeRequests,
 *                     statusReplay, home }) ← 原生推数据
 *   window.__history({ project, sessions, error, ticket })     ← 原生推会话列表
 *   window.__toast(message)                                    ← 原生推提示
 *   window.__focusSearch()                                     ← 窗口唤起时聚焦搜索
 *   window.launcher.open(id, mode, requestId)   mode = "continue" | "new"
 *   window.launcher.toggleFavorite(id) · window.launcher.history(id)
 *   window.launcher.resume(id, session, requestId) · window.launcher.remove(id)
 *   window.launcher.pickFolder(then)  then = "favorite" | "open"
 *   window.launcher.quit()
 *   window.launcher.theme(value)      value = "day" | "night"（原生据此改窗口底色）
 *
 * 原生是唯一事实来源；这里只负责渲染与上报意图。
 */
(function () {
  "use strict";

  var shell = document.getElementById("shell");
  var stack = document.getElementById("stack");
  var input = document.getElementById("q");
  var clearBtn = document.getElementById("clear");
  var statusEl = document.getElementById("status");
  var toastEl = document.getElementById("toast");
  var tplCard = document.getElementById("tpl-card");
  var tplAdd = document.getElementById("tpl-add");
  var tplSession = document.getElementById("tpl-session");
  var historyEl = document.getElementById("history");
  var hlist = document.getElementById("hlist");
  var htitle = document.getElementById("htitle");
  var hpath = document.getElementById("hpath");
  var hcount = document.getElementById("hcount");
  var hqInput = document.getElementById("hq");
  var hclearBtn = document.getElementById("hclear");
  var hback = document.getElementById("hback");
  var hnew = document.getElementById("hnew");
  var keysProjects = document.getElementById("keys-projects");
  var keysSplit = document.getElementById("keys-split");

  /* ── 平台判定 ─────────────────────────────────────
   * 有 __TAURI__ 就是 Windows 外壳；否则仍是 Mac 的 WKWebView。
   * 只有这里分流，后面全部共用。 */
  var IS_WIN = !!(window.__TAURI__ && window.__TAURI__.core);
  if (IS_WIN) document.documentElement.classList.add("platform-win");
  var TERM_LABEL = IS_WIN ? "Windows Terminal" : "Ghostty";
  var REOPEN_HINT = IS_WIN ? "从开始菜单再打开" : "从 Dock 再打开";
  var MOD_LABEL = IS_WIN ? "Ctrl+" : "⌘";

  /** 修饰键：Mac 认 ⌘，Windows 认 Ctrl */
  function modKey(e) { return IS_WIN ? e.ctrlKey : e.metaKey; }

  var state = {
    home: "",
    projects: [],
    query: "",
    view: "projects",
    // 当前键盘落在哪一栏：左栏项目 / 右匣会话
    activePane: "projects",
    // 右匣的会话筛选词，与左栏项目筛选完全独立
    hquery: "",
    history: { project: null, sessions: [], ready: false, error: null, ticket: 0 },
    historyTicket: 0,
    // 底栏当前所处的相：start | done | error（见 setStatus）
    statusPhase: "start",
    statusRequestID: null,
    // 原生检测到的终端（已安装的，含未适配的），以及菜单是否展开
    terminals: [],
    termOpen: false,
    // 上次渲染的指纹：数据没变就不重绘（v3 修正：窗口失焦再回来不再重建列表）
    signature: ""
  };
  var savedProjectQuery = "";   // 进历史页前暂存项目筛选词
  var flat = [];                // 当前栏可键盘选中的元素，按 DOM 顺序
  var cursor = 0;
  var cursorByPane = { projects: 0, history: 0 };
  var scrollMemory = { projects: 0, history: 0 };

  /* ── 原生桥 ─────────────────────────────────────── */

  function post(action, payload) {
    var body = Object.assign({ action: action }, payload || {});
    try {
      if (IS_WIN) {
        window.__TAURI__.core.invoke("message", { body: body });
        return;
      }
      window.webkit.messageHandlers.launcher.postMessage(body);
    } catch (err) {
      /* 浏览器里预览时降级为 no-op */
    }
  }

  var bridge = {
    open: function (id, mode, requestId) { post("open", { id: id, mode: mode || "new", requestId: requestId }); },
    history: function (id, ticket) { post("history", { id: id, ticket: ticket }); },
    resume: function (id, session, requestId) { post("resume", { id: id, session: session, requestId: requestId }); },
    toggleFavorite: function (id) { post("toggleFavorite", { id: id }); },
    remove: function (id) { post("remove", { id: id }); },
    pickFolder: function (then) {
      var action = then || "open";
      // 选目录后真要启动时，意图必须在 post 之前登记；取消不占用 30 秒计时。
      var requestId = action === "open" ? registerUnboundIntent("continue") : null;
      post("pickFolder", { then: action, requestId: requestId });
    },
    setTerminal: function (id) { post("setTerminal", { id: id }); },
    detectTerminals: function () { post("detectTerminals"); },
    quit: function () { post("quit"); },
    theme: function (value) { post("theme", { value: value }); }
  };
  window.launcher = bridge;

  /* ── 昼夜主题 ───────────────────────────────────────
   * <html data-theme="day|night"> 是唯一开关，CSS 只认这一个属性。
   * 首帧由 index.html <head> 的内联脚本定下来（早于样式绘制，不白闪）；
   * 这里负责：首次运行时把系统外观落盘、按钮切换、把结果同步给原生。
   * 两态：第一次跟随系统，之后一律手动。 */
  var THEME_KEY = "pi.launcher.theme";
  var themeBtn = document.getElementById("theme");

  function currentTheme() {
    return document.documentElement.dataset.theme === "night" ? "night" : "day";
  }

  function storedTheme() {
    try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; }
  }

  function applyTheme(theme, persist) {
    document.documentElement.dataset.theme = theme;
    if (themeBtn) themeBtn.setAttribute("aria-checked", theme === "night" ? "true" : "false");
    if (persist) {
      try { localStorage.setItem(THEME_KEY, theme); } catch (e) {}
    }
    bridge.theme(theme);
  }

  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      applyTheme(currentTheme() === "night" ? "day" : "night", true);
      themeBtn.focus();
    });
  }
  /* 第一次运行：把「跟随系统」得到的结果写回去，之后就只认手动选择 */
  applyTheme(currentTheme(), !storedTheme());

  /* ── 终端选择 ───────────────────────────────────────
   * 选项来自原生检测：只列已安装的，未适配的灰着、点不动。
   * 切换结果由原生写盘后回推，这里不做乐观更新。 */
  var termBtn = document.getElementById("term");
  var termMenu = document.getElementById("term-menu");
  var termName = document.getElementById("term-name");

  function currentTerminal() {
    return state.terminals.filter(function (t) { return t.selected; })[0] || null;
  }

  function renderTerminalLabel() {
    if (!termName) return;
    var current = currentTerminal();
    termName.textContent = current ? current.name : "终端";
    if (termBtn) termBtn.title = current ? "当前终端：" + current.name : "选择用哪个终端打开";
  }

  function renderTerminalMenu() {
    if (!termMenu) return;
    // 重绘会把焦点丢掉：菜单开着时把焦点还给当前项（比如菜单打开时重新检测终端会触发重绘）
    var hadFocus = state.termOpen && termMenu.contains(document.activeElement);
    termMenu.textContent = "";

    if (!state.terminals.length) {
      var none = document.createElement("p");
      none.className = "term__empty";
      none.textContent = "没有检测到可用的终端";
      termMenu.appendChild(none);
      return;
    }

    state.terminals.forEach(function (t) {
      var item = document.createElement("button");
      item.type = "button";
      item.className = "term__item";
      item.dataset.id = t.id;
      item.setAttribute("role", "menuitemradio");
      item.setAttribute("aria-checked", t.selected ? "true" : "false");
      if (!t.supported) item.setAttribute("aria-disabled", "true");

      var name = document.createElement("span");
      name.className = "term__item-name";
      name.textContent = t.name;
      item.appendChild(name);

      if (t.note) {
        var note = document.createElement("span");
        note.className = "term__item-note";
        note.textContent = t.note;
        item.appendChild(note);
      }

      var tag = document.createElement("span");
      tag.className = "term__item-tag";
      tag.textContent = !t.supported ? "未适配" : (t.selected ? "当前" : "");
      item.appendChild(tag);

      termMenu.appendChild(item);
    });

    // 重绘前焦点在菜单里：还给当前项，否则键盘选择会断掉
    if (hadFocus) {
      var items = termItems();
      var current = items.filter(function (el) { return el.getAttribute("aria-checked") === "true"; })[0];
      (current || items[0] || termMenu).focus();
    }
  }

  function termItems() {
    return termMenu ? Array.prototype.slice.call(termMenu.querySelectorAll(".term__item")) : [];
  }

  function openTermMenu() {
    if (!termMenu || state.termOpen) return;
    // 菜单打开时重新检测一次：运行期间装了 / 卸了终端，列表要跟着变
    bridge.detectTerminals();
    state.termOpen = true;
    renderTerminalMenu();
    termMenu.hidden = false;
    termBtn.setAttribute("aria-expanded", "true");
    // 键盘进来的话，焦点先落在当前项上
    var items = termItems();
    var current = items.filter(function (el) { return el.getAttribute("aria-checked") === "true"; })[0];
    (current || items[0] || termMenu).focus();
  }

  function closeTermMenu(refocus) {
    if (!termMenu || !state.termOpen) return;
    state.termOpen = false;
    termMenu.hidden = true;
    termBtn.setAttribute("aria-expanded", "false");
    if (refocus) termBtn.focus();
  }

  function moveTerm(delta) {
    var items = termItems();
    if (!items.length) return;
    var index = items.indexOf(document.activeElement);
    index = index < 0 ? 0 : (index + delta + items.length) % items.length;
    items[index].focus();
  }

  function chooseTerm(item) {
    if (!item || item.getAttribute("aria-disabled") === "true") return;
    closeTermMenu(true);
    if (item.getAttribute("aria-checked") === "true") return;
    bridge.setTerminal(item.dataset.id);
  }

  if (termBtn) {
    termBtn.addEventListener("click", function () {
      if (state.termOpen) closeTermMenu(false);
      else openTermMenu();
    });
  }
  if (termMenu) {
    termMenu.addEventListener("click", function (e) {
      chooseTerm(e.target.closest(".term__item"));
    });
  }
  /* 点菜单以外的地方收起；点的这一下照常生效，不吞掉 */
  document.addEventListener("mousedown", function (e) {
    if (!state.termOpen) return;
    if (e.target.closest("#term") || e.target.closest("#term-menu")) return;
    closeTermMenu(false);
  });

  /* ── 小工具 ─────────────────────────────────────── */

  /* 路径处理要认得两张台子的分隔符：Mac 是 `/`，Windows 是 `\`（还可能是 UNC 的 `\\server\share`） */
  function trimTrailing(p) {
    var s = String(p);
    // 盘符根（C:\）和 POSIX 根（/）要留着
    while (s.length > 3 && /[\/]$/.test(s)) s = s.slice(0, -1);
    if (s.length === 3 && /^[A-Za-z]:[\/]$/.test(s)) return s;
    return s;
  }

  function baseName(p) {
    var s = trimTrailing(p);
    var i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"));
    return i >= 0 ? s.slice(i + 1) || s : s;
  }

  function shortenPath(p) {
    var home = trimTrailing(state.home || "");
    var s = trimTrailing(p);
    // 只有 Windows 的路径不分大小写；Mac 卷可能分大小写，照原样逐字比较
    var hit = IS_WIN
      ? s.toLowerCase().indexOf(home.toLowerCase()) === 0
      : s.indexOf(home) === 0;
    if (home && hit) return "~" + s.slice(home.length);
    return s;
  }

  function matches(project, q) {
    if (!q) return true;
    var hay = (baseName(project.path) + " " + project.path).toLowerCase();
    return q.toLowerCase().split(/\s+/).every(function (t) {
      return t === "" || hay.indexOf(t) >= 0;
    });
  }

  /* 底栏状态：start 常驻（还没完），done 几秒后自己收，error 留到下一次操作 */
  var STATUS_TTL = { start: 0, done: 4000, error: 0 };
  var statusTimer = null;

  function setStatus(text, tone, phase, requestId) {
    state.statusPhase = phase || "start";
    state.statusRequestID = requestId || null;
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    statusEl.textContent = text || "";
    statusEl.dataset.tone = tone || "";

    var ttl = STATUS_TTL[state.statusPhase] || 0;
    if (text && ttl) {
      statusTimer = setTimeout(function () {
        statusTimer = null;
        statusEl.textContent = "";
        statusEl.dataset.tone = "";
      }, ttl);
    }
  }

  var toastTimer = null;
  function toast(message) {
    toastEl.textContent = message;
    toastEl.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.hidden = true; }, 5200);
  }

  var pad = function (n) { return (n < 10 ? "0" : "") + n; };

  function clockOf(d) { return pad(d.getHours()) + ":" + pad(d.getMinutes()); }

  /** 相对时间：今天/昨天/前天用词，更早用月日 */
  function relativeDay(ms) {
    if (!ms) return "";
    var d = new Date(ms);
    var now = new Date();
    var midnight = function (x) { return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime(); };
    var days = Math.round((midnight(now) - midnight(d)) / 864e5);
    if (days <= 0) return "今天 " + clockOf(d);
    if (days === 1) return "昨天 " + clockOf(d);
    if (days === 2) return "前天 " + clockOf(d);
    if (days < 30) return days + " 天前";
    return pad(d.getMonth() + 1) + "-" + pad(d.getDate());
  }

  /// 挂起态在卡片上的说法：面板选目录那种「不知道该开新的还是继续」的路由用「正在打开」
  function pendingLabel(mode) {
    if (mode === "new") return "正在开新会话";
    if (mode === "continue") return "正在继续上次";
    return "正在打开";
  }

  function sessionLabel(count) {
    if (!count) return "";
    return count + " 个旧会话";
  }

  /* ── 项目页渲染 ─────────────────────────────────── */

  function makeCard(project, index) {
    var node = tplCard.content.firstElementChild.cloneNode(true);
    var card = node.querySelector(".card");
    var open = node.querySelector(".card-open");
    var fav = node.querySelector(".tool--fav");
    var remove = node.querySelector(".tool--remove");
    var sessions = node.querySelector(".cell__sessions");
    var label = baseName(project.path);

    card.dataset.id = project.id;
    open.dataset.id = project.id;
    open.setAttribute("aria-label", "在 " + label + " 开新会话");
    open.title = "点击直接在此目录开新会话 · " + project.path;
    card.querySelector(".card__idx").textContent = index ? pad(index) : "";
    card.querySelector(".card__name").textContent = label;
    card.querySelector(".card__path").textContent = shortenPath(project.path);
    card.querySelector(".card__path").title = project.path;

    // 上行放日期（悬停时让位给右上工具）；下行放路径与旧会话胶囊
    var time = card.querySelector(".card__time");
    if (project.missing) {
      time.textContent = "路径失效";
      open.disabled = true;
      open.setAttribute("aria-label", label + " 的路径已失效");
      open.title = project.path + "（路径不存在）";
      card.classList.add("is-broken");
      card.querySelector(".card__ico use").setAttribute("href", "#i-warn");
      sessions.hidden = true;
    } else if (pendingOf(project.id)) {
      // 启动还在飞：卡片上的状态跟着 pending 走，重绘不会把它抹掉
      card.dataset.state = "loading";
      time.textContent = pendingLabel(pendingOf(project.id).mode);
    } else if (!project.sessionCount) {
      time.textContent = "还没有旧会话";
      card.classList.add("is-fresh");
      sessions.hidden = true;
    } else {
      time.textContent = relativeDay(project.lastActivity);
      var inspecting = state.history.project === project.id;
      node.classList.add("has-sessions");
      sessions.dataset.id = project.id;
      sessions.querySelector(".cell__sessions-label").textContent = sessionLabel(project.sessionCount);
      // 窄窗只留条数，胶囊收窄到一半，不压住卡片中段
      sessions.querySelector(".cell__sessions-short").textContent = project.sessionCount + " 条";
      sessions.setAttribute("aria-expanded", inspecting ? "true" : "false");
      sessions.setAttribute("aria-label",
        (inspecting ? "收起" : "在右侧查看") + label + " 的" + sessionLabel(project.sessionCount));
      if (inspecting) node.classList.add("is-inspecting");
    }

    fav.dataset.id = project.id;
    fav.setAttribute("aria-pressed", project.favorite ? "true" : "false");
    fav.setAttribute("aria-label", (project.favorite ? "取消常用：" : "设为常用：") + label);

    // 移除只对「最近」开放：常用项要降级请先取消星标
    if (project.favorite) {
      remove.hidden = true;
    } else {
      remove.dataset.id = project.id;
      remove.setAttribute("aria-label", "从最近项目里移除：" + label);
    }

    return node;
  }

  /* opts: { add: 在分组头摆「+ 添加」入口, hollow: 空组时留一条提示行 } */
  function makeGroup(title, projects, mod, start, opts) {
    opts = opts || {};
    var group = document.createElement("section");
    group.className = "group group--" + mod;

    var head = document.createElement("h2");
    head.className = "group__head";

    var label = document.createElement("span");
    label.className = "group__label";
    label.textContent = title;
    head.appendChild(label);

    var count = document.createElement("span");
    count.className = "group__count";
    count.textContent = projects.length + " 个";
    head.appendChild(count);

    if (opts.add) {
      var add = document.createElement("button");
      add.type = "button";
      add.className = "group__add";
      add.title = "选择一个文件夹加入常用项目";
      add.innerHTML = '<svg class="icon" aria-hidden="true"><use href="#i-plus"/></svg><span>添加</span>';
      add.addEventListener("click", function (e) {
        e.stopPropagation();
        bridge.pickFolder("favorite");
      });
      head.appendChild(add);
    }
    group.appendChild(head);

    if (projects.length) {
      var grid = document.createElement("div");
      grid.className = "grid";
      projects.forEach(function (p, i) { grid.appendChild(makeCard(p, start + i)); });
      group.appendChild(grid);
    } else if (opts.hollow) {
      var hollow = document.createElement("p");
      hollow.className = "group__hollow";
      hollow.innerHTML =
        '<svg class="icon" aria-hidden="true"><use href="#i-star"/></svg>' +
        '<span>还没有常用项目 · 点上面的「添加」，或悬停卡片点 ☆</span>';
      group.appendChild(hollow);
    }
    return group;
  }

  function introBlock() {
    var el = document.createElement("div");
    el.className = "intro";
    el.innerHTML =
      '<span class="intro__mark"><svg class="icon" aria-hidden="true"><use href="#i-terminal"/></svg></span>' +
      '<h2 class="intro__title">还没有项目</h2>' +
      '<p class="intro__hint">选一个文件夹，就在 ' + TERM_LABEL + ' 新窗口里用这个目录启动 PI。之后它会一直在这里等着。</p>' +
      '<ol class="intro__steps">' +
      '<li><b>1</b><span>点列表末尾的「选择文件夹并打开」，选一个项目目录</span></li>' +
      '<li><b>2</b><span>' + TERM_LABEL + ' 里直接就是 PI，不用再 cd</span></li>' +
      '<li><b>3</b><span>关掉窗口就退出；下次' + REOPEN_HINT + '</span></li>' +
      '</ol>' +
      '<p class="intro__keys"><span>↑↓ 选择</span><span>↵ 开新会话</span><span>' + MOD_LABEL + '↵ 继续上次</span><span>' + MOD_LABEL + 'F 搜索</span></p>';
    return el;
  }

  function emptyBlock(q) {
    var el = document.createElement("div");
    el.className = "empty";
    el.innerHTML =
      '<svg class="empty__ico icon" aria-hidden="true"><use href="#i-empty"/></svg>' +
      '<h2 class="empty__title">没有匹配项</h2>' +
      '<p class="empty__hint"></p>';
    el.querySelector(".empty__hint").textContent =
      "没有名称或路径包含 “" + q + "” 的项目。按 ESC 清除筛选，或点「选择文件夹并打开」。";
    return el;
  }

  function renderProjects() {
    var q = state.query.trim();
    var visible = state.projects.filter(function (p) { return matches(p, q); });

    var favorites = visible.filter(function (p) { return p.favorite; });
    var recents = visible.filter(function (p) { return !p.favorite; });

    stack.textContent = "";

    if (state.projects.length === 0) {
      stack.appendChild(introBlock());
    } else if (visible.length === 0) {
      stack.appendChild(emptyBlock(q));
    } else {
      // 「常用项目」分组常驻：它的分组头就是添加常用项目唯一常驻入口
      stack.appendChild(makeGroup("常用项目", favorites, "fav", 1, { add: true, hollow: true }));
      if (recents.length) stack.appendChild(makeGroup("最近项目", recents, "rec", favorites.length + 1));
    }

    // 列表末尾的打开入口：空项目、搜索有结果/无结果都保留，且只出现一次。
    var addGrid = document.createElement("div");
    addGrid.className = "grid grid--add";
    addGrid.appendChild(tplAdd.content.firstElementChild.cloneNode(true));
    stack.appendChild(addGrid);

    syncFlat();
  }

  /* ── 历史页 ─────────────────────────────────────── */

  function sessionRows() {
    return Array.prototype.slice.call(hlist.querySelectorAll(".srow"));
  }

  function openHistory(id) {
    // 已经开着同一个项目：再点胶囊就是收起
    if (state.view === "history" && state.history.project === id) { closeHistory(); return; }
    if (!stack.hidden) scrollMemory.projects = stack.scrollTop;
    state.view = "history";
    state.activePane = "history";
    // ticket 自增：同一项目连点两次时，先发的慢响应不会覆盖后发的结果
    state.historyTicket += 1;
    state.history = { project: id, sessions: [], ready: false, error: null, ticket: state.historyTicket };
    // 右匣有自己独立的筛选词，进来时清空
    state.hquery = "";
    hqInput.value = "";
    hclearBtn.hidden = true;
    cursorByPane.history = 0;
    cursor = 0;
    bridge.history(id, state.historyTicket);
    render();
  }

  function closeHistory() {
    if (!hlist.hidden) scrollMemory.history = hlist.scrollTop;
    state.view = "projects";
    state.activePane = "projects";
    // 清掉项目标记：还在飞的会话列表响应回来后不再影响左侧卡片
    state.history.project = null;
    state.history.ready = false;
    state.hquery = "";
    hqInput.value = "";
    hclearBtn.hidden = true;
    render();
    input.focus();
  }

  /* 栏位与底栏提示：单栏时只显示项目，展开后左右并存 */
  function syncPanes() {
    var split = state.view === "history";
    shell.classList.toggle("is-split", split);
    historyEl.hidden = !split;
    keysProjects.hidden = split;
    keysSplit.hidden = !split;
    input.placeholder = split ? "筛选左侧项目…" : "输入项目名或路径以筛选…";
  }

  function historyNotice(iconId, title, hint) {
    var el = document.createElement("div");
    el.className = "hempty";
    el.innerHTML =
      '<svg class="hempty__ico icon" aria-hidden="true"><use href="#' + iconId + '"/></svg>' +
      '<h3 class="hempty__title"></h3><p class="hempty__hint"></p>';
    el.querySelector(".hempty__title").textContent = title;
    el.querySelector(".hempty__hint").textContent = hint;
    return el;
  }

  function renderHistory() {
    var hist = state.history;
    var project = hist.project || "";
    var typed = state.hquery.trim();
    var q = typed.toLowerCase();
    var visible = hist.sessions.filter(function (s) {
      return !q || (s.title || "").toLowerCase().indexOf(q) >= 0;
    });

    htitle.textContent = baseName(project) || project;
    htitle.title = project;
    hpath.textContent = project ? shortenPath(project) : "";
    hpath.title = project;
    hcount.textContent = hist.ready ? hist.sessions.length + " 条" : "";

    hlist.textContent = "";
    if (hist.error) {
      hlist.appendChild(historyNotice("i-warn", "读取失败", hist.error));
    } else if (!hist.ready) {
      hlist.appendChild(historyNotice("i-clock", "正在读取…", "正在读取这个项目的会话记录。"));
    } else if (hist.sessions.length === 0) {
      hlist.appendChild(historyNotice("i-history", "暂无旧会话",
        "这个项目还没有可以继续的会话。点「开新会话」起一个，或按 ESC 收起右栏。"));
    } else if (visible.length === 0) {
      hlist.appendChild(historyNotice("i-empty", "没有匹配项",
        "没有会话标题包含 “" + typed + "”。按 ESC 清除筛选。"));
    } else {
      visible.forEach(function (s) {
        var row = tplSession.content.firstElementChild.cloneNode(true);
        row.dataset.session = s.path;
        row.title = s.title;
        row.querySelector(".srow__title").textContent = s.title;
        row.querySelector(".srow__time").textContent = relativeDay(s.modified);
        row.querySelector(".srow__count").textContent = s.messageCount ? s.messageCount + " 条" : "";
        hlist.appendChild(row);
      });
    }

    // 重绘后把「启动中」还回那一行：push 可能把列表整块重建
    var pendingSession = Object.keys(pending)
      .map(function (k) { return pending[k].session; })
      .filter(Boolean);
    if (pendingSession.length) {
      sessionRows().forEach(function (row) {
        if (pendingSession.indexOf(row.dataset.session) === -1) return;
        row.dataset.state = "loading";
        row.querySelector(".srow__time").textContent = "启动中";
      });
    }

    syncFlat();
  }

  function openSession(row) {
    if (!row || !state.history.project) return;
    var requestId = markPending(state.history.project, "continue", row.dataset.session);
    row.dataset.state = "loading";
    row.querySelector(".srow__time").textContent = "启动中";
    setStatus("正在继续这个会话…", undefined, "start", requestId);
    bridge.resume(state.history.project, row.dataset.session, requestId);
  }

  /* ── 键盘选中 ───────────────────────────────────── */

  /* 两栏各有自己的列表与游标；flat/cursor 始终指向当前栏 */
  function paneList(pane) {
    return pane === "history" ? sessionRows() : Array.prototype.slice.call(stack.querySelectorAll(".card"));
  }

  function syncFlat() {
    var pane = state.view === "history" && state.activePane === "history" ? "history" : "projects";
    if (pane === "history" && state.view !== "history") pane = "projects";
    flat = paneList(pane);
    cursor = cursorByPane[pane] || 0;
    if (cursor >= flat.length) cursor = Math.max(0, flat.length - 1);
    cursorByPane[pane] = cursor;
    paintSelection();
  }

  function setPane(pane) {
    if (state.view !== "history") pane = "projects";
    if (state.activePane === pane) return;
    state.activePane = pane;
    syncFlat();
  }

  function paintSelection() {
    // 清掉另一栏可能残留的选中：键盘只落在一栏上，不该两边同时高亮
    var other = state.activePane === "history" && state.view === "history"
      ? stack.querySelectorAll(".card")
      : hlist.querySelectorAll(".srow");
    Array.prototype.forEach.call(other, function (el) {
      el.classList.remove("is-selected");
      el.removeAttribute("aria-current");
    });

    flat.forEach(function (el, i) {
      el.classList.toggle("is-selected", i === cursor);
      if (i === cursor) el.setAttribute("aria-current", "true");
      else el.removeAttribute("aria-current");
    });
  }

  function move(delta) {
    if (!flat.length) return;
    cursor = (cursor + delta + flat.length) % flat.length;
    cursorByPane[state.activePane] = cursor;
    paintSelection();
    flat[cursor].scrollIntoView({ block: "nearest" });
  }

  function activate(forceContinue) {
    var el = flat[cursor];
    if (!el) return;
    if (state.view === "history" && state.activePane === "history") openSession(el);
    else openCard(el, forceContinue ? "continue" : "new");
  }

  /* ── 启动挂起态 ───────────────────────────────────
   * 点了之后、原生回话之前，卡片要一直显示 loading；这段状态不能存在 DOM 里——
   * refreshMeta 的推送会重绘列表。超过 PENDING_TIMEOUT 还没人回话就当失败。 */
  var PENDING_TIMEOUT = 30000;
  // 请求 ID 绑定本页代际与递增序号；时间不是权威。
  var pageID = "p" + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  var snapshotConsumedPageID = null;
  var requestSeq = 0;
  var pendingSeq = 0;
  var pending = {};              // requestId -> { id, mode, session, seq, order, pageID, timer }
  var unboundIntents = {};       // panel 选目录前登记；不启动 30 秒计时
  var latestLaunchState = {};    // project -> { pageID, order, settled }

  function newRequestId() {
    requestSeq += 1;
    return "launch-" + pageID + "-" + requestSeq;
  }

  function parseRequestId(requestId) {
    var match = /^launch-(p[^-]+)-(\d+)$/.exec(requestId || "");
    if (!match) return null;
    return { pageID: match[1], order: Number(match[2]) };
  }

  function registerUnboundIntent(mode) {
    var requestId = newRequestId();
    var meta = parseRequestId(requestId);
    unboundIntents[requestId] = {
      mode: mode || "continue",
      pageID: meta ? meta.pageID : null,
      order: meta ? meta.order : null
    };
    return requestId;
  }

  function pendingOf(projectId) {
    var latest = null;
    Object.keys(pending).forEach(function (key) {
      var item = pending[key];
      if (!item || item.id !== projectId) return;
      if (!latest || item.seq > latest.seq) latest = item;
    });
    return latest;
  }

  function hasPending() { return Object.keys(pending).length > 0; }

  function hasExplicitPending() {
    return Object.keys(pending).some(function (k) { return pending[k] && !pending[k].legacy; });
  }

  function noteLaunchState(project, meta, settled) {
    if (!project || !meta || meta.pageID !== pageID) return;
    var state = latestLaunchState[project];
    if (!state || meta.order > state.order) {
      latestLaunchState[project] = { pageID: pageID, order: meta.order, settled: settled };
    } else if (meta.order === state.order && settled) {
      state.settled = true;
    }
  }

  function retireProject(project) {
    if (!project) return;
    delete latestLaunchState[project];
    Object.keys(pending).forEach(function (key) {
      if (!pending[key] || pending[key].id !== project) return;
      clearTimeout(pending[key].timer);
      delete pending[key];
    });
  }

  // 只保留当前项目或仍在途的展示记录；pending 清掉后才可判断可回收。
  function pruneLaunchState() {
    var current = {};
    state.projects.forEach(function (p) { current[p.id] = true; });
    Object.keys(latestLaunchState).forEach(function (project) {
      if (!current[project] && !pendingOf(project)) delete latestLaunchState[project];
    });
  }

  function armPendingTimer(key) {
    var item = pending[key];
    if (!item) return;
    item.timer = setTimeout(function () {
      var current = pending[key];
      if (!current || current !== item) return;
      var meta = parseRequestId(key);
      noteLaunchState(current.id, meta, true);
      delete pending[key];
      // 同项目还有更新请求时不报旧请求失败，也不覆盖它的启动状态。
      if (!pendingOf(current.id)) {
        setStatus("没等到回应，请重试", "error", "error");
      }
      render();
    }, PENDING_TIMEOUT);
  }

  function markPending(id, mode, session, requestId, legacy) {
    var key = requestId || newRequestId();
    var meta = parseRequestId(key);
    var project = id || "";
    // 新请求取代同项目的旧挂起态：旧请求的计时器/loading 不再复活。
    Object.keys(pending).forEach(function (k) {
      if (pending[k] && pending[k].id === project) clearPending(k);
    });
    clearPending(key);
    delete unboundIntents[key];
    pendingSeq += 1;
    pending[key] = {
      id: id || "",
      mode: mode || "new",
      session: session || null,
      seq: pendingSeq,
      pageID: meta ? meta.pageID : null,
      order: meta ? meta.order : null,
      legacy: !!legacy,
      timer: null
    };
    // 新 intent 一登记就更新本项目的展示序号；旧 panel 即使新请求取消也不能复活。
    noteLaunchState(project, meta, false);
    armPendingTimer(key);
    return key;
  }

  /// 传 requestId 只清那一个；不传清全部（兼容旧调用）。
  function clearPending(requestId) {
    if (requestId === undefined) {
      Object.keys(pending).forEach(function (k) { clearTimeout(pending[k].timer); });
      pending = {};
      return;
    }
    if (!pending[requestId]) return;
    clearTimeout(pending[requestId].timer);
    delete pending[requestId];
  }

  /* ── 动作 ───────────────────────────────────────── */

  function openCard(hit, mode) {
    // hit 是铺满按钮；纸面本身是它的兄弟节点
    var paper = hit.closest(".cell").querySelector(".card");
    if (paper.classList.contains("is-broken") || hit.disabled) {
      toast("这个文件夹已不存在，请重新选择。");
      return;
    }
    var label = baseName(hit.dataset.id || "");
    var name = paper.querySelector(".card__name").textContent || label;

    var requestId = markPending(hit.dataset.id, mode);
    paper.dataset.state = "loading";
    paper.querySelector(".card__time").textContent =
      mode === "new" ? "正在开新会话" : "正在继续上次";
    setStatus("正在打开 " + name + "…", undefined, "start", requestId);
    bridge.open(hit.dataset.id, mode, requestId);
  }

  stack.addEventListener("click", function (e) {
    // 胶囊在卡片内部视觉上叠着，但事件目标优先：先判胶囊
    var sessions = e.target.closest(".cell__sessions");
    if (sessions) {
      e.stopPropagation();
      var owner = sessions.closest(".cell").querySelector(".card");
      if (owner.classList.contains("is-broken")) {
        toast("这个文件夹已不存在，请重新选择。");
        return;
      }
      openHistory(sessions.dataset.id);
      return;
    }
    var fav = e.target.closest(".tool--fav");
    if (fav) {
      e.stopPropagation();
      bridge.toggleFavorite(fav.dataset.id);
      return;
    }
    var remove = e.target.closest(".tool--remove");
    if (remove) {
      e.stopPropagation();
      retireProject(remove.dataset.id);
      if (state.history.project === remove.dataset.id) closeHistory();
      bridge.remove(remove.dataset.id);
      return;
    }
    // 点纸面＝直接开新会话，右栏开着也照旧。
    // 铺满按钮是真正的命中目标；合成点击（脚本／测试）落在纸面容器上时同样算数。
    var card = e.target.closest(".card-open") || e.target.closest(".card");
    if (card) {
      state.activePane = "projects";
      flat = paneList("projects");
      cursor = flat.indexOf(card);
      if (cursor < 0) cursor = 0;
      cursorByPane.projects = cursor;
      paintSelection();
      openCard(card, modKey(e) || e.altKey ? "continue" : "new");
      return;
    }
    // 列表末尾的入口：选目录并直接打开
    if (e.target.closest(".cell--add")) bridge.pickFolder("open");
  });

  hback.addEventListener("click", function () { closeHistory(); });
  hnew.addEventListener("click", function () {
    if (!state.history.project) return;
    var requestId = markPending(state.history.project, "new");
    setStatus("正在开新会话…", undefined, "start", requestId);
    bridge.open(state.history.project, "new", requestId);
  });
  hlist.addEventListener("click", function (e) {
    var row = e.target.closest(".srow");
    if (!row) return;
    state.activePane = "history";
    flat = sessionRows();
    cursor = flat.indexOf(row);
    if (cursor < 0) cursor = 0;
    cursorByPane.history = cursor;
    paintSelection();
    openSession(row);
  });

  input.addEventListener("focus", function () { setPane("projects"); });
  input.addEventListener("input", function () {
    state.query = input.value;
    clearBtn.hidden = input.value === "";
    cursorByPane.projects = 0;
    state.activePane = "projects";
    render();
  });

  clearBtn.addEventListener("click", function () {
    input.value = "";
    state.query = "";
    clearBtn.hidden = true;
    cursorByPane.projects = 0;
    input.focus();
    render();
  });

  hqInput.addEventListener("focus", function () { setPane("history"); });
  hqInput.addEventListener("input", function () {
    state.hquery = hqInput.value;
    hclearBtn.hidden = hqInput.value === "";
    cursorByPane.history = 0;
    state.activePane = "history";
    renderHistory();
  });

  hclearBtn.addEventListener("click", function () {
    hqInput.value = "";
    state.hquery = "";
    hclearBtn.hidden = true;
    hqInput.focus();
    renderHistory();
  });

  /* 两个选择目录的入口自己处理 Enter/空格，不能让全局激活再顺手开一次 */
  function isPickerEntry(el) {
    return !!(el && el.closest && el.closest(".cell--add, .group__add"));
  }

  /* 中文输入法候选确认也是 Enter：先放行正在组字的按键 */
  var lastCompositionEnd = null;
  document.addEventListener("compositionend", function (e) { lastCompositionEnd = e.timeStamp; });

  document.addEventListener("keydown", function (e) {
    if (e.isComposing || e.keyCode === 229 ||
        (lastCompositionEnd !== null && Math.abs(e.timeStamp - lastCompositionEnd) < 50)) return;

    var typing = document.activeElement === input || document.activeElement === hqInput;

    // 终端菜单开着时，键盘先归菜单
    if (state.termOpen) {
      if (e.key === "Escape") { closeTermMenu(true); e.preventDefault(); return; }
      if (e.key === "ArrowDown") { moveTerm(1); e.preventDefault(); return; }
      if (e.key === "ArrowUp") { moveTerm(-1); e.preventDefault(); return; }
      if (e.key === "Enter") { chooseTerm(document.activeElement); e.preventDefault(); return; }
    }

    // Tab 在左右栏之间切换（右匣开着才有意义）
    if (e.key === "Tab" && state.view === "history" && !e.metaKey && !e.ctrlKey && !e.altKey) {
      setPane(state.activePane === "history" ? "projects" : "history");
      if (state.activePane === "history") hqInput.focus();
      else input.focus();
      e.preventDefault();
      return;
    }

    if (e.key === "Escape") {
      // 有筛选就清当前栏的筛选，没有就收起右匣，再没有才退出应用。
      if (document.activeElement === hqInput && hqInput.value !== "") {
        hqInput.value = ""; state.hquery = ""; hclearBtn.hidden = true; renderHistory();
      } else if (document.activeElement === input && input.value !== "") {
        input.value = ""; state.query = ""; clearBtn.hidden = true; cursorByPane.projects = 0; render();
      } else if (state.view === "history") {
        closeHistory();
      } else if (state.query !== "") {
        state.query = ""; input.value = ""; clearBtn.hidden = true; cursorByPane.projects = 0; render();
      } else {
        bridge.quit();
      }
      e.preventDefault();
      return;
    }

    if (e.key === "ArrowDown" || (e.key === "n" && e.ctrlKey)) { move(1); e.preventDefault(); return; }
    if (e.key === "ArrowUp" || (e.key === "p" && e.ctrlKey)) { move(-1); e.preventDefault(); return; }
    if (e.key === "Enter") {
      // 选择目录的入口自己处理 Enter，不能让全局激活再开一次。
      if (isPickerEntry(document.activeElement)) return;
      activate(modKey(e) || e.altKey);
      e.preventDefault();
      return;
    }
    if (IS_WIN && e.key === "w" && e.ctrlKey) {
      bridge.quit();
      e.preventDefault();
      return;
    }
    if (e.key === "f" && modKey(e)) {
      var target = state.view === "history" && state.activePane === "history" ? hqInput : input;
      target.focus();
      target.select();
      e.preventDefault();
      return;
    }
  });

  /* 点空白处把焦点还给当前栏的搜索框，保证随时能直接打字 */
  stack.addEventListener("mousedown", function (e) {
    if (!e.target.closest(".card, .tool, .cell--add, .cell__sessions")) input.focus();
  });
  hlist.addEventListener("mousedown", function (e) {
    if (!e.target.closest(".srow")) hqInput.focus();
  });

  /* ── 渲染入口 ───────────────────────────────────── */

  function render() {
    // 两栏可以同时存在：左栏始终渲染，右匣只在展开时渲染
    if (!stack.hidden) scrollMemory.projects = stack.scrollTop;
    if (!hlist.hidden) scrollMemory.history = hlist.scrollTop;

    syncPanes();
    renderProjects();
    stack.scrollTop = scrollMemory.projects;

    if (state.view === "history") {
      renderHistory();
      hlist.scrollTop = scrollMemory.history;
    }
    syncFlat();
  }

  /** 数据指纹：内容相同就不重绘，避免失焦回来时列表重建、滚动跳顶 */
  function signatureOf(projects) {
    return projects.map(function (p) {
      return [p.id, p.favorite ? 1 : 0, p.missing ? 1 : 0,
              p.sessionCount || 0, Math.round((p.lastActivity || 0) / 60000)].join(":");
    }).join("|");
  }

  /* ── 原生接口 ───────────────────────────────────── */

  window.__render = function (payload) {
    payload = payload || {};
    // 普通推送带投递页面绑定；旧页面/旧快照直接丢弃（在改动任何界面状态之前）。
    if (typeof payload.pageID === "string" && payload.pageID !== pageID) return;
    if (payload.home) state.home = payload.home;

    if (Array.isArray(payload.terminals)) {
      state.terminals = payload.terminals.map(function (t) {
        return {
          id: t.id,
          name: t.name || t.id,
          note: t.note || "",
          supported: !!t.supported,
          selected: !!t.selected
        };
      });
      renderTerminalLabel();
      if (state.termOpen) renderTerminalMenu();
    }

    var hasProjects = Array.isArray(payload.projects);
    var projects = hasProjects ? payload.projects.map(function (p) {
      return {
        id: p.id || p.path,
        path: p.path,
        favorite: !!p.favorite,
        missing: !!p.missing,
        sessionCount: typeof p.sessionCount === "number" ? p.sessionCount : null,
        lastActivity: typeof p.lastActivity === "number" ? p.lastActivity : null
      };
    }) : state.projects.slice();

    var currentIds = {};
    projects.forEach(function (p) { currentIds[p.id] = true; });

    if (hasProjects) {
      var nextProjects = {};
      projects.forEach(function (p) { nextProjects[p.id] = true; });
      state.projects.forEach(function (p) {
        if (!nextProjects[p.id]) retireProject(p.id);
      });
      Object.keys(latestLaunchState).forEach(function (p) {
        if (!nextProjects[p] && !pendingOf(p)) delete latestLaunchState[p];
      });
    }

    var signature = signatureOf(projects);
    state.projects = projects;
    var finished = false;

    // 每个页面代际只消费一次快照导入权；首份绑定当前 pageID 的快照即消费，
    // 即使 activeRequests 为空。后续同页快照不能再导入或借 replay 覆盖状态。
    var boundSnapshot = payload.snapshot === true &&
      typeof payload.pageID === "string" && payload.pageID === pageID &&
      (payload.activeRequests === undefined || Array.isArray(payload.activeRequests));
    var snapshotPrivilege = boundSnapshot && snapshotConsumedPageID !== pageID;
    if (boundSnapshot) snapshotConsumedPageID = pageID;
    if (snapshotPrivilege && Array.isArray(payload.activeRequests)) {
      payload.activeRequests.forEach(function (active) {
        if (!active || typeof active.requestId !== "string" ||
            typeof active.project !== "string") return;
        var activeMeta = parseRequestId(active.requestId);
        if (!activeMeta) return;
        if (hasProjects && nextProjects[active.project] !== true) return;
        var existing = pendingOf(active.project);
        if (existing && existing.pageID === pageID && activeMeta.pageID !== pageID) return;
        if (existing && existing.pageID === activeMeta.pageID &&
            existing.order !== null && existing.order > activeMeta.order) return;
        var known = latestLaunchState[active.project];
        if (known && known.pageID === pageID) {
          if (activeMeta.pageID !== pageID) return;
          if (known.order > activeMeta.order ||
              (known.order === activeMeta.order && known.settled)) return;
        }
        if (!pending[active.requestId]) {
          if (activeMeta.pageID === pageID) {
            requestSeq = Math.max(requestSeq, activeMeta.order);
          }
          markPending(active.project, active.mode || "continue", null, active.requestId);
          finished = true;
        }
      });
    }

    if (typeof payload.status === "string") {
      // 原生没给 phase（旧调用点）时按色调推断：红字是失败，其余都是「已做完」
      var phase = payload.statusPhase === "start" || payload.statusPhase === "done" || payload.statusPhase === "error"
        ? payload.statusPhase
        : (payload.statusTone === "error" ? "error" : "done");
      var requestId = typeof payload.statusRequestID === "string" ? payload.statusRequestID : null;
      var meta = requestId ? parseRequestId(requestId) : null;
      var requestEntry = requestId ? pending[requestId] : null;
      var unbound = requestId ? unboundIntents[requestId] : null;
      var project = payload.statusProject || "";
      var latestForProject = project ? pendingOf(project) : null;
      var replay = payload.statusReplay === true;
      var isLaunch = payload.statusScope === "launch";
      var stateForProject = project ? latestLaunchState[project] : null;
      var order = meta ? meta.order : null;
      var projectCurrent = !!project && currentIds[project] === true;
      var projectBound = !requestEntry || (!!project && requestEntry.id === project);
      var unboundBound = !!unbound && !!meta &&
        unbound.pageID === meta.pageID && unbound.order === meta.order;

      // 登记正证：live pending 或当前页登记、尚未绑定的 panel 意图。
      // 只有登记才能接受普通 start；快照消息是唯一无需 live 登记的导入特权。
      var hasRegistration = !!requestEntry && projectBound;
      if (!hasRegistration && unbound) {
        hasRegistration = !!meta && meta.pageID === pageID &&
          unboundBound && !!project;
      }
      var startRegistered = phase === "start" && hasRegistration &&
        !!meta && (meta.pageID === pageID ||
          (snapshotPrivilege && !!requestEntry));
      var terminalRegistered = phase !== "start" && hasRegistration;
      var replayTerminal = isLaunch && replay && snapshotPrivilege && !!meta &&
        phase !== "start" && !requestEntry && !unbound && projectCurrent;
      var unregistered = isLaunch && !!requestId &&
        !(startRegistered || terminalRegistered || replayTerminal);
      var bindingMismatch = isLaunch && !!meta && (
        (!!requestEntry && !projectBound) ||
        (!!unbound && !unboundBound));

      // 无 ID 状态只隔离同项目的显式 pending；跨项目不能全局吞掉。
      var missingIdWithExplicit = isLaunch && !requestId &&
        ((!!latestForProject && !latestForProject.legacy) ||
         (!project && hasExplicitPending()));

      // requestId 里的页面代际是硬边界：旧页普通推送忽略；快照回放例外；
      // 已由快照导入的活跃请求允许旧页终态收尾。
      var pageMismatch = isLaunch && !!meta && meta.pageID !== pageID && !replay &&
        !(requestEntry && requestEntry.pageID === meta.pageID &&
          requestEntry.order === meta.order);

      var orderStale = isLaunch && !!meta && (
        (!!requestEntry && requestEntry.pageID === meta.pageID &&
         requestEntry.order !== null && order < requestEntry.order) ||
        (!!latestForProject && latestForProject.pageID === meta.pageID &&
         latestForProject.order !== null && order < latestForProject.order) ||
        (!requestEntry && !latestForProject && meta.pageID === pageID &&
         !!stateForProject && stateForProject.pageID === pageID &&
         (order < stateForProject.order ||
          (order === stateForProject.order && stateForProject.settled)))
      );

      // 快照回放只在活跃请求已导入时补状态；没有活跃记录的 start 不重建 loading。
      // 旧页终态只有在当前页没有更新请求/状态时才可作为最近状态出现。
      var replayStale = isLaunch && replay && !!meta && !requestEntry &&
        (phase === "start" ||
         (meta.pageID === pageID &&
          !!stateForProject && stateForProject.pageID === pageID &&
          (order < stateForProject.order ||
           (order === stateForProject.order && stateForProject.settled))) ||
         (meta.pageID !== pageID && (!!latestForProject || !!stateForProject)));

      var superseded = missingIdWithExplicit || bindingMismatch || unregistered ||
        pageMismatch || orderStale || replayStale;

      if (superseded) {
        // 只收匹配项目、且本轮确属旧终态的同一个请求；错误绑定/未知/已释放不动别人的 pending。
        if (requestEntry && projectBound && phase !== "start" && !replay) {
          clearPending(requestId);
          finished = true;
        }
        // 旧 panel 的合法意图已失去展示；丢掉它自己的 unbound，不碰新请求。
        if (unbound && unboundBound && meta && meta.pageID === pageID &&
            (phase !== "start" || orderStale)) {
          delete unboundIntents[requestId];
        }
      } else {
        // 只有登记正证或本次快照导入才推进页内序号；拒绝的消息不能先改序号。
        if (meta && meta.pageID === pageID && (hasRegistration || replayTerminal)) {
          requestSeq = Math.max(requestSeq, meta.order);
        }
        setStatus(payload.status, payload.statusTone, phase, requestId);
        if (isLaunch && meta && project) {
          noteLaunchState(project, meta, phase !== "start");
        }

        /* 只有「启动」这条线的终态才能撤掉卡片 loading。
         * 加常用、切终端、改星标也会推状态，它们跟启动无关，不能拿它们去清 pending——
         * 否则启动还在飞时点一下星标，卡片 loading 与 30 秒兜底就一起没了。 */
        if (isLaunch && phase === "start") {
          var starting = project;
          if (starting && requestId && !pending[requestId]) {
            // 合法 panel 首次绑定：转成 pending 后删除 unbound；已有快照导入则不重建计时。
            if (unbound) {
              markPending(starting, payload.statusMode || "open", null, requestId);
              finished = true;
            }
          } else if (starting && !requestId && !pendingOf(starting)) {
            markPending(starting, payload.statusMode || "open", null, null, true);
            finished = true;
          }
        }

        if (isLaunch && phase !== "start") {
          if (requestId) {
            // 只收自己的 pending；unbound 的 panel 错误终态只释放自己的登记。
            if (pending[requestId]) {
              finished = true;
              clearPending(requestId);
            } else if (unbound) {
              delete unboundIntents[requestId];
            }
          } else {
            var which = project;
            if (which) {
              // 只按项目清旧的无 ID 挂起态；显式 ID 挂起态不会被缺失 ID 的终态碰掉。
              var legacyForProject = Object.keys(pending).filter(function (k) {
                return pending[k] && pending[k].id === which && pending[k].legacy;
              });
              finished = legacyForProject.length > 0;
              legacyForProject.forEach(function (k) { clearPending(k); });
            } else {
              var legacyKeys = Object.keys(pending).filter(function (k) {
                return pending[k] && pending[k].legacy;
              });
              finished = legacyKeys.length > 0;
              legacyKeys.forEach(function (k) { clearPending(k); });
            }
          }
        }
      }
    }

    pruneLaunchState();

    // 数据没变、也没有卡片要复位时，不重绘
    if (signature === state.signature && state.view === "projects" && !finished) {
      return;
    }
    state.signature = signature;
    render();
  };

  window.__toast = function (message) { toast(message); };

  window.__history = function (payload) {
    payload = payload || {};
    // 迟到/串台/已被收起的响应直接丢弃
    if (state.view !== "history") return;
    if (payload.project && payload.project !== state.history.project) return;
    if (typeof payload.ticket === "number" && payload.ticket !== state.history.ticket) return;
    state.history = {
      project: payload.project || state.history.project,
      sessions: (payload.sessions || []).map(function (s) {
        return {
          path: s.path,
          title: s.title || "",
          modified: s.modified || 0,
          messageCount: typeof s.messageCount === "number" ? s.messageCount : 0
        };
      }),
      ready: !payload.error,
      error: payload.error || null,
      ticket: state.history.ticket
    };
    if (state.view === "history") render();
  };

  window.__focusSearch = function () {
    // 窗口唤起时聚焦左栏项目筛选；右匣的筛选只在用户 Tab 过去时才抢焦点
    if (state.view === "history" && state.activePane === "history") {
      hqInput.focus();
      hqInput.select();
      return;
    }
    input.focus();
    input.select();
  };

  /* 原生拖动层靠这个让位：标题栏左右两侧要留出多少。
   * 手抄常量两次已经对不上（原生 88 / CSS 20），所以改成每次问页面实测。 */
  window.__titlebarInsets = function () {
    var bar = document.querySelector(".bar");
    if (!bar) return null;
    // 左侧：红绿灯占住页内边距那一条，取 .bar 的实际 padding-left
    var left = parseFloat(getComputedStyle(bar).paddingLeft) || 84;
    var rightEdge = Infinity;
    Array.prototype.forEach.call(bar.querySelectorAll(".term, .switch, .win-controls"), function (el) {
      var rect = el.getBoundingClientRect();
      if (rect.width > 0) rightEdge = Math.min(rightEdge, rect.left);
    });
    if (!isFinite(rightEdge)) return null;
    return { left: Math.ceil(left), right: Math.ceil(window.innerWidth - rightEdge) + 2 };
  };

  /* 拖动层盖在网页上面，标题栏里的按下事件到不了页面；由原生转一手，把菜单收起来 */
  window.__dismissMenus = function () {
    if (state.termOpen) closeTermMenu(false);
  };

  // 原生收到 ready 后才投递与这个页面代际绑定的数据/回放。
  window.__intentReleased = function (requestId) {
    if (typeof requestId !== "string") return;
    delete unboundIntents[requestId];
    // 只回收这个旧请求自己的挂起态；真实开窗不受影响。
    if (pending[requestId]) {
      clearPending(requestId);
      pruneLaunchState();
      render();
    }
  };

  /* ── Windows：纸卡标题栏 + 自绘窗口键 ───────────────
   * 无边框窗口（decorations: false）拿不到系统标题栏，拖动靠 data-tauri-drag-region，
   * 双击最大化由 Tauri 的拖动层自己处理。Mac 版这段直接跳过。 */
  function initWindowChrome() {
    if (!IS_WIN) return;

    var bar = document.querySelector(".bar");
    if (bar) bar.setAttribute("data-tauri-drag-region", "");
    // 拖在标题文字上也要能拉动：属性只在事件目标本身上生效
    Array.prototype.forEach.call(document.querySelectorAll(".bar__title"), function (el) {
      el.setAttribute("data-tauri-drag-region", "");
    });

    function appWindow() {
      return window.__TAURI__.window.getCurrentWindow();
    }

    function bind(id, run) {
      var el = document.getElementById(id);
      if (!el) return;
      el.addEventListener("click", function () {
        try { run(appWindow()); } catch (err) { /* 窗口已关就没必要报错 */ }
      });
    }

    bind("win-min", function (w) { w.minimize(); });
    bind("win-max", function (w) { w.toggleMaximize(); });
    // 关闭走与 ESC / Ctrl+W 同一条路：原生先收尾再退出，不留在后台
    bind("win-close", function () { bridge.quit(); });

    // 底栏与引导的快捷键文案：⌘ → Ctrl+
    Array.prototype.forEach.call(document.querySelectorAll("kbd[data-mod]"), function (el) {
      el.textContent = MOD_LABEL + el.getAttribute("data-mod");
    });
  }
  initWindowChrome();

  render();
  post("ready", { pageID: pageID });
})();
