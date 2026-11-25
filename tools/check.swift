// 质量检查（确定性版）：样式规则存在性、点击区、溢出、颜色归一化对比度。
// 用法：swiftc -O -o /tmp/check check.swift && /tmp/check <ui目录> [day|night]
// 昼夜各跑一遍：暗色的合成底色与白天完全不同，白天的结论不能沿用。
import Cocoa
import WebKit

let rawArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ui"
// http(s) 开头视为 URL（cssRules 可读），否则视为本地目录
let uiDir: URL = rawArg.hasPrefix("http")
    ? URL(string: rawArg)!
    : URL(fileURLWithPath: rawArg)

let theme = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "night" ? "night" : "day"
/// 合成时垫在最底下的不透明色：取画布渐变最深的一端（最保守，深字对比度最低）
let canvasBaseHex = theme == "night" ? "#100f0a" : "#ece5d4"

let payload: [String: Any] = [
    "home": "/Users/you",
    "projects": [
        ["id": "/Users/you/projects/pi-launcher", "path": "/Users/you/projects/pi-launcher", "favorite": true, "missing": false, "sessionCount": 21, "lastActivity": Date().timeIntervalSince1970 * 1000],
        ["id": "/Users/you/projects/网站后台", "path": "/Users/you/projects/网站后台", "favorite": true, "missing": false, "sessionCount": 3, "lastActivity": Date().timeIntervalSince1970 * 1000],
        ["id": "/Users/you/projects/一个很长的中文项目目录名称用来测试截断行为是否正常", "path": "/Users/you/projects/一个很长的中文项目目录名称用来测试截断行为是否正常", "favorite": false, "missing": false],
        ["id": "/Users/you/projects/已删除", "path": "/Users/you/projects/已删除", "favorite": false, "missing": true]
    ],
    "terminals": [
        ["id": "ghostty", "name": "Ghostty", "note": "", "supported": true, "selected": true],
        ["id": "terminal", "name": "Terminal", "note": "系统自带", "supported": true, "selected": false],
        ["id": "iterm", "name": "iTerm2", "note": "", "supported": false, "selected": false]
    ],
    "status": "就绪"
]

