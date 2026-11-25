// 用法：node tools/ui-probe.js [playwright 模块路径]
// Playwright 可能只装在 npx 缓存里，所以允许从参数或 PLAYWRIGHT_PATH 指过来。
function loadPlaywright() {
  const candidates = [process.argv[2], process.env.PLAYWRIGHT_PATH, 'playwright'].filter(Boolean);
  for (const c of candidates) {
    try { return require(c); } catch (e) { /* 下一个 */ }
  }
  const roots = require('child_process').execSync('ls -d ~/.npm/_npx/*/node_modules 2>/dev/null || true')
    .toString().trim().split('\n').filter(Boolean);
  for (const root of roots) {
    try { return require(root + '/playwright'); } catch (e) { /* 下一个 */ }
  }
  console.error('找不到 playwright 模块：传路径给第一个参数，或设置 PLAYWRIGHT_PATH');
  process.exit(2);
}
const { chromium } = loadPlaywright();
// 已安装的 Chromium：优先用环境变量，再退回本机缓存里任意一个
function findChrome() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const fs = require('fs');
  const base = require('os').homedir() + '/Library/Caches/ms-playwright';
  const dirs = fs.existsSync(base) ? fs.readdirSync(base).filter(d => d.startsWith('chromium-')) : [];
  for (const d of dirs) {
    const p = `${base}/${d}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
    if (fs.existsSync(p)) return p;
  }
  return undefined;   // 交给 playwright 自己找
}
const CHROME = findChrome();
// 页面地址跟着脚本走：仓库原件与 /tmp 冻结副本都能直接跑
const path = require('path');
const fsPath = require('fs');
const UI_DIR = process.env.UI_DIR || path.resolve(__dirname, '..', 'ui');
const URL = 'file://' + path.join(UI_DIR, 'index.html');

const results = [];
function check(label, ok, detail) { results.push({ label, ok, detail: detail === undefined ? '' : String(detail) }); }
function requestParts(id) {
  const match = /^launch-(p[^-]+)-(\d+)$/.exec(id || '');
  return match ? { pageID: match[1], seq: Number(match[2]) } : null;
}
function requestWithSeq(id, seq) {
  const parts = requestParts(id);
  return parts ? `launch-${parts.pageID}-${seq}` : null;
}

(async () => {
  const browser = await chromium.launch(CHROME ? { executablePath: CHROME } : {});
  const page = await browser.newPage({ viewport: { width: 780, height: 640 } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  // 在页面脚本之前装原生桥，只观察 ready/postMessage，不替换被测门面。
  await page.addInitScript(() => {
    window.__nativePosts = [];
    window.webkit = { messageHandlers: { launcher: { postMessage: m => window.__nativePosts.push(m) } } };
  });
  await page.goto(URL);
  const pageID = await page.evaluate(() => {
    const ready = (window.__nativePosts || []).filter(m => m && m.action === 'ready').slice(-1)[0];
    return ready && ready.pageID;
  });

  const projects = [];
  for (let i = 0; i < 18; i++) {
    projects.push({ id: '/tmp/项目 ' + i, path: '/tmp/项目 ' + i, favorite: i < 2, missing: false,
      sessionCount: i % 3, lastActivity: Date.now() - i * 3600e3 });
  }
  const terminals = [
    { id: 'ghostty', name: 'Ghostty', note: '', supported: true, selected: true },
    { id: 'terminal', name: 'Terminal', note: '系统自带', supported: true, selected: false },
    { id: 'iterm', name: 'iTerm2', note: '', supported: false, selected: false }
  ];
  // 终端选择测试完成后，原生实际状态是 Terminal；完整回推用它，避免把标题栏改回 Ghostty。
  const nativeTerminals = terminals.map(t => ({ ...t, selected: t.id === 'terminal' }));
  await page.evaluate(({ projects, terminals }) => {
    window.__posts = [];
    const orig = window.launcher;
    ['open','history','resume','toggleFavorite','remove','pickFolder','quit','theme','setTerminal'].forEach(k => {
      const real = orig[k];
      orig[k] = (...args) => {
        window.__posts.push([k, ...args]);
        return real.apply(orig, args);
      };
    });
    window.__render({ home: '/Users/tester', terminals, projects });
  }, { projects, terminals });
  await page.waitForTimeout(150);

  check('页面 ready 带上本页 pageID', typeof pageID === 'string' && /^p[^-]+$/.test(pageID), pageID);

  // 旧页/旧快照带不同 pageID：普通推送和活跃快照都不能落地。
  const beforePagePush = await page.textContent('#status');
  await page.evaluate(({ p, t, oldId }) => window.__render({
    pageID: 'p-old-page', projects: p, terminals: t,
    snapshot: true, activeRequests: [{ requestId: oldId, project: '/tmp/项目 3', mode: 'new' }],
    status: '旧页推送', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: oldId
  }), { p: projects, t: nativeTerminals, oldId: 'launch-poldpage-1' });
  await page.waitForTimeout(50);
  check('旧页普通推送被 pageID 丢弃', (await page.textContent('#status')) === beforePagePush,
    await page.textContent('#status'));
  check('旧页活跃快照不建 loading',
    (await page.$$eval('.card', els => els[3].dataset.state || '')) === '',
    await page.$$eval('.card', els => els[3].dataset.state || ''));

  // ── 两个目录入口：列表末尾打开，「常用项目」分组头只收藏；鼠标/键盘各一次 ──
  check('常用项目分组头是添加入口',
    (await page.textContent('.group__add')).includes('添加'), await page.textContent('.group__add'));
  check('列表末尾是选择文件夹并打开',
    (await page.$$eval('.cell--add', els => els.map(e => e.textContent.trim()))).join('|').includes('选择文件夹并打开'),
    await page.$$eval('.cell--add', els => els.map(e => e.textContent.trim())));
  check('项目列表只有一个打开入口磁贴',
    (await page.$$eval('.cell--add', els => els.length)) === 1,
    await page.$$eval('.cell--add', els => els.length));

  await page.evaluate(() => { window.__posts = []; });
  await page.click('.group__add');
  await page.waitForTimeout(60);
  let entryPosts = await page.evaluate(() => window.__posts.slice());
  check('鼠标点分组头添加只发 favorite',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'favorite',
    JSON.stringify(entryPosts));

  await page.evaluate(() => { window.__posts = []; });
  await page.click('.cell--add');
  await page.waitForTimeout(60);
  const mouseOpen = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  entryPosts = await page.evaluate(() => window.__posts.slice());
  check('鼠标点列表末尾只发 open',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'open' &&
      !!requestParts(mouseOpen && mouseOpen.requestId),
    JSON.stringify(entryPosts) + ' / ' + JSON.stringify(mouseOpen));
  check('鼠标点列表末尾不误开项目',
    !entryPosts.some(p => p[0] === 'open'), JSON.stringify(entryPosts));
  await page.evaluate(id => window.__intentReleased(id), mouseOpen.requestId);

  async function tabTo(selector) {
    const ok = await page.evaluate(target => {
      const items = Array.prototype.slice.call(document.querySelectorAll('button:not([disabled]), input:not([disabled])'))
        .filter(el => !el.hidden && el.offsetParent !== null);
      const index = items.indexOf(document.querySelector(target));
      if (index <= 0) return false;
      items[index - 1].focus();
      return true;
    }, selector);
    if (!ok) return false;
    await page.keyboard.press('Tab');
    return page.evaluate(target => document.activeElement === document.querySelector(target), selector);
  }

  await page.evaluate(() => { window.__posts = []; });
  check('Tab 能聚焦列表末尾入口', await tabTo('.cell--add'));
  await page.keyboard.press('Enter');
  await page.waitForTimeout(60);
  entryPosts = await page.evaluate(() => window.__posts.slice());
  const tabOpen = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  check('Tab+Enter 对列表入口恰好一次且发 open',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'open' &&
      !entryPosts.some(p => p[0] === 'open') && !!requestParts(tabOpen && tabOpen.requestId),
    JSON.stringify(entryPosts) + ' / ' + JSON.stringify(tabOpen));
  await page.evaluate(id => window.__intentReleased(id), tabOpen.requestId);

  await page.evaluate(() => { window.__posts = []; });
  await page.keyboard.press('Space');
  await page.waitForTimeout(60);
  entryPosts = await page.evaluate(() => window.__posts.slice());
  const spaceOpen = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  check('空格对列表入口恰好一次且发 open',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'open' &&
      !entryPosts.some(p => p[0] === 'open') && !!requestParts(spaceOpen && spaceOpen.requestId),
    JSON.stringify(entryPosts) + ' / ' + JSON.stringify(spaceOpen));
  await page.evaluate(id => window.__intentReleased(id), spaceOpen.requestId);

  await page.focus('#q');
  await page.keyboard.press('Tab');
  check('Tab 从搜索框落到「+ 添加」入口',
    await page.evaluate(() => document.activeElement === document.querySelector('.group__add')));
  await page.evaluate(() => { window.__posts = []; });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(60);
  entryPosts = await page.evaluate(() => window.__posts.slice());
  check('Enter 对分组头入口恰好一次且只 favorite',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'favorite' &&
      !entryPosts.some(p => p[0] === 'open'), JSON.stringify(entryPosts));

  await page.evaluate(() => { window.__posts = []; });
  await page.keyboard.press('Space');
  await page.waitForTimeout(60);
  entryPosts = await page.evaluate(() => window.__posts.slice());
  check('空格对分组头入口恰好一次且只 favorite',
    entryPosts.length === 1 && entryPosts[0][0] === 'pickFolder' && entryPosts[0][1] === 'favorite' &&
      !entryPosts.some(p => p[0] === 'open'), JSON.stringify(entryPosts));

  // 空项目和搜索有/无结果时，列表末尾打开入口都要在，且不出现第二份。
  await page.evaluate(({ t }) => window.__render({ projects: [], terminals: t }), { t: terminals });
  await page.waitForTimeout(60);
  check('空项目仍有打开入口',
    (await page.$$eval('.cell--add', els => els.length)) === 1 &&
      (await page.$$eval('.intro', els => els.length)) === 1,
    await page.$$eval('.cell--add', els => els.length));
  await page.evaluate(({ p, t }) => window.__render({ projects: p, terminals: t }), { p: projects, t: terminals });
  await page.fill('#q', '项目 17');
  await page.waitForTimeout(60);
  check('搜索有结果仍有打开入口',
    (await page.$$eval('.cell--add', els => els.length)) === 1 &&
      (await page.$$eval('.card', els => els.length)) === 1,
    await page.$$eval('.cell--add', els => els.length));
  await page.fill('#q', '绝无此项目');
  await page.waitForTimeout(60);
  check('搜索无结果仍有打开入口',
    (await page.$$eval('.cell--add', els => els.length)) === 1 &&
      (await page.$$eval('.empty', els => els.length)) === 1,
    await page.$$eval('.cell--add', els => els.length));
  await page.fill('#q', '');
  await page.waitForTimeout(60);
  await page.evaluate(() => { window.__posts = []; });

  // ── 选目录：登记意图不应启动 30 秒计时，取消只释放 ──
  await page.evaluate(() => {
    window.__timeoutCalls = [];
    window.__origSetTimeout = window.setTimeout;
    window.setTimeout = function (fn, ms) {
      window.__timeoutCalls.push(ms);
      return window.__origSetTimeout(fn, ms);
    };
  });
  await page.click('.cell--add');
  await page.waitForTimeout(60);
  const pickPost = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  const pickRequestId = pickPost && pickPost.requestId;
  check('选目录先登记请求 ID 再上报', !!requestParts(pickRequestId) && requestParts(pickRequestId).pageID === pageID,
    JSON.stringify(pickPost));
  check('选目录未返回前不启动 30 秒计时',
    (await page.evaluate(() => window.__timeoutCalls.filter(ms => ms === 30000).length)) === 0,
    await page.evaluate(() => JSON.stringify(window.__timeoutCalls)));
  await page.evaluate(id => window.__intentReleased(id), pickRequestId);
  check('取消选目录释放意图后仍不计时',
    (await page.evaluate(() => window.__timeoutCalls.filter(ms => ms === 30000).length)) === 0,
    await page.evaluate(() => JSON.stringify(window.__timeoutCalls)));
  await page.click('.cell--add');
  await page.waitForTimeout(60);
  const pickPost2 = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  const pickRequestId2 = pickPost2 && pickPost2.requestId;
  await page.evaluate(({ id, pageID, p }) => window.__render({
    pageID: pageID, projects: p, status: '正在打开 新项目…', statusPhase: 'start',
    statusScope: 'launch', statusProject: '/tmp/panel 新项目', statusMode: 'continue',
    statusRequestID: id, statusOrigin: 'panel'
  }), { id: pickRequestId2, pageID: pageID, p: projects });
  await page.waitForTimeout(60);
  check('面板返回的合法 start 建立 loading 并计时',
    (await page.evaluate(() => window.__timeoutCalls.filter(ms => ms === 30000).length)) > 0,
    await page.evaluate(() => JSON.stringify(window.__timeoutCalls)));
  check('面板返回的 start 写进底栏', (await page.textContent('#status')).includes('正在打开'), await page.textContent('#status'));
  await page.evaluate(({ id, pageID, p }) => window.__render({
    pageID: pageID, projects: p, status: '新项目已开好', statusPhase: 'done',
    statusScope: 'launch', statusProject: '/tmp/panel 新项目', statusRequestID: id
  }), { id: pickRequestId2, pageID: pageID, p: projects });
  await page.waitForTimeout(60);
  await page.evaluate(() => { window.setTimeout = window.__origSetTimeout; });
  await page.evaluate(() => { window.__posts = []; });

  // ── 终端选择器 ──
  check('标题栏显示当前终端', (await page.textContent('#term-name')) === 'Ghostty');
  await page.click('#term');
  const items = await page.$$eval('.term__item', els => els.map(e => ({
    id: e.dataset.id, tag: e.querySelector('.term__item-tag').textContent,
    disabled: e.getAttribute('aria-disabled'), checked: e.getAttribute('aria-checked')
  })));
  check('菜单只列检测到的终端', items.length === 3, JSON.stringify(items));
  check('当前项标记', items[0].checked === 'true' && items[0].tag === '当前');
  check('未适配项灰着', items[2].disabled === 'true' && items[2].tag === '未适配');
  await page.$eval('.term__item[data-id="iterm"]', el => el.click());
  await page.waitForTimeout(80);
  check('点未适配项不切换、不收起', await page.evaluate(() => !document.getElementById('term-menu').hidden && window.__posts.length === 0));
  await page.$eval('.term__item[data-id="terminal"]', el => el.click());
  await page.waitForTimeout(80);
  const posts = await page.evaluate(() => window.__posts);
  check('选可用终端会回报原生', JSON.stringify(posts) === JSON.stringify([['setTerminal', 'terminal']]), JSON.stringify(posts));
  check('选完收起菜单', await page.evaluate(() => document.getElementById('term-menu').hidden));
  // 原生回推选中结果
  await page.evaluate(({ t, p }) => window.__render({ terminals: t.map(x => ({ ...x, selected: x.id === 'terminal' })), projects: p }), { t: terminals, p: projects });
  check('切换后标题栏跟着变', (await page.textContent('#term-name')) === 'Terminal', await page.textContent('#term-name'));

  // 快速连续回推终端标签，标题栏取最后一次，不因中间状态乱序。
  await page.evaluate(({ p, t }) => {
    window.__render({ projects: p, terminals: t.map(x => ({ ...x, selected: x.id === 'ghostty' })) });
    window.__render({ projects: p, terminals: t.map(x => ({ ...x, selected: x.id === 'terminal' })) });
  }, { p: projects, t: terminals });
  await page.waitForTimeout(60);
  check('快速切终端后标题栏取最后一次', (await page.textContent('#term-name')) === 'Terminal', await page.textContent('#term-name'));

  // Esc 收起菜单且不退出
  await page.click('#term');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(80);
  const afterEsc = await page.evaluate(() => ({ open: !document.getElementById('term-menu').hidden, posts: window.__posts.map(p => p[0]) }));
  check('Esc 只收起菜单', afterEsc.open === false && !afterEsc.posts.includes('quit'), JSON.stringify(afterEsc));

  // ── 状态三相 ──
  const statusText = () => page.textContent('#status');
  const cardTime = (i) => page.$$eval('.card', (els, i) => els[i].querySelector('.card__time').textContent, i);
  const cardState = (i) => page.$$eval('.card', (els, i) => els[i].dataset.state || '', i);

  await page.evaluate(p => window.__render({ status: '正在打开 项目 3…', statusPhase: 'start', projects: p }), projects);
  await page.waitForTimeout(80);
  check('start 状态写进底栏', (await statusText()).includes('正在打开'), await statusText());

  // 模拟点卡片（DOM 已经在，走真实点击）
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(80);
  check('点卡片立刻显示卡片 loading', (await cardState(3)) === 'loading' && (await cardTime(3)).includes('正在'), await cardTime(3));
  check('点卡片回报 open', await page.evaluate(() => window.__posts.some(p => p[0] === 'open')));
  const firstLaunch = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const firstRequestId = firstLaunch && firstLaunch[3];
  check('点击产生请求 ID 并随 open 上报',
    !!requestParts(firstRequestId) && requestParts(firstRequestId).pageID === pageID,
    JSON.stringify(firstLaunch));

  // 完整原生回推：同一请求 ID；同类中间态不撤 loading
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '正在打开 项目 3…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'new', statusRequestID: id
  }), { p: projects, id: firstRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('带请求 ID 的 start 保持卡片 loading', (await cardState(3)) === 'loading', await cardState(3));

  // 同项目再点一次，产生新请求；旧请求的 done 只能收自己，不能清新 loading。
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const launchPosts = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open'));
  const secondRequestId = launchPosts.length > 1 ? launchPosts[launchPosts.length - 1][3] : null;
  check('同项目第二次点击产生新请求 ID',
    typeof secondRequestId === 'string' && secondRequestId !== firstRequestId,
    `${firstRequestId} / ${secondRequestId}`);

  // 旧请求的迟到 start 也不能 markPending 并吃掉同项目新请求。
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '旧请求迟到的启动…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'new', statusRequestID: id
  }), { p: projects, id: firstRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('旧请求迟到 start 不撤新 loading', (await cardState(3)) === 'loading', await cardState(3));
  check('旧请求迟到 start 不覆盖新状态', (await statusText()).includes('正在打开'), await statusText());

  // 缺失 requestID 的终态不能清带 ID 的新 loading，也不能覆盖新状态。
  await page.evaluate(({ p, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '已开好新会话', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3'
  }), { p: projects, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('缺失请求 ID 的终态不刷新 loading', (await cardState(3)) === 'loading', await cardState(3));
  check('缺失请求 ID 的终态不覆盖新状态', (await statusText()).includes('正在打开'), await statusText());

  // 错误 requestID 同样只能被忽略。
  await page.evaluate(({ p, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '已开好新会话', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: 'wrong-request-id'
  }), { p: projects, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('错误请求 ID 的终态不刷新 loading', (await cardState(3)) === 'loading', await cardState(3));

  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '已开好新会话', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: firstRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(80);
  check('旧请求终态不撤同项目新 loading', (await cardState(3)) === 'loading', await cardState(3));
  check('旧请求终态不覆盖新启动状态', (await statusText()).includes('正在打开'), await statusText());

  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '已开好新会话', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: secondRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(80);
  check('新请求终态撤掉自己的 loading', (await cardState(3)) === '', await cardState(3));

  // 新请求完成后的旧 start 只能被忽略，不能重新亮起 loading。
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '旧请求完成的启动…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'new', statusRequestID: id
  }), { p: projects, id: firstRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('完成后迟到 start 不复活 loading', (await cardState(3)) === '', await cardState(3));
  check('完成后迟到 start 不覆盖完成状态', (await statusText()).includes('已开好'), await statusText());

  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '旧请求迟到的终态', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: firstRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('完成后迟到终态不能复活 loading',
    (await cardState(3)) === '', await cardState(3));

  // 跨项目：项目 4 在 loading 时，项目 3 的无 ID 终态不能碰它。
  await page.$$eval('.card', els => els[4].click());
  await page.waitForTimeout(60);
  const crossLaunch = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const crossRequestId = crossLaunch && crossLaunch[3];
  check('跨项目测试先建立新 loading', (await cardState(4)) === 'loading', await cardState(4));
  await page.evaluate(({ p, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '项目 3 已完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3'
  }), { p: projects, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('跨项目无 ID 终态不影响其它项目 loading',
    (await cardState(4)) === 'loading', await cardState(4));
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '项目 4 已完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 4', statusRequestID: id
  }), { p: projects, id: crossRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('跨项目自己的终态只收自己的 loading',
    (await cardState(4)) === '', await cardState(4));

  // 原生选目录补发的合法新请求：先在当前页登记 unbound，再接收首次绑定。
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const prePanelLaunch = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const prePanelId = prePanelLaunch && prePanelLaunch[3];
  await page.click('.cell--add');
  await page.waitForTimeout(40);
  const panelPick = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  const panelRequestId = panelPick && panelPick.requestId;
  check('panel 首次绑定使用已登记的当前页请求',
    !!requestParts(panelRequestId) && requestParts(panelRequestId).pageID === pageID,
    JSON.stringify(panelPick));
  check('panel 接管使用本页递增序号',
    !!requestParts(panelRequestId) && !!requestParts(prePanelId) &&
      requestParts(panelRequestId).seq > requestParts(prePanelId).seq,
    `${prePanelId} / ${panelRequestId}`);
  await page.evaluate(({ p, panelId, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '正在打开 项目 3…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'continue',
    statusRequestID: panelId, statusOrigin: 'panel'
  }), { p: projects, panelId: panelRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('panel start 可接管同项目旧挂起', (await cardState(3)) === 'loading', await cardState(3));
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '项目 3 已完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: panelRequestId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('panel 终态清掉自己的 loading', (await cardState(3)) === '', await cardState(3));
  await page.evaluate(() => { window.__posts = []; });

  // 旧 panel start 晚于新点击：先登记旧 unbound，再让新点击取得更新的页内序号。
  await page.click('.cell--add');
  await page.waitForTimeout(40);
  const oldPanelPick = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'pickFolder').slice(-1)[0]);
  const oldPanelId = oldPanelPick && oldPanelPick.requestId;
  check('旧 panel 使用先登记的 unbound',
    !!requestParts(oldPanelId) && requestParts(oldPanelId).pageID === pageID,
    JSON.stringify(oldPanelPick));
  await page.evaluate(() => {
    window.__frozenNow = Date.now();
    window.__realNow = Date.now;
    Date.now = function () { return window.__frozenNow; };
  });
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const latePanelNewLaunch = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const latePanelNewId = latePanelNewLaunch && latePanelNewLaunch[3];
  check('同一毫秒新点击仍建立 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '正在打开 项目 3（同一毫秒）…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'new', statusRequestID: id
  }), { p: projects, id: latePanelNewId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('同一毫秒合法 start 保持自己的 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  await page.evaluate(({ p, terminals, oldId }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '旧 panel 迟到', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'continue',
    statusRequestID: oldId, statusOrigin: 'panel'
  }), { p: projects, terminals: nativeTerminals, oldId: oldPanelId });
  await page.waitForTimeout(60);
  check('旧 panel start 不接管更新点击的 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  check('旧 panel start 不覆盖新点击状态',
    (await statusText()).includes('正在打开'), await statusText());
  // 不可解析的未知 start 不能靠 origin=panel 重新变成请求。
  await page.evaluate(({ p, terminals, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '未知旧 start', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusMode: 'continue',
    statusRequestID: 'unknown-panel-start', statusOrigin: 'panel'
  }), { p: projects, terminals: nativeTerminals, pageID: pageID });
  await page.waitForTimeout(60);
  check('未知 start 不能靠 origin=panel 接管 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  check('未知 start 不覆盖新点击状态',
    (await statusText()).includes('正在打开'), await statusText());
  // 旧快照也不能用 activeRequests 把旧请求重新挂到新点击上。
  await page.evaluate(({ p, terminals, pageID, oldId }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    snapshot: true, activeRequests: [{ requestId: oldId, project: '/tmp/项目 3', mode: 'continue' }],
    status: '旧快照启动', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: oldId, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, pageID: pageID, oldId: oldPanelId });
  await page.waitForTimeout(60);
  check('旧快照 activeRequests 不接管新点击 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  check('旧快照 start 不覆盖新点击状态',
    (await statusText()).includes('正在打开'), await statusText());
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '新点击完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: latePanelNewId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('同一毫秒新点击终态正常收尾',
    (await cardState(3)) === '', await cardState(3));
  check('同一毫秒旧 panel 不覆盖新点击状态',
    (await statusText()).includes('新点击完成'), await statusText());
  await page.evaluate(({ p, terminals, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '完成后未知 start', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: 'unknown-after-done',
    statusOrigin: 'panel'
  }), { p: projects, terminals: nativeTerminals, pageID: pageID });
  await page.waitForTimeout(60);
  check('完成后未知 start 不复活 loading',
    (await cardState(3)) === '', await cardState(3));
  await page.evaluate(() => { Date.now = window.__realNow; });

  // 释放后的请求不能再靠合法 ID/序号或 replay 标记登记、改底栏或复活 loading。
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const releasedPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const releasedId = releasedPost && releasedPost[3];
  await page.evaluate(id => window.__intentReleased(id), releasedId);
  const releasedStatus = await statusText();
  check('释放后清掉自己的 loading', (await cardState(3)) === '', await cardState(3));
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '释放后又启动', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusOrigin: 'panel'
  }), { p: projects, id: releasedId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('释放后迟到 start 不改底栏', (await statusText()) === releasedStatus, await statusText());
  check('释放后迟到 start 不复活 loading', (await cardState(3)) === '', await cardState(3));
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '释放后又完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, id: releasedId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('释放后迟到终态不改底栏', (await statusText()) === releasedStatus, await statusText());
  check('释放后迟到终态不复活 loading', (await cardState(3)) === '', await cardState(3));

  const unregisteredId = 'launch-' + pageID + '-999999';
  const beforeUnregistered = await statusText();
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '未登记同页 ID', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 4', statusRequestID: id, statusOrigin: 'panel'
  }), { p: projects, id: unregisteredId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('未登记同页有效格式 ID 不改底栏',
    (await statusText()) === beforeUnregistered, await statusText());
  check('未登记同页有效格式 ID 不复活 loading',
    (await cardState(4)) === '', await cardState(4));

  // 错误项目绑定不能按旧 superseded 分支清掉真正属于项目 3 的 pending。
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const boundPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const boundId = boundPost && boundPost[3];
  const boundStatus = await statusText();
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '错误绑定终态', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 4', statusRequestID: id
  }), { p: projects, id: boundId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('错误项目绑定不清其它项目 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  check('错误项目绑定不改底栏', (await statusText()) === boundStatus, await statusText());
  await page.evaluate(({ p, id, pageID, terminals }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '绑定正确完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: boundId, pageID: pageID, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('绑定正确后才收自己的 loading', (await cardState(3)) === '', await cardState(3));

  // 中途 refreshMeta 推送（同签名以外还变了会话数）不能让 loading 消失
  const ticked = projects.map((p, i) => i === 3 ? { ...p, sessionCount: (p.sessionCount || 0) + 1 } : p);
  await page.evaluate(p => window.__render({ status: '已在 Ghostty 开窗口，等 pi 起来…', statusPhase: 'start', statusScope: 'launch', statusProject: '/tmp/项目 3', projects: p }), ticked);
  await page.waitForTimeout(80);
  check('中间相不抹掉卡片 loading', (await cardState(3)) === 'loading', await cardState(3));
  check('中间相文案生效', (await statusText()).includes('等 pi 起来'), await statusText());

  // 启动还在飞的时候点星标：这类状态不属于启动，不能把卡片 loading 和 30 秒兜底一起撤掉
  await page.evaluate(p => window.__render({ status: '已设为常用', statusTone: 'ok', projects: p }), ticked);
  await page.waitForTimeout(80);
  check('非启动类状态不会撤掉卡片 loading', (await cardState(3)) === 'loading', await cardState(3));

  const scrollBefore = await page.evaluate(() => { const s = document.getElementById('stack'); s.scrollTop = s.scrollHeight; return s.scrollTop; });
  await page.evaluate(p => window.__render({ status: '已开好新会话', statusTone: 'ok', statusPhase: 'done', statusScope: 'launch', statusProject: '/tmp/项目 3', projects: p }), ticked);
  await page.waitForTimeout(120);
  check('done 后卡片回到真实日期', (await cardState(3)) === '' && (await cardTime(3)).includes('小时') || (await cardTime(3)).includes(':') || (await cardTime(3)).includes('天前'), await cardTime(3));
  check('done 后底栏仍有文字（4 秒后才收）', (await statusText()).includes('已开好'), await statusText());
  const scrollAfter = await page.evaluate(() => document.getElementById('stack').scrollTop);
  check('重绘不跳回顶部', Math.abs(scrollAfter - scrollBefore) < 2, `${scrollBefore} -> ${scrollAfter}`);
  await page.waitForTimeout(4300);
  check('done 后 4 秒自动清空', (await statusText()) === '', JSON.stringify(await statusText()));

  await page.evaluate(p => window.__render({ status: '打开失败', statusTone: 'error', statusPhase: 'error', statusScope: 'launch', statusProject: '/tmp/项目 3', projects: p }), ticked);
  await page.waitForTimeout(4500);
  check('error 留到下次操作（5 秒仍在）', (await statusText()).includes('打开失败'), await statusText());

  // 旧调用点没给 phase 时按色调推断
  await page.evaluate(p => window.__render({ status: '已加入常用项目', statusTone: 'ok', projects: p }), ticked);
  await page.waitForTimeout(4300);
  check('没给 phase 的旧状态也会自动收', (await statusText()) === '', JSON.stringify(await statusText()));

  // 连续 68 次请求后，旧 start/终态仍要靠序号/最新状态拒绝，不能因为没历史表就当新请求。
  await page.$$eval('.card', els => { for (let i = 0; i < 68; i++) els[3].click(); });
  await page.waitForTimeout(100);
  const overflowPosts = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open'));
  const overflowFirstId = overflowPosts.length >= 68 ? overflowPosts[overflowPosts.length - 68][3] : null;
  const overflowLatestId = overflowPosts.length ? overflowPosts[overflowPosts.length - 1][3] : null;
  check('溢出测试拿到新旧请求 ID',
    typeof overflowFirstId === 'string' && typeof overflowLatestId === 'string' &&
    overflowFirstId !== overflowLatestId,
    `${overflowFirstId} / ${overflowLatestId}`);
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '溢出请求完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: overflowLatestId, terminals: nativeTerminals });
  await page.waitForTimeout(80);
  check('连续 68 次请求后的当前终态正常收尾',
    (await cardState(3)) === '', await cardState(3));
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '超过上限的旧 start', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: overflowFirstId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('连续 68 次请求后的旧 start 不复活 loading',
    (await cardState(3)) === '', await cardState(3));
  check('连续 68 次请求后的旧 start 不覆盖完成状态',
    (await statusText()).includes('溢出请求完成'), await statusText());
  await page.evaluate(({ p, id, terminals }) => window.__render({
    projects: p, terminals: terminals, home: '/Users/tester',
    status: '超过上限的旧终态', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: overflowFirstId, terminals: nativeTerminals });
  await page.waitForTimeout(60);
  check('连续 68 次请求后的旧终态不复活 loading',
    (await cardState(3)) === '', await cardState(3));

  // 历史页「开新会话」有即时反馈
  await page.evaluate(p => { window.__render({ status: '已加入常用项目', statusTone: 'ok', projects: p }); }, ticked);
  await page.$$eval('.cell__sessions', els => els[3].click());
  await page.evaluate(() => window.__history({ project: '/tmp/项目 3', sessions: [
    { path: '/tmp/s1.jsonl', title: '第一条会话', modified: Date.now() - 3600e3, messageCount: 4 }
  ], ticket: 1 }));
  await page.waitForTimeout(120);
  await page.$eval('.srow', el => el.click());
  await page.waitForTimeout(80);
  const resumePost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'resume').slice(-1)[0]);
  check('历史行继续也带请求 ID',
    !!resumePost && !!requestParts(resumePost[3]) &&
    requestParts(resumePost[3]).pageID === pageID,
    JSON.stringify(resumePost));
  await page.click('#hnew');
  await page.waitForTimeout(80);
  const hnewPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  check('历史页开新会话也带有效请求 ID',
    !!hnewPost && !!requestParts(hnewPost[3]) &&
    requestParts(hnewPost[3]).pageID === pageID,
    JSON.stringify(hnewPost));
  check('历史页开新会话有即时状态', (await statusText()).includes('正在开新会话'), await statusText());
  await page.click('#hback');
  await page.waitForTimeout(80);

  // 昼夜截图
  await page.evaluate(() => { document.documentElement.dataset.theme = 'day'; document.getElementById('status').textContent = ''; });
  await page.click('#term').catch(() => {});
  await page.waitForTimeout(80);
  await page.screenshot({ path: '/tmp/ui-menu-day.png' });
  await page.evaluate(() => { document.documentElement.dataset.theme = 'night'; });
  await page.waitForTimeout(80);
  await page.screenshot({ path: '/tmp/ui-menu-night.png' });

  // 时钟回拨不影响请求身份：仍按 requestId 的页内序号判断。
  await page.evaluate(() => {
    window.__realNow = Date.now;
    Date.now = function () { return 1; };
  });
  await page.$$eval('.card', els => els[5].click());
  await page.waitForTimeout(60);
  const rollbackPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const rollbackId = rollbackPost && rollbackPost[3];
  check('时钟回拨后仍生成本页递增请求 ID',
    !!requestParts(rollbackId) && requestParts(rollbackId).pageID === pageID,
    JSON.stringify(rollbackPost));
  await page.evaluate(({ p, id, pageID }) => window.__render({
    pageID: pageID, projects: p, status: '回拨后启动', statusPhase: 'start',
    statusScope: 'launch', statusProject: '/tmp/项目 5', statusMode: 'new',
    statusRequestID: id
  }), { p: projects, id: rollbackId, pageID: pageID });
  await page.waitForTimeout(60);
  check('时钟回拨不阻止合法 start', (await cardState(5)) === 'loading', await cardState(5));
  await page.evaluate(({ p, id, pageID }) => window.__render({
    pageID: pageID, projects: p, status: '回拨后完成', statusPhase: 'done',
    statusScope: 'launch', statusProject: '/tmp/项目 5', statusRequestID: id
  }), { p: projects, id: rollbackId, pageID: pageID });
  await page.waitForTimeout(60);
  check('时钟回拨后终态正常收尾', (await cardState(5)) === '', await cardState(5));
  await page.evaluate(() => { Date.now = window.__realNow; });

  // 项目移除：清掉该项目的 pending/身份记录并留下页内退役水位；
  // 两个项目的旧消息都不能复活，重新加入后的新请求仍可用。
  const withoutProjects = projects.filter((_, i) => i !== 3 && i !== 4);
  const beforeRemovalStatus = await page.textContent('#status');
  await page.evaluate(({ p, t }) => window.__render({ projects: p, terminals: t }), {
    p: withoutProjects, t: nativeTerminals
  });
  await page.waitForTimeout(60);
  await page.evaluate(({ p, t, pageID, old3, old4 }) => window.__render({
    pageID: pageID, projects: p, terminals: t,
    status: '项目 3 旧消息迟到', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: old3
  }), { p: withoutProjects, t: nativeTerminals, pageID: pageID, old3: latePanelNewId, old4: crossRequestId });
  await page.evaluate(({ p, t, pageID, old4 }) => window.__render({
    pageID: pageID, projects: p, terminals: t,
    status: '项目 4 旧消息迟到', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 4', statusRequestID: old4
  }), { p: withoutProjects, t: nativeTerminals, pageID: pageID, old4: crossRequestId });
  await page.waitForTimeout(60);
  check('移除项目后旧消息不覆盖状态', (await page.textContent('#status')) === beforeRemovalStatus,
    await page.textContent('#status'));
  check('移除项目后旧 start 不复活 loading',
    (await page.$$eval('.card', els => els.filter(e => e.dataset.id === '/tmp/项目 3').length)) === 0);
  await page.evaluate(({ p, t }) => window.__render({ projects: p, terminals: t }), {
    p: projects, t: nativeTerminals
  });
  await page.waitForTimeout(60);
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const recycledPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const recycledId = recycledPost && recycledPost[3];
  check('重新加入项目后的新请求序号大于退役水位',
    !!requestParts(recycledId) && requestParts(recycledId).pageID === pageID,
    JSON.stringify(recycledPost));
  check('重新加入项目后的新请求恢复 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  await page.evaluate(({ p, id, pageID }) => window.__render({
    pageID: pageID, projects: p, status: '重新加入后完成', statusPhase: 'done',
    statusScope: 'launch', statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: recycledId, pageID: pageID });
  await page.waitForTimeout(60);
  check('重新加入项目后的终态正常收尾', (await cardState(3)) === '', await cardState(3));

  // 页面重载前留一个真实活跃请求：重载后只能靠当前投递页的 activeRequests 导入，
  // 页面脚本自己的 pending 已经随旧页消失。
  await page.$$eval('.card', els => els[6].click());
  await page.waitForTimeout(60);
  const activeBeforeReloadPost = await page.evaluate(() => window.__posts.filter(p => p[0] === 'open').slice(-1)[0]);
  const activeBeforeReloadId = activeBeforeReloadPost && activeBeforeReloadPost[3];
  check('重载前建立活跃请求',
    !!requestParts(activeBeforeReloadId) && (await cardState(6)) === 'loading',
    JSON.stringify(activeBeforeReloadPost));

  // 每个需要首次快照特权的场景使用独立页面代际；同页后续快照不再导入。
  const beforeReloadPageID = pageID;
  async function freshPage() {
    await page.reload();
    await page.waitForFunction(() => typeof window.__render === 'function');
    await page.waitForTimeout(80);
    const id = await page.evaluate(() => {
      const ready = (window.__nativePosts || []).filter(m => m && m.action === 'ready').slice(-1)[0];
      return ready && ready.pageID;
    });
    await page.evaluate(({ p, t, pageID }) => window.__render({
      pageID: pageID, projects: p, terminals: t, home: '/Users/tester'
    }), { p: projects, t: nativeTerminals, pageID: id });
    return id;
  }

  // 首次非空快照：导入旧页活跃请求，后续普通终态按登记收尾。
  const reloadPageID = await freshPage();
  check('页面重载产生新 pageID',
    typeof reloadPageID === 'string' && reloadPageID !== beforeReloadPageID,
    `${beforeReloadPageID} / ${reloadPageID}`);
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    snapshot: true, activeRequests: [{ requestId: id, project: '/tmp/项目 6', mode: 'new' }],
    status: '重载后活跃请求仍在', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 6', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: activeBeforeReloadId, pageID: reloadPageID });
  await page.waitForTimeout(80);
  check('重载导入旧页活跃请求并回放 start',
    (await cardState(6)) === 'loading', await cardState(6));
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '重载后活跃请求完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 6', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: activeBeforeReloadId, pageID: reloadPageID });
  await page.waitForTimeout(60);
  check('重载回放旧页活跃请求终态收尾',
    (await cardState(6)) === '', await cardState(6));

  // 首次快照 done：独立页面代际。
  const donePageID = await freshPage();
  const reloadDoneId = `launch-${donePageID}-10`;
  const reloadOldDoneId = `launch-${donePageID}-9`;
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    snapshot: true, status: '重载回放完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: reloadDoneId, pageID: donePageID });
  await page.waitForTimeout(60);
  check('重载先回放 done 不重建 loading',
    (await cardState(3)) === '', await cardState(3));
  await page.evaluate(({ p, terminals, oldId, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '重载旧页 start', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: oldId
  }), { p: projects, terminals: nativeTerminals, oldId: latePanelNewId, pageID: donePageID });
  await page.waitForTimeout(60);
  check('重载回放 done 后的旧页 start 不复活 loading',
    (await cardState(3)) === '', await cardState(3));
  check('重载回放 done 后的旧页 start 不覆盖状态',
    (await statusText()).includes('重载回放完成'), await statusText());
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '重载旧 start', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, terminals: nativeTerminals, id: reloadOldDoneId, pageID: donePageID });
  await page.waitForTimeout(60);
  check('重载回放 done 后的旧 start 不复活 loading',
    (await cardState(3)) === '', await cardState(3));
  check('重载回放 done 后的旧 start 不覆盖状态',
    (await statusText()).includes('重载回放完成'), await statusText());

  // 首次快照 error：再取一个独立页面代际。
  const errorPageID = await freshPage();
  const reloadErrorId = `launch-${errorPageID}-11`;
  const reloadOldErrorId = `launch-${errorPageID}-9`;
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    snapshot: true, status: '重载回放错误', statusPhase: 'error', statusTone: 'error', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: reloadErrorId, pageID: errorPageID });
  await page.waitForTimeout(60);
  check('重载回放 error 不重建 loading',
    (await cardState(3)) === '', await cardState(3));
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '重载旧 start 2', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, terminals: nativeTerminals, id: reloadOldErrorId, pageID: errorPageID });
  await page.waitForTimeout(60);
  check('重载回放 error 后的旧 start 不复活 loading',
    (await cardState(3)) === '', await cardState(3));
  check('重载回放 error 后的旧 start 不覆盖状态',
    (await statusText()).includes('重载回放错误'), await statusText());

  // 首次快照导入当前活跃请求：另取页面代际。
  const currentPageID2 = await freshPage();
  const reloadCurrentId = `launch-${currentPageID2}-20`;
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    snapshot: true, activeRequests: [{ requestId: id, project: '/tmp/项目 3', mode: 'continue' }],
    status: '重载后正在打开…', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: reloadCurrentId, pageID: currentPageID2 });
  await page.waitForTimeout(80);
  check('页面重载回放当前 start 重建 loading',
    (await cardState(3)) === 'loading', await cardState(3));
  await page.evaluate(({ p, terminals, id, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: terminals, home: '/Users/tester',
    status: '重载后已完成', statusPhase: 'done', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, terminals: nativeTerminals, id: reloadCurrentId, pageID: currentPageID2 });
  await page.waitForTimeout(80);
  check('页面重载回放当前终态收掉自己的 loading',
    (await cardState(3)) === '', await cardState(3));

  // 同页第二份快照（含空首份后的旧活跃）不得再次导入：独立页面代际复现诊断。
  const repeatPageID = await freshPage();
  await page.evaluate(({ p, t, pageID }) => window.__render({
    pageID: pageID, projects: p, terminals: t, snapshot: true, activeRequests: []
  }), { p: projects, t: nativeTerminals, pageID: repeatPageID });
  await page.$$eval('.card', els => els[3].click());
  await page.waitForTimeout(60);
  const repeatPost = await page.evaluate(() => (window.__nativePosts || []).filter(m => m && m.action === 'open').slice(-1)[0]);
  const repeatId = repeatPost && repeatPost.requestId;
  await page.evaluate(({ p, id, pageID }) => window.__render({
    pageID: pageID, projects: p, status: '本轮请求已经完成', statusPhase: 'done',
    statusScope: 'launch', statusProject: '/tmp/项目 3', statusRequestID: id
  }), { p: projects, id: repeatId, pageID: repeatPageID });
  await page.evaluate(({ p, pageID }) => {
    window.__render({ pageID, projects: p.filter((_, i) => i !== 3) });
    window.__render({ pageID, projects: p });
  }, { p: projects, pageID: repeatPageID });
  const repeatBefore = await statusText();
  const repeatBeforeLoading = await cardState(3);
  await page.evaluate(({ p, id, pageID }) => window.__render({
    pageID: pageID, projects: p, snapshot: true,
    activeRequests: [{ requestId: id, project: '/tmp/项目 3', mode: 'new' }],
    status: '诊断：本页第二份旧活跃快照', statusPhase: 'start', statusScope: 'launch',
    statusProject: '/tmp/项目 3', statusRequestID: id, statusReplay: true
  }), { p: projects, id: repeatId, pageID: repeatPageID });
  await page.waitForTimeout(60);
  check('首份空快照后第二份旧 active 快照不复活 loading',
    repeatBeforeLoading === '' && (await cardState(3)) === '', await cardState(3));
  check('首份空快照后第二份旧 active 快照不覆盖状态',
    (await statusText()) === repeatBefore, await statusText());

  // 160 个不同项目进入/退出：项目、请求、unbound 都清空，仅当前项目可留展示记录。
  await page.evaluate(pageID => {
    for (let i = 0; i < 160; i++) {
      const project = { id: '/tmp/identity-churn-' + i, path: '/tmp/identity-churn-' + i,
        favorite: false, missing: false };
      window.__render({ pageID, projects: [project] });
      const card = document.querySelector('.card');
      if (!card) throw new Error('churn card missing');
      card.click();
      const open = (window.__nativePosts || []).filter(m => m && m.action === 'open').slice(-1)[0];
      if (!open || !open.requestId) throw new Error('churn request id missing');
      window.__render({ pageID, projects: [project], status: 'churn start',
        statusPhase: 'start', statusScope: 'launch', statusProject: project.id,
        statusRequestID: open.requestId });
      window.__render({ pageID, projects: [project], status: 'churn done',
        statusPhase: 'done', statusScope: 'launch', statusProject: project.id,
        statusRequestID: open.requestId });
      window.__render({ pageID, projects: [] });
    }
    window.__render({ pageID, projects: [] });
  }, repeatPageID);

  // 用 Chromium 调试器只读查看原产品闭包：没有 retiredBefore 历史表，记录已收敛。
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Debugger.enable');
  const renderFn = await cdp.send('Runtime.evaluate', { expression: 'window.__render' });
  const breakpoint = await cdp.send('Debugger.setBreakpointOnFunctionCall', {
    objectId: renderFn.result.objectId
  });
  const paused = new Promise(resolve => cdp.once('Debugger.paused', resolve));
  const renderAfterChurn = page.evaluate(({ p, pageID }) => window.__render({
    pageID, projects: p
  }), { p: projects, pageID: repeatPageID });
  const event = await Promise.race([
    paused,
    new Promise((_, reject) => setTimeout(() => reject(new Error('CDP 闭包断点未命中')), 5000))
  ]);
  const closure = await cdp.send('Debugger.evaluateOnCallFrame', {
    callFrameId: event.callFrames[0].callFrameId,
    expression: 'JSON.stringify({retiredType:typeof retiredBefore,latestKeys:Object.keys(latestLaunchState),pendingKeys:Object.keys(pending),unboundKeys:Object.keys(unboundIntents),currentIds:state.projects.map(p=>p.id)})',
    returnByValue: true,
    silent: true
  });
  await cdp.send('Debugger.removeBreakpoint', { breakpointId: breakpoint.breakpointId });
  await cdp.send('Debugger.resume');
  await renderAfterChurn;
  const closureReport = closure.result.value ? JSON.parse(closure.result.value) : null;
  check('160 个项目进出后无历史表残留',
    !!closureReport && closureReport.retiredType === 'undefined' &&
      closureReport.pendingKeys.length === 0 && closureReport.unboundKeys.length === 0 &&
      closureReport.latestKeys.every(id => closureReport.currentIds.indexOf(id) >= 0),
    JSON.stringify(closureReport));

  check('无 JS 报错', errors.length === 0, errors.join(' | '));
  await browser.close();

  const failed = results.filter(r => !r.ok);
  for (const r of results) console.log((r.ok ? 'PASS ' : 'FAIL ') + r.label + (r.ok ? '' : '  -> ' + r.detail));
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();
