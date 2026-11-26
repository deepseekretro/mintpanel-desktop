// 启动一个「可见的」Camoufox 给人工操作（2 核 + HD400 + 1366x768 + 已登录态）
// 常驻：进程 detached，node 不退出（浏览器活着），日志 ~/camoufox/ui.log
// 用法: TMPDIR=$HOME/tmp node --experimental-sqlite cf-ui.mjs [起始URL]
import { launchOptions } from 'camoufox-js';
import { firefox } from 'playwright-core';
import fs from 'node:fs';

globalThis.Deno = {}; // 绕开 better-sqlite3 的 SIGSEGV，走 node:sqlite（需 --experimental-sqlite）

const H = process.env.HOME;
const PROFILE = `${H}/camoufox/profile-ui`;
const START = process.argv[2] || 'https://dash.pingless.org/shrtfly';
// CF_SECOND=<url>：再开一个独立窗口（window.open 带 features，任务栏会多一条）
const SECOND = process.env.CF_SECOND || '';
fs.mkdirSync(PROFILE, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const cookies = (() => {
  try { return JSON.parse(fs.readFileSync(`${H}/pw/cookies.json`, 'utf8')); } catch { return []; }
})();

// 浏览器路径：CF_EXE > ~/cf-new（手动装的新版）> 缓存里的 pin 版
function pickExe() {
  if (process.env.CF_EXE && fs.existsSync(process.env.CF_EXE)) return process.env.CF_EXE;
  const bases = [`${H}/cf-new`, `${H}/.cache/camoufox/browsers/custom`];
  for (const base of bases) {
    if (!fs.existsSync(base)) continue;
    for (const d of fs.readdirSync(base)) {
      for (const cand of [`${base}/${d}/camoufox-bin`, `${base}/${d}/camoufox/camoufox-bin`, `${base}/camoufox-bin`]) {
        if (fs.existsSync(cand)) return cand;
      }
    }
  }
  const off = `${H}/.cache/camoufox/browsers/official`;
  const dirs = fs.existsSync(off) ? fs.readdirSync(off).sort() : [];
  return dirs.length ? `${off}/${dirs[dirs.length - 1]}/camoufox-bin` : undefined;
}
const EXE = pickExe();

const opts = await launchOptions({
  os: 'linux',
  headless: false,
  humanize: false, // 人工操作，别让拟人化干扰
  locale: 'en-IN',            // 出口 IP 在 Bengaluru(IN)，语言跟 IP 走，不显示中文
  timezone: 'Asia/Kolkata',   // 出口 IP 时区（ipinfo.io 报的 timezone）
  screen: { width: 1366, height: 768 },
  window: [1360, 760],
  executable_path: EXE, // 可指到手动安装的任意版本
  user_data_dir: PROFILE,
  i_know_what_im_doing: true,
  // 不要 camoufox-js 的默认 addon（UBO）：它的路径在本机是 .cache/camoufox/addons/UBO，
  // 我们不用它的 addon 机制（扩展直接放 profile-ui/extensions/ 里），留着反而会
  // 因为路径校验失败抛 InvalidAddonPath 把整个 launchOptions 打断。
  exclude_addons: ['UBO'],
  firefox_user_prefs: {
    // 容器 pids 很紧（僵尸 160+），尽量少开内容进程
    'dom.ipc.processCount': 1,
    'dom.ipc.processCount.file': 1,
    'fission.autostart': false,
    'gfx.webrender.software': true,
    'dom.maxHardwareConcurrency': 2,
    'intl.accept_languages': 'en-IN,en',
    'dom.disable_open_during_load': false, // 允许脚本把第二页拆成独立窗口
    // 关键的「参数级」窗口行为：脚本 window.open（带 features）走普通新窗口，
    // 而不是精简 popup —— 效果等同手动把 tab 拖出来。restriction=2（默认）表示
    // 只对带 features 的脚本调用生效，页面普通链接仍按 open_newwindow 默认（新 tab）。
    'browser.link.open_newwindow': 2,
    'browser.link.open_newwindow.restriction': 2,
  },
  // 指纹要和真实桌面自洽：Xvfb 是 1920x1080，底部 tint2 占 30px。
  // 关掉 viewport 后 innerWidth/Height 随窗口实时变化，若这里还报 1366x768，
  // 就会出现 innerHeight(884) > screen.availHeight(728) 这种明显穿帮。
  // 所以 screen 用真实值，并且**不覆盖 window.outer***，让真实窗口尺寸透出。
  config: {
    'navigator.hardwareConcurrency': 2,
    'navigator.maxTouchPoints': 0,
    'screen.width': 1920, 'screen.height': 1080,
    'screen.availWidth': 1920, 'screen.availHeight': 1050,
    'screen.colorDepth': 24, 'screen.pixelDepth': 24,
  },
  env: {
    ...process.env, TMPDIR: `${H}/tmp`, TZ: 'Asia/Kolkata', DISPLAY: process.env.DISPLAY || ':2',
    LD_LIBRARY_PATH: [process.env.LD_LIBRARY_PATH, `${H}/opt/desktop/lib`, `${H}/gui/lib2`].filter(Boolean).join(':'),
    ...(fs.existsSync(`${H}/opt/desktop/etc/fonts/fonts.conf`) ? { FONTCONFIG_PATH: `${H}/opt/desktop/etc/fonts`, FONTCONFIG_FILE: `${H}/opt/desktop/etc/fonts/fonts.conf` } : {}),
    LIBGL_ALWAYS_SOFTWARE: '1', LIBGL_DRIVERS_PATH: `${H}/gui/lib2/dri`,
    MESA_LOADER_DRIVER_OVERRIDE: 'swrast', MOZ_X11_EGL: '0',
    MOZ_DISABLE_CONTENT_SANDBOX: '1', MOZ_DISABLE_GPU_SANDBOX: '1',
    MOZ_DISABLE_SOCKET_PROCESS_SANDBOX: '1', MOZ_DISABLE_RDD_SANDBOX: '1',
    MOZ_DISABLE_GMP_SANDBOX: '1', MOZ_DISABLE_UTILITY_SANDBOX: '1',
  },
});

// Playwright 默认给主 page 一个固定 viewport（1280x720），窗口再大页面也只渲染那一块，
// 看起来就是「主窗口渲染区域不完整」。置 null 让它跟随窗口实际尺寸；
// window.open 出来的窗口本来就不受这个 viewport 管，所以之前只有它正常。
opts.viewport = null;
opts.noDefaultViewport = true;

// 确保 uBlock Origin 与 Cookie-Editor 默认固定到浏览器工具栏 (nav-bar)
try {
  const prefsPath = `${PROFILE}/prefs.js`;
  const widgets = ['ublock0_raymondhill_net-browser-action', '_c3c10168-4186-445c-9c5b-63f12b8e2c87_-browser-action'];
  let txt = fs.existsSync(prefsPath) ? fs.readFileSync(prefsPath, 'utf8') : '';
  const re = /user_pref\("browser\.uiCustomization\.state",\s*"(.*)"\);/;
  const m = txt.match(re);
  let st;
  if (m) {
    st = JSON.parse(JSON.parse('"' + m[1] + '"'));
  } else {
    st = {
      placements: {
        'widget-overflow-fixed-list': [],
        'unified-extensions-area': [],
        'nav-bar': ['back-button','forward-button','stop-reload-button','customizableui-special-spring1','vertical-spacer','urlbar-container','customizableui-special-spring2','downloads-button','fxa-toolbar-menu-button','reset-pbm-toolbar-button','unified-extensions-button','new-tab-button','alltabs-button','personal-bookmarks'],
        'toolbar-menubar': ['menubar-items'],
        'TabsToolbar': ['tabbrowser-tabs'],
        'vertical-tabs': [],
        'PersonalToolbar': []
      },
      seen: ['reset-pbm-toolbar-button','developer-button'],
      dirtyAreaCache: ['unified-extensions-area','nav-bar','TabsToolbar'],
      currentVersion: 24,
      newElementCount: 2
    };
  }
  st.placements = st.placements || {};
  st.placements['nav-bar'] = st.placements['nav-bar'] || ['back-button','forward-button','stop-reload-button','urlbar-container','unified-extensions-button'];
  st.placements['unified-extensions-area'] = (st.placements['unified-extensions-area'] || []).filter((w) => !widgets.includes(w));
  st.seen = st.seen || [];
  let changed = !m;
  const uebIdx = st.placements['nav-bar'].indexOf('unified-extensions-button');
  for (const w of widgets) {
    if (!st.placements['nav-bar'].includes(w)) {
      if (uebIdx >= 0) st.placements['nav-bar'].splice(uebIdx, 0, w);
      else st.placements['nav-bar'].push(w);
      changed = true;
    }
    if (!st.seen.includes(w)) { st.seen.push(w); changed = true; }
  }
  if (changed) {
    const line = `user_pref("browser.uiCustomization.state", ${JSON.stringify(JSON.stringify(st))});`;
    txt = m ? txt.replace(re, line) : (txt ? txt.trimEnd() + '\n' + line + '\n' : line + '\n');
    fs.mkdirSync(PROFILE, { recursive: true });
    fs.writeFileSync(prefsPath, txt, 'utf8');
  }
} catch {}

log('launching', opts.executablePath);
const ctx = await firefox.launchPersistentContext(PROFILE, opts);
log('ctx ok');
if (cookies.length) {
  try { await ctx.addCookies(cookies); log('cookies', cookies.length); } catch (e) { log('cookies 失败', e.message.slice(0, 90)); }
}
const REPLAY = `${H}/camoufox/replay.txt`;
const RESUME = (() => {
  try { const u = fs.readFileSync(REPLAY, 'utf8').trim(); if (u) { fs.unlinkSync(REPLAY); return u; } } catch { }
  return '';
})();
const page = ctx.pages()[0] || await ctx.newPage();
try {
  await page.goto(RESUME || START, { waitUntil: 'domcontentloaded', timeout: 45000 });
  log('opened', (RESUME ? 'RESUME ' : '') + page.url().slice(0, 70));
  try {
    const fp = await page.evaluate(() => [navigator.language, (navigator.languages || []).join(','),
      Intl.DateTimeFormat().resolvedOptions().timeZone, new Date().toString().slice(4, 33)].join(' | '));
    log('locale', fp);
  } catch { }
} catch (e) { log('goto 失败', e.message.slice(0, 90)); }
// ---- 第二个窗口（可选）：window.open 带 features → 独立窗口而不是 tab ----
if (SECOND) {
  const before = ctx.pages().length;
  const ok = await page.evaluate((u) => {
    // 不加 popup 关键字：带 popup 会变成「精简弹窗」外观（没有工具栏/地址栏），
    // 只给宽高时 Firefox 开的是完整外观的新窗口。
    try { return !!window.open(u, '_blank', 'width=1200,height=760'); } catch { return false; }
  }, SECOND).catch(() => false);
  await new Promise((r) => setTimeout(r, 3000));
  log('second', ok ? 'open' : 'blocked', 'pages', before, '->', ctx.pages().length);
  for (const [i, p] of ctx.pages().entries()) {
    const b = await p.evaluate(() => [window.outerWidth, window.outerHeight, window.screenX, window.screenY]).catch(() => null);
    log(` win${i}`, (p.url() || '').slice(0, 45), b ? `${b[0]}x${b[1]}@${b[2]},${b[3]}` : '');
  }
}


// ===== 动态命令通道（不需要重启浏览器）=====
// 往 ~/camoufox/cmds/*.mjs 丢一个文件，内容就是函数体，可用：
//   ctx / pages (Playwright) / fs / log / sleep / H
// 结果写到同名 .out。这样改行为只要发命令，不用杀浏览器。
const CMD_DIR = `${H}/camoufox/cmds`;
fs.mkdirSync(CMD_DIR, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function runCmds() {
  let files = [];
  try { files = fs.readdirSync(CMD_DIR).filter((f) => f.endsWith('.mjs')); } catch { return; }
  for (const f of files) {
    const src = `${CMD_DIR}/${f}`, dst = `${CMD_DIR}/${f.replace(/\.mjs$/, '.out')}`;
    let code = '';
    try { code = fs.readFileSync(src, 'utf8'); } catch { continue; }
    try { fs.unlinkSync(src); } catch { }
    try {
      const fn = new Function('ctx', 'pages', 'fs', 'log', 'sleep', 'H', `return (async () => { ${code}\n })()`);
      const r = await fn(ctx, ctx.pages(), fs, log, sleep, H);
      fs.writeFileSync(dst, 'OK\n' + (typeof r === 'string' ? r : JSON.stringify(r, null, 1)));
    } catch (e) {
      fs.writeFileSync(dst, 'ERR\n' + ((e && e.stack) || String(e)));
    }
    log('[cmd]', f, '完成');
  }
}
setInterval(() => { runCmds().catch(() => { }); }, 900);

// 自检（CF_SELFCHECK=1）：每 5s 打印一次页面渲染区尺寸，用来验证窗口缩放是否跟随
if (process.env.CF_SELFCHECK === '1') {
  setInterval(async () => {
    for (const [i, p] of ctx.pages().entries()) {
      const d = await p.evaluate(() => [innerWidth, innerHeight, outerWidth, outerHeight,
        screen.width, screen.height, screen.availWidth, screen.availHeight, devicePixelRatio]).catch(() => null);
      if (d) log(`self${i} inner=${d[0]}x${d[1]} outer=${d[2]}x${d[3]} screen=${d[4]}x${d[5]} avail=${d[6]}x${d[7]} dpr=${d[8]}`);
    }
  }, 5000);
}


// ================= 广告链自动点击（AUTO=1 开启，默认关） =================
// 实测链路（2026-11-20 pingless 账本走通一次）：
//   shrtfly 点 Generate → /shrtslug/<id>「Continue for free」
//   → 广告站 1..N，每站典型序列：
//        BEGIN / Start  →  Turnstile 容器（点中心即出 token，页面上没有 checkbox）
//        →  VERIFY  →  「Please wait…100%」→ CLICK HERE TO VERIFY
//        →  NEXT POST / Go next / Next step
//   → 最终回到 dash.pingless.org/shrtfly，余额 +18
// 注意：Turnstile 的复选框在页面里根本不存在（.cf-turnstile 内只有空 div + hidden input），
//       点容器中心即可触发 token 生成，所以「先点 cloudflare 再点 VERIFY」＝ 先点容器再点按钮。
const AUTO = process.env.AUTO === '1';
const GEN_GAP = +(process.env.CLICK_GAP || 25000); // Generate 冷却
const TICK = +(process.env.AUTO_GAP || 2500);      // tick 间隔
const SAME_GAP = +(process.env.SAME_GAP || 6000);  // 同一个按钮重复点击的最小间隔
const TS_GAP = +(process.env.TS_GAP || 15000);     // Turnstile 重试间隔
const logA = (...a) => log('[auto]', ...a);

// 点了会跑偏的按钮（订阅/商城/隐私）
const BAN = /premium|subscri|upgrade|sign\s?up|sign\s?in|log\s?in|register|pricing|buy\b|shop|cart|newsletter|privacy|cookie|terms/i;
// 按出现顺序排列，先匹配到的先点
const ORDER = [
  /^\s*click\s+here\s+to\s+verify\s*$/i,
  /^\s*verify(\s+now)?\s*$/i,
  /^\s*next\s+post\s*$/i,
  /^\s*begin\s*$/i,
  /^\s*start\s*$/i,
  /^\s*go\s+next\s*$/i,
  /^\s*next\s+step\s*$/i,
  /^\s*continue(\s+for\s+free)?\s*$/i,
  /^\s*(proceed|get\s+link|unlock|claim)\s*$/i,
];

let lastKey = ''; let lastKeyAt = 0; let lastGenAt = 0; let lastTsAt = 0; let wasAd = false;
let round = 0; let lastWaitLog = 0;
const PAGE_TIMEOUT = +(process.env.PAGE_TIMEOUT || 60000);
let trackedPageUrl = '';
let trackedPageAt = 0;

async function checkPageTimeout(page) {
  const curUrl = page.url();
  if (curUrl !== trackedPageUrl) {
    trackedPageUrl = curUrl;
    trackedPageAt = Date.now();
    return false;
  }
  if (Date.now() - trackedPageAt < PAGE_TIMEOUT) return false;

  const sec = Math.round((Date.now() - trackedPageAt) / 1000);
  logA('页面停留超时(' + sec + 's)，history.back() 返回并重载继续', curUrl.slice(0, 60));
  lastKey = ''; lastKeyAt = 0; lastTsAt = 0; lastDumpUrl = '';
  dwellUntil.delete(curUrl);

  const nav = await page.goBack({ waitUntil: 'domcontentloaded', timeout: 15000 }).catch(() => null);
  if (!nav) {
    await page.goto('https://dash.pingless.org/shrtfly', { waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {});
  } else {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 15000 }).catch(() => {});
  }
  trackedPageUrl = page.url();
  trackedPageAt = Date.now();
  dwellUntil.delete(trackedPageUrl);
  return true;
}
// 每页进来先随机停留 3-5s 再动手（模拟人阅读；同一 URL 只停一次）
const DWELL_MIN = +(process.env.DWELL_MIN || 3000);
const DWELL_MAX = +(process.env.DWELL_MAX || 5000);
const dwellUntil = new Map();
function dwellOk(url) {
  if (!dwellUntil.has(url)) {
    const ms = DWELL_MIN + Math.random() * (DWELL_MAX - DWELL_MIN);
    dwellUntil.set(url, { at: Date.now() + ms, ms: Math.round(ms) });
    if (dwellUntil.size > 200) dwellUntil.clear();
    logA('dwell', Math.round(ms) + 'ms', url.slice(0, 44));
  }
  return Date.now() >= dwellUntil.get(url).at;
}

async function tsProbe(page) {
  return page.evaluate(() => {
    const w = document.querySelector('.cf-turnstile');
    if (!w) return null;
    const b = w.getBoundingClientRect();
    const inp = document.querySelector('[name=cf-turnstile-response]');
    return { x: Math.round(b.left + b.width / 2), y: Math.round(b.top + b.height / 2),
      w: Math.round(b.width), h: Math.round(b.height),
      tok: inp ? String(inp.value || '').length : 0 };
  }).catch(() => null);
}

const CLICKABLE_SEL = 'a,button,[role=button],input[type=submit],input[type=button],[onclick],[tabindex],[class*=btn],[class*=button],[class*=cta],[class*=link]';
async function listButtons(page) {
  return page.evaluate((sel) => {
    const out = [];
    const seen = new Set();
    const add = (el) => {
      if (seen.has(el)) return;
      seen.add(el);
      const r = el.getBoundingClientRect();
      if (r.width < 40 || r.height < 16) return;
      if (r.width > 900 && r.height > 70) return;          // 整块文章容器，不是按钮
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) < 0.1) return;
      const t = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ');
      if (!t || t.length > 40) return;
      out.push({ t, x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2),
        w: Math.round(r.width), h: Math.round(r.height), tag: el.tagName,
        dis: !!(el.disabled || el.getAttribute('aria-disabled') === 'true'),
        vis: r.top >= -4 && r.bottom <= innerHeight + 4 });
    };
    for (const el of document.querySelectorAll(sel)) add(el);
    // 兜底：cursor:pointer 的元素也算（广告站的按钮经常是 <div>/<span>）
    let n = 0;
    for (const el of document.querySelectorAll('div,span,li,p')) {
      if (++n > 1500) break;
      if (getComputedStyle(el).cursor === 'pointer') add(el);
    }
    return out;
  }, CLICKABLE_SEL).catch(() => []);
}