let probe = """
(function () {
  var out = {};

  // 终端菜单默认是收起的：先点开，才量得到菜单项的对比度；量完再点回去
  var termBtn = document.getElementById('term');
  var termMenuWasOpen = termBtn ? !document.getElementById('term-menu').hidden : true;
  if (termBtn && !termMenuWasOpen) termBtn.click();

  // 用 canvas 把任意颜色写法（oklch/color(srgb)/rgb）归一化为 rgb
  var cv = document.createElement('canvas');
  cv.width = cv.height = 1;
  var ctx = cv.getContext('2d', { willReadFrequently: true });
  function norm(color) {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = '#000';
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, 1, 1);
    var d = ctx.getImageData(0, 0, 1, 1).data;
    return { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
  }
  function lum(c) {
    var f = [c.r, c.g, c.b].map(function (v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2];
  }
  function ratio(a, b) {
    var A = lum(a), B = lum(b);
    return (Math.max(A, B) + 0.05) / (Math.min(A, B) + 0.05);
  }
  // v3 的背景是渐变（.shell .canvas），不是纯色：不能再靠 backgroundColor 找底。
  // 做法是把所有半透明层按 alpha 从下往上合成到一个不透明底上，
  // 这样测出来的是眼睛实际看到的颜色。
  // 垫在最底下的不透明色：由启动参数按昼夜给（夜里 #101d18，白天 #c6dacd）
  var canvasBase = norm(window.__canvasBase || '#c6dacd');
  function composite() {
    var layers = [];
    for (var i = arguments.length - 1; i >= 0; i--) layers.push(arguments[i]);
    var out = { r: canvasBase.r, g: canvasBase.g, b: canvasBase.b, a: 1 };
    layers.forEach(function (c) {
      if (!c) return;
      var a = c.a;
      out.r = c.r * a + out.r * (1 - a);
      out.g = c.g * a + out.g * (1 - a);
      out.b = c.b * a + out.b * (1 - a);
    });
    return out;
  }
  // 渐变没法直接取样，但可以从计算后的 backgroundImage 里把每个色标解析出来，
  // 按 alpha 加权求平均当作这一层的代表色。写死一个平均色会让暗色永远测不准。
  function avgGradient(image) {
    var stops = image.match(/rgba?\\([^)]+\\)/g);
    if (!stops || !stops.length) return null;
    var r = 0, g = 0, b = 0, a = 0;
    stops.forEach(function (s) {
      var p = s.replace(/[^0-9.,]/g, '').split(',').map(Number);
      var al = p.length > 3 ? p[3] : 1;
      r += p[0] * al; g += p[1] * al; b += p[2] * al; a += al;
    });
    if (!a) return null;
    return { r: r / a, g: g / a, b: b / a, a: a / stops.length };
  }
  function bgOf(el) {
    var chain = [];
    var node = el;
    while (node && node !== document.documentElement) {
      var cs = getComputedStyle(node);
      if (cs.backgroundImage && cs.backgroundImage !== 'none') {
        var avg = avgGradient(cs.backgroundImage);
        if (avg && avg.a > 0) chain.push(avg);
      }
      var c = norm(cs.backgroundColor);
      if (c.a > 0) chain.push(c);
      node = node.parentElement;
    }
    return composite.apply(null, chain);
  }

  // ── 1. 对比度（真实浏览器计算值）──
  var contrast = [];
  [['.bar__title', 4.5], ['.bar__hint', 4.5], ['.card__name', 4.5], ['.card__path', 4.5],
   ['.card__time', 4.5], ['.group__head', 4.5], ['.group__count', 4.5], ['.foot__status', 4.5],
   ['.foot__keys', 4.5], ['.find__input', 4.5], ['.intro__hint', 4.5], ['.srow__title', 4.5],
   ['.srow__meta', 4.5], ['.history__count', 4.5], ['.history__path', 4.5],
   ['.cell__sessions', 4.5], ['.group__add', 4.5], ['.hbtn--new', 4.5], ['.hbtn--close', 4.5],
   // 标题栏的终端选择：名字 10.5px 等宽，必须自己过一遍
   ['.term__name', 4.5], ['.term__item-name', 4.5], ['.term__item-tag', 4.5]].forEach(function (pair) {
    var el = document.querySelector(pair[0]);
    if (!el) return;
    var cs = getComputedStyle(el);
    var fg = norm(cs.color);
    var bg = bgOf(el);
    var size = parseFloat(cs.fontSize);
    var bold = parseInt(cs.fontWeight, 10) >= 700;
    var large = size >= 24 || (size >= 18.66 && bold);
    var need = large ? 3.0 : pair[1];
    var r = ratio(fg, bg);
    contrast.push({ sel: pair[0], ratio: Math.round(r * 100) / 100, need: need,
                    pass: r >= need - 0.005 });
  });
  // 「路径失效」提示：只在坏卡片上有，单独测
  var warn = document.querySelector('.card.is-broken .card__time');
  if (warn) {
    var rw = ratio(norm(getComputedStyle(warn).color), bgOf(warn.closest('.card')));
    contrast.push({ sel: '.card.is-broken .card__time', ratio: Math.round(rw * 100) / 100, need: 4.5, pass: rw >= 4.5 - 0.005 });
  }
  out.contrast = contrast;

  // ── 2. 点击区（WCAG 2.2 ≥24px）──
  var sizes = [];
  ['.card', '.tool', '.cell__sessions', '.cell--add', '.group__add', '.hbtn', '.term', '.switch'].forEach(function (sel) {
    var el = document.querySelector(sel);
    if (!el) return;
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return;   // 隐藏元素不参与判定
    sizes.push({ sel: sel, w: Math.round(r.width), h: Math.round(r.height),
                 pass: r.width >= 24 && r.height >= 24 });
  });
  out.targets = sizes;
  // ── 2b. 遮挡实测：胶囊与悬停工具各有自己的命中区，谁都不许盖住谁 ──
  // 只量矩形分得开还不够——真正要证的是「点下去落到哪个元素」。
  var hits = {};
  var cell = document.querySelector('.cell.has-sessions');
  if (cell) {
    var pillEl = cell.querySelector('.cell__sessions');
    var starEl = cell.querySelector('.tool--fav');
    var nameEl = cell.querySelector('.card__name');
    function centerOf(el) {
      var r = el.getBoundingClientRect();
      return [r.left + r.width / 2, r.top + r.height / 2];
    }
    function hitName(el) {
      if (!el) return 'none';
      var classes = (el.className && el.className.baseVal !== undefined ? el.className.baseVal : el.className) || '';
      return el.tagName.toLowerCase() + '.' + String(classes).split(' ')[0];
    }
    function hitsWithin(el) {
      var c = centerOf(el);
      var hit = document.elementFromPoint(c[0], c[1]);
      return { hit: hitName(hit), own: !!(hit && el.contains(hit)) };
    }
    hits.pill = hitsWithin(pillEl);
    hits.name = hitsWithin(nameEl);
    // 工具只在悬停时才可见；先强制显示再量，否则量到的是它下面的铺面按钮
    if (starEl) {
      var group = starEl.parentElement;
      group.style.opacity = '1';
      group.style.pointerEvents = 'auto';
    }
    hits.star = hitsWithin(starEl);
    var pr = pillEl.getBoundingClientRect();
    var tr = cell.querySelector('.cell__tools').getBoundingClientRect();
    hits.pillTop = Math.round(pr.top);
    hits.toolsBottom = Math.round(tr.bottom);
    hits.verticalGap = Math.round(pr.top - tr.bottom);
    // 名字区命中铺面按钮是正确结果（点文字＝开新会话），不是遮挡
    hits.nameOpensCard = hits.name.hit.indexOf('card-open') >= 0;
    hits.pass = hits.pill.own && hits.star.own && hits.nameOpensCard && hits.verticalGap > 0;
  }
  out.hitTest = hits;

  // 历史页默认 hidden，量之前必须临时显示，否则拿到 0×0
  var histEl = document.getElementById('history');
  var histWasHidden = histEl.hidden;
  histEl.hidden = false;
  var histRowProbe = document.createElement('div');
  histRowProbe.innerHTML = '<button class="srow"><span class="srow__title">x</span><span class="srow__meta"><span class="srow__count">1 条</span><span class="srow__time">今天</span></span></button>';
  document.getElementById('hlist').appendChild(histRowProbe);
  var hr = histRowProbe.querySelector('.srow').getBoundingClientRect();
  out.historyRowHeight = Math.round(hr.height);
  out.historyRowTargetPass = hr.height >= 24;
  histRowProbe.remove();
  histEl.hidden = histWasHidden;

  // ── 3. 溢出 ──
  var st = document.getElementById('stack');
  out.overflow = {
    docW: document.documentElement.scrollWidth, viewW: window.innerWidth,
    horizontal: document.documentElement.scrollWidth > window.innerWidth + 1,
    stackScroll: st.scrollWidth > st.clientWidth
  };

  // 关键：必须在禁用过渡后读取计算样式，否则读到的是动画中间值（会假报「状态未生效」）。
  var noTrans = document.createElement('style');
  noTrans.textContent = '*,*::before,*::after{transition:none !important;animation:none !important;}';
  document.head.appendChild(noTrans);

  // 基线必须取自干净、未选中、无状态的卡片
  var probeCard = document.querySelector('.card:not(.is-broken)');
  probeCard.classList.remove('is-selected');
  probeCard.removeAttribute('data-state');

  var cv2 = document.createElement('canvas'); cv2.width = cv2.height = 1;
  var ctx2 = cv2.getContext('2d', { willReadFrequently: true });
  function rgbOf(c) {
    ctx2.clearRect(0, 0, 1, 1); ctx2.fillStyle = '#000'; ctx2.fillStyle = c;
    ctx2.fillRect(0, 0, 1, 1);
    var d = ctx2.getImageData(0, 0, 1, 1).data;
    return d[0] + ',' + d[1] + ',' + d[2];
  }
  function snap() {
    var cs = getComputedStyle(probeCard);
    // 命门：卡片的状态（载入/成功/失败/选中）从 v3 起画在 ::before 的渐变描边上，
    // 只读卡片本体的话四个状态全被误判成「没生效」。
    var pb = getComputedStyle(probeCard, '::before');
    return rgbOf(cs.borderTopColor) + '|' + rgbOf(cs.backgroundColor) + '|' + cs.borderTopStyle +
      '|' + pb.backgroundImage + '|' + pb.opacity + '|' + cs.boxShadow;
  }
  var baseSnap = snap();
  var states = {};
  probeCard.setAttribute('data-state', 'loading'); states.loading = snap() !== baseSnap;
  probeCard.setAttribute('data-state', 'success'); states.success = snap() !== baseSnap;
  probeCard.setAttribute('data-state', 'error');   states.error   = snap() !== baseSnap;
  probeCard.removeAttribute('data-state');
  probeCard.classList.add('is-selected');          states.selected = snap() !== baseSnap;
  probeCard.classList.remove('is-selected');
  states.returnsToBase = snap() === baseSnap;

  var brokenCard = document.querySelector('.card.is-broken');
  states.broken = brokenCard ? getComputedStyle(brokenCard).borderTopStyle === 'dashed' : null;

  noTrans.remove();
  out.states = states;
  out.stateCount = ['loading', 'success', 'error', 'selected', 'broken'].filter(function (k) {
    return states[k] === true;
  }).length;

  // ── 5. 样式表规则核验 ──
  // 本地 file:// 下 cssRules 会被标为跨源不可读（实测 cssReadable=false），
  // 所以可访问性纪律改由「实际计算样式」判定，源码静态检查在 build 里另做。
  var rules = [];
  try {
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      Array.prototype.forEach.call(sheet.cssRules || [], function (r) { rules.push(r.cssText || ''); });
    });
  } catch (e) {}
  var cssAll = rules.join(String.fromCharCode(10));
  out.cssReadable = rules.length > 0;

  // 焦点轮廓：真的把焦点给一个卡片，看 outline-width 是否非 0
  var focusProbe = document.createElement('button');
  focusProbe.className = 'card';
  focusProbe.textContent = 'focus';
  probeCard.parentElement.appendChild(focusProbe);
  focusProbe.focus();
  var fcs = getComputedStyle(focusProbe);
  var focusMatches = focusProbe.matches(':focus-visible');
  out.focus = {
    isFocusVisible: focusMatches,
    outlineWidth: parseFloat(fcs.outlineWidth) || 0,
    outlineColor: fcs.outlineColor,
    // :focus-visible 在无键盘交互时可能不匹配，属正常；有匹配就必须有轮廓
    hasOutlineRule: !focusMatches || (parseFloat(fcs.outlineWidth) || 0) >= 2,
    reducedMotionDeclared: window.matchMedia('(prefers-reduced-motion: reduce)').media !== 'not all',
    usesGlassTokens: getComputedStyle(document.documentElement).getPropertyValue('--lg-color-violet').trim().length > 0
  };
  focusProbe.remove();


  // ── 7. emoji 残留 + 图标类型 ──
  // 用码点范围判断，避免嵌套转义把正则写坏
  function isEmojiChar(ch) {
    var c = ch.codePointAt(0);
    return (c >= 0x1F300 && c <= 0x1FAFF) ||
           (c >= 0x2600  && c <= 0x27BF)  ||
           (c >= 0x2B00  && c <= 0x2BFF)  ||
           (c >= 0xFE00  && c <= 0xFE0F)  ||
           (c >= 0x1F000 && c <= 0x1F2FF);
  }
  var found = [];
  document.querySelectorAll('body *').forEach(function (el) {
    Array.prototype.forEach.call(el.childNodes, function (n) {
      if (n.nodeType !== 3) return;
      Array.from(n.textContent).forEach(function (ch) {
        if (isEmojiChar(ch) && found.indexOf(el.className || el.tagName) < 0) {
          found.push(el.className || el.tagName);
        }
      });
    });
  });
  out.emojiText = found;
  out.iconsAreSvg = Array.prototype.every.call(
    document.querySelectorAll('.card__ico, .group__add svg, .find__icon, .cell__sessions svg, .hbtn svg'),
    function (el) { return el.tagName.toLowerCase() === 'svg'; });

  // ── 8. 圆角刻度纪律：14px 卡片 / 12px 凹槽 / 8–10px 小控件 ──
  // 防止启动器专属覆盖未加载，或旧版胶囊搜索框意外回归。
  var radii = [];
  ['.card', '.cell--add', '.tool', '.find', '.toast'].forEach(function (sel) {
    var el = document.querySelector(sel);
    if (el) radii.push({ sel: sel, radius: getComputedStyle(el).borderTopLeftRadius });
  });
  out.radii = radii;
  var cardRadius = document.querySelector('.card') ? getComputedStyle(document.querySelector('.card')).borderTopLeftRadius : '';
  // 纸卡与纸槽共用 --p-r-card：只校验两者一致且有圆角，不再钉死具体像素
  out.radiusScale = {
    cardRadius: cardRadius,
    cardIsRounded: parseFloat(cardRadius) > 0,
    findMatchesWell: (function () {
      var f = document.querySelector('.find');
      if (!f) return null;
      return getComputedStyle(f).borderTopLeftRadius === cardRadius;
    })()
  };

  // ── 9. 动画属性纪律（读不到样式表时留空，由源码静态检查兜底）──
  out.animatedProps = [];

  // 量的过程借用了终端菜单，还回去，别影响后面的宽高与溢出量测
  if (termBtn && !termMenuWasOpen) termBtn.click();

  return JSON.stringify(out);
})();
"""

final class Check: NSObject, WKNavigationDelegate {
    var web: WKWebView!

    func start() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 760, height: 620), configuration: cfg)
        web.navigationDelegate = self
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 620),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = web
        win.orderBack(nil)
        let arg = uiDir.absoluteString
        if arg.hasPrefix("http") {
            web.load(URLRequest(url: URL(string: arg + "/index.html")!))
        } else {
            web.loadFileURL(uiDir.appendingPathComponent("index.html"), allowingReadAccessTo: uiDir)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8)!
        // 主题与合成底色必须先定：页面首帧可能按系统外观选了另一套
        let setup = "document.documentElement.dataset.theme = '\(theme)';" +
                    "try { localStorage.setItem('pi.launcher.theme', '\(theme)'); } catch (e) {}" +
                    "window.__canvasBase = '\(canvasBaseHex)';"
        webView.evaluateJavaScript(setup) { _, _ in
        webView.evaluateJavaScript("window.__render(\(json));") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript(probe) { result, err in
                    if let err { print("PROBE ERROR: \(err)") }
                    if let s = result as? String {
                        print(s)
                        self.checkWidths()
                    } else {
                        print("PROBE returned: \(String(describing: result))")
                        exit(1)
                    }
                }
            }
        }
        }
    }

    let widths: [Double] = [480, 560, 760, 1024]
    var wIndex = 0

    func checkWidths() {
        guard wIndex < widths.count else { print("WIDTH-CHECK DONE"); exit(0) }
        let w = widths[wIndex]; wIndex += 1
        web.frame = CGRect(x: 0, y: 0, width: w, height: 620)
        web.window?.setContentSize(NSSize(width: w, height: 620))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.web.evaluateJavaScript(
                "JSON.stringify({w:\(Int(w)),docW:document.documentElement.scrollWidth,viewW:window.innerWidth,stackOverflow:document.getElementById('stack').scrollWidth>document.getElementById('stack').clientWidth})"
            ) { v, _ in
                print("width \(Int(w)): \(v ?? "?")")
                self.checkWidths()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let c = Check()
DispatchQueue.main.async { c.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("TIMEOUT"); exit(1) }
app.run()