// 只把目标按钮带进视口（scrollIntoView），不做整页滚动；坐标在滚动后重新量
async function clickAt(page, label) {
  const pos = await page.evaluate(([t, sel]) => {
    const els = [...document.querySelectorAll(sel)];
    const el = els.find((e) => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ') === t)
      || [...document.querySelectorAll('div,span,li')].find((e) => getComputedStyle(e).cursor === 'pointer'
        && (e.innerText || '').trim().replace(/\s+/g, ' ') === t);
    if (!el) return null;
    el.scrollIntoView({ block: 'center' });
    const b = el.getBoundingClientRect();
    return { x: Math.round(b.left + b.width / 2), y: Math.round(b.top + b.height / 2), dis: !!(el.disabled || el.getAttribute('aria-disabled') === 'true') };
  }, [label, CLICKABLE_SEL]).catch(() => null);
  if (!pos || pos.dis) return false;
  await sleep(350);
  await page.mouse.move(pos.x, pos.y).catch(() => { });
  await page.mouse.down().catch(() => { });
  await page.mouse.up().catch(() => { });
  return true;
}

// 按钮配色识别（广告站通用指纹）
//   实测两种写法：
//     ① 渐变  linear-gradient(135deg,#2563eb,#1d4ed8)  → rgb() 221°/224° 蓝
//     ② 纯色  oklch(0.511 0.262 276.966)               → Tailwind v4 的 indigo/blue，H 是 oklch 刻度
//   注意 oklch 的 H 和 HSL 的 H 不是同一把尺：oklch 蓝在 235-305°，HSL 蓝在 200-245°。
//   只看 backgroundColor 也会漏：渐变按钮的 backgroundColor 是 transparent。
function colorHsl(str) {
  if (!str || str === 'none') return null;
  const nums = (str.match(/-?[\d.]+(?:e-?\d+)?/g) || []).map(parseFloat);
  if (nums.length < 3) return null;
  if (/oklch/i.test(str)) {
    const [L, C, H] = nums;
    return { h: ((H % 360) + 360) % 360, s: Math.min(100, Math.round(C * 350)), l: Math.round(L * 100), space: 'oklch' };
  }
  if (/oklab/i.test(str)) {
    const [L, a, b] = nums;
    let h = (Math.atan2(b, a) * 180) / Math.PI;
    if (h < 0) h += 360;
    return { h: Math.round(h), s: Math.min(100, Math.round(Math.hypot(a, b) * 350)), l: Math.round(L * 100), space: 'oklab' };
  }
  if (/hsla?\(/i.test(str)) return { h: nums[0], s: nums[1], l: nums[2], space: 'hsl' };
  const [r, g, b] = nums.slice(0, 3);
  const R = r / 255, G = g / 255, B = b / 255;
  const mx = Math.max(R, G, B), mn = Math.min(R, G, B), d = mx - mn;
  let h = 0;
  if (d > 0) { h = mx === R ? ((G - B) / d) % 6 : mx === G ? (B - R) / d + 2 : (R - G) / d + 4; h *= 60; if (h < 0) h += 360; }
  return { h: Math.round(h), s: mx ? Math.round((d / mx) * 100) : 0, l: Math.round(((mx + mn) / 2) * 100), space: 'rgb' };
}
function isBlueish(c) {
  if (!c) return false;
  if (c.space === 'oklch' || c.space === 'oklab') return c.h >= 235 && c.h <= 295 && c.s > 30 && c.l > 30 && c.l < 78;
  return c.h >= 200 && c.h <= 245 && c.s > 55 && c.l > 25 && c.l < 72;
}

// 蓝按钮 + 「下一步语义」：命中的元素打 data-cfnext，交给 clickMarked 滚动后点击
async function blueNext(page) {
  return page.evaluate((fnSrc) => {
    const colorHsl = eval('(' + fnSrc + ')');
    const hueBlue = (c) => {
      if (!c) return false;
      if (c.space === 'oklch' || c.space === 'oklab') return c.h >= 235 && c.h <= 295 && c.s > 30 && c.l > 30 && c.l < 78;
      return c.h >= 200 && c.h <= 245 && c.s > 55 && c.l > 25 && c.l < 72;
    };
    const SEM = /next|continue|go\b|proceed|verify|begin|start|step|click|enter|visit|open|launch|resume|read/i;
    const BTNCLS = /btn|cta|primary|button/i;
    // 「Scroll down to continue」只是提示条：点了只滚动，不算下一步。有别的候选时优先别它。
    const SCROLLHINT = /scroll/i;
    document.querySelectorAll('[data-cfnext]').forEach((e) => e.removeAttribute('data-cfnext'));
    const cands = [];
    for (const el of document.querySelectorAll('a,button,[role=button],div,span')) {
      const b = el.getBoundingClientRect();
      if (b.width < 120 || b.width > 700 || b.height < 40 || b.height > 90) continue;
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') continue;
      const img = st.backgroundImage || '';
      const stops = (img.match(/(?:rgb|oklch|oklab|hsl)a?\([^)]*\)/g) || []).map(colorHsl).filter(Boolean);
      const blue = hueBlue(colorHsl(st.backgroundColor)) || stops.some(hueBlue);
      if (!blue) continue;
      const t = (el.innerText || '').trim().replace(/\s+/g, ' ');
      if (!t || t.length > 40) continue;
      if (!SEM.test(t) && !(BTNCLS.test(String(el.className)) && stops.length)) continue;
      const pri = /next\s*step|next\s*post|go\s*next|continue|proceed|verify|begin|start|open/i.test(t) ? 3 : 1;
      cands.push({ el, t, y: b.top, hint: SCROLLHINT.test(t), score: pri + (b.top >= 0 && b.bottom <= innerHeight ? 1 : 0) });
    }
    if (!cands.length) return null;
    const real = cands.filter((c) => !c.hint);
    const pool = real.length ? real : cands;   // 只有滚动提示时才退而求其次
    pool.sort((a, b) => b.score - a.score || a.y - b.y);
    cands.length = 0;
    cands.push(...pool);
    cands[0].el.setAttribute('data-cfnext', '1');
    return { t: cands[0].t, n: cands.length };
  }, colorHsl.toString()).catch(() => null);
}

// 点被 data-cfnext 标记的元素：先滚进视口，再重新量坐标（视口外不滚动就点不到）
async function clickMarked(page) {
  const pos = await page.evaluate(() => {
    const el = document.querySelector('[data-cfnext]');
    if (!el) return null;
    el.scrollIntoView({ block: 'center' });
    const b = el.getBoundingClientRect();
    return { x: Math.round(b.left + b.width / 2), y: Math.round(b.top + b.height / 2), w: Math.round(b.width), h: Math.round(b.height), inView: b.top >= 0 && b.bottom <= innerHeight };
  }).catch(() => null);
  if (!pos) return null;
  await sleep(450);   // 等平滑滚动落位
  const pos2 = await page.evaluate(() => {
    const el = document.querySelector('[data-cfnext]');
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return { x: Math.round(b.left + b.width / 2), y: Math.round(b.top + b.height / 2) };
  }).catch(() => null);
  const p2 = pos2 || pos;
  await page.mouse.move(p2.x, p2.y).catch(() => { });
  await page.mouse.down().catch(() => { });
  await page.mouse.up().catch(() => { });
  return { x: p2.x, y: p2.y, inView: pos.inView, w: pos.w, h: pos.h };
}

// 状态机：只看当前页面「有什么」，就做对应动作
// 判定分两层，别混：
//   pingless.org 域（自己家页面）→ 只读 #genBtn 的文案：能点就是 "Generate Link & Earn Coins"，
//     冷却时文案变成 "Please wait 0h 10m 13s"。页面上别处的当日额度倒计时（如 03:29:01）不看。
//   广告站域 → 文案每次都换，必须靠「蓝配色 + 下一步语义」：rgb 蓝 200-245° / oklch 蓝 235-295°。
//   captcha   .cf-turnstile 存在但 token 为空            → 点容器中心（生成 token）
//   verify    有 VERIFY / CLICK HERE TO VERIFY            → 点它
//   nav       有 NEXT POST / Begin / Start / Go next / Next step → 点它
//   blue      背景是蓝渐变(#2563eb→#1d4ed8) + 文案带下一步语义 → 先滚进视口再点（站点通用）
//   loose     认得出是流程按钮（尺寸够大、含 next/continue 等）→ 点它（兜底）
//   idle      找不到任何按钮（等加载/等倒计时）            → 等；不做整页滚动
//   cooldown  同一按钮刚点过                              → 等下一次 tick
//   idle      什么都没有                                  → 等
let lastDumpUrl = '';
async function adState(page) {
  const ts = await tsProbe(page);
  const all = await listButtons(page);
  // 第一步永远是「找到当前页面的按钮文字」：每个新 URL 只 dump 一次，方便回看它当时看到了什么
  if (page.url() !== lastDumpUrl) {
    lastDumpUrl = page.url();
    logA('state=dump', page.url().slice(0, 46), '|', all.map((b) => b.t).join(' / ').slice(0, 320));
  }
  if (ts && ts.w > 60 && ts.tok === 0) return { s: 'captcha', ts, btns: all };
  const btns = all.filter((b) => !BAN.test(b.t));
  for (const re of ORDER) { const hit = btns.find((b) => re.test(b.t)); if (hit) return { s: 'button', hit, btns, tokLen: ts ? ts.tok : -1 }; }
  const blue = await blueNext(page);
  if (blue) return { s: 'blue', hit: blue, btns, tokLen: ts ? ts.tok : -1 };
  const loose = btns.find((b) => /verify|continue|next|begin|start|proceed|confirm|submit|human|click/i.test(b.t) && b.w >= 100 && b.h >= 30);
  if (loose) return { s: 'loose', hit: loose, btns, tokLen: ts ? ts.tok : -1 };
  return { s: 'idle', btns, tokLen: ts ? ts.tok : -1 };
}

async function adTick(page) {
  const url = page.url();
  const st = await adState(page);
  // 看到了什么先等一会儿再点（3-5s 随机）
  if (st.s !== 'idle' && !dwellOk(url)) return 'dwell';
  switch (st.s) {
    case 'captcha': {
      if (Date.now() - lastTsAt < TS_GAP) return 'cooldown';
      lastTsAt = Date.now();
      await page.evaluate(() => { const w = document.querySelector('.cf-turnstile'); if (w) w.scrollIntoView({ block: 'center' }); }).catch(() => { });
      await sleep(300);
      const p2 = await tsProbe(page);
      if (!p2) return 'idle';
      await page.mouse.move(p2.x, p2.y).catch(() => { });
      await page.mouse.down().catch(() => { });
      await page.mouse.up().catch(() => { });
      logA('state=captcha click', p2.x + ',' + p2.y, 'tok→', url.slice(0, 42));
      return 'captcha';
    }
    case 'blue': {
      const key = url.slice(0, 100) + '|blue|' + st.hit.t;
      if (key === lastKey && Date.now() - lastKeyAt < SAME_GAP) return 'cooldown';
      const pos = await clickMarked(page);
      if (!pos) return 'disabled';
      lastKey = key; lastKeyAt = Date.now();
      logA('state=blue', JSON.stringify(st.hit.t), 'y=' + pos.y, 'inView=' + pos.inView, url.slice(0, 40));
      return 'clicked';
    }
    case 'button':
    case 'loose': {
      const hit = st.hit;
      const key = url.slice(0, 100) + '|' + hit.t;
      if (key === lastKey && Date.now() - lastKeyAt < SAME_GAP) return 'cooldown';
      if (!(await clickAt(page, hit.t))) return 'disabled';
      lastKey = key; lastKeyAt = Date.now();
      logA('state=' + st.s, JSON.stringify(hit.t), 'y=' + hit.y, 'tok=' + st.tokLen, url.slice(0, 40));
      return 'clicked';
    }
    default:
      return 'idle';
  }
}

async function autoTick() {
  const pages = ctx.pages().filter((p) => !p.isClosed());
  // 0) 广告站的 window.open 弹窗：只保留预期的那几张（pingless + 可选第二窗口）
  //    广告链本身只在单页内导航，多出来的都是弹窗，直接关。
  const keepN = 2; // 硬编码 2：afk + 广告窗口，避免 SECOND 缺失时误关 afk
  if (pages.length > keepN) {
    const extras = pages.slice(keepN);
    for (const p of extras) {
      const u = p.url() || '';
      try { await p.close(); logA('关弹窗', u.slice(0, 60)); } catch { }
    }
    return;
  }
  // 1) 广告页优先（最新的那张）
  const ads = pages.filter((p) => !/pingless\.org/i.test(p.url()));
  if (ads.length) {
    wasAd = true;
    const targetAd = ads[ads.length - 1];
    if (await checkPageTimeout(targetAd)) return;
    const r = await adTick(targetAd);
    if (r === 'captcha' || r === 'clicked') await sleep(1200);
    return;
  }
  if (wasAd) {
    wasAd = false;
    lastKey = ''; lastKeyAt = 0; lastTsAt = 0; // 新一轮：清掉上一轮的按钮/Turnstile 冷却
    logA('广告链走完，回到 pingless');
  }
  // 2) 中间页
  const mid = pages.find((p) => /shrtslug|shortslug/i.test(p.url()));
  if (mid) {
    if (await checkPageTimeout(mid)) return;
    const btns = (await listButtons(mid)).filter((b) => !BAN.test(b.t));
    const hit = btns.find((b) => /continue|proceed|get\s+link|click|start/i.test(b.t));
    if (hit && (await clickAt(mid, hit.t))) logA('中间页', JSON.stringify(hit.t), mid.url().slice(0, 40));
    return;
  }
  // 3) 主页面：回到 shrtfly，清空非主页停留计时，等 Generate 恢复可用 → 再点，形成闭环
  trackedPageUrl = '';
  trackedPageAt = 0;
  const shop = pages.find((p) => /shrtfly/i.test(p.url()));
  if (!shop) return;
  const st = await shop.evaluate(() => {
    const b = document.getElementById('genBtn')
      || [...document.querySelectorAll('button,a')].find((e) => /generate/i.test((e.innerText || '')));
    const t = document.body ? document.body.innerText : '';
    const cre = t.match(/([\d.]+)\s*Credits/i);
    const wm = t.match(/(Please wait[^\n]{0,24})/i);
    const cd = t.match(/\b(\d{1,2}:\d{2}(:\d{2})?)\b/);
    return {
      has: !!b,
      btnText: b ? (b.innerText || '').trim().replace(/\s+/g, ' ') : '',
      cls: b ? String(b.className) : '',
      dis: !!(b && (b.disabled || b.getAttribute('aria-disabled') === 'true')),
      wait: wm ? wm[1] : null,
      countdown: cd ? cd[1] : null,
      credits: cre ? cre[1] : null,
    };
  }).catch(() => null);
  if (!st || !st.has) return;
  // 只看 Generate 按钮自身：页面别处的倒计时（如当日短链额度 03:59:17）不能拦，但按钮自己的
  // 文案会变成「Please wait 0h 10m 13s」——这才是真在冷却
  const blocked = st.dis
    || /disabled|pointer-events-none|is-loading/i.test(st.cls)
    || /please\s*wait|wait\s+\d|\d+\s*[hm]\s*\d+\s*s/i.test(st.btnText);
  if (blocked) {
    if (Date.now() - lastWaitLog > 8000) {
      lastWaitLog = Date.now();
      logA('等 Generate 可用', st.btnText.slice(0, 26) || st.cls.slice(0, 26), 'credits=' + st.credits);
    }
    return;
  }
  if (Date.now() - lastGenAt < GEN_GAP) return;
  if (!dwellOk('gen:' + st.credits)) return;
  lastGenAt = Date.now();
  round++;
  // 不用 page.click（会因浮层/toast 挡住的「可点击性检查」超时 8s），直接滚到按钮量坐标点
  const gp = await shop.evaluate(() => {
    const b = document.getElementById('genBtn') || [...document.querySelectorAll('a,button')].find((e) => /generate/i.test(e.innerText || ''));
    if (!b) return null;
    b.scrollIntoView({ block: 'center' });
    const r = b.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  }).catch(() => null);
  if (!gp) { logA('gen 失败: 找不到按钮'); return; }
  await sleep(300);
  await shop.mouse.move(gp.x, gp.y).catch(() => { });
  await shop.mouse.down().catch(() => { });
  await shop.mouse.up().catch(() => { });
  const gp2 = await shop.evaluate(() => {
    const b = document.getElementById('genBtn');
    return b ? (b.innerText || '').trim().slice(0, 26) : '';
  }).catch(() => '');
  logA('点了 Generate', JSON.stringify(gp2));
  logA('第', round, '轮 Generate, 起始 credits=' + st.credits);
}

if (AUTO) {
  logA('启动 gap', TICK, 'ms / gen 冷却', GEN_GAP, 'ms');
  const loop = async () => { try { await autoTick(); } catch (e) { logA('tick 异常', (e.message || '').slice(0, 90)); } };
  setInterval(loop, TICK);
  setTimeout(loop, 4000);
}

// 常驻，不主动关闭；进程被杀即结束
await new Promise(() => { });
