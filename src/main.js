// Sidebar — a minimal browser. Vertical tab sidebar that can hide completely
// (Cmd+S), no tab strip, no bookmarks bar, no toolbar.
const {
  app, BaseWindow, WebContentsView, Menu, ipcMain, screen, clipboard,
  shell, session, desktopCapturer, nativeTheme,
} = require('electron');
const path = require('path');
const fs = require('fs');

const SIDEBAR_W = 248;
const INSET = 8; // gap around the page while the sidebar is docked
const HOME = 'https://www.google.com';

app.setName('Sidebar');
// Look like plain Chrome so sites (Google sign-in etc.) don't treat us as an embedded browser.
app.userAgentFallback = app.userAgentFallback
  .replace(/\sElectron\/\S+/, '')
  .replace(/\s(Sidebar|sidebar-browser)\/\S+/i, '');

if (process.env.SB_TEST) app.setPath('userData', process.env.SB_TEST);
if (!app.requestSingleInstanceLock()) app.quit();

const STATE_FILE = () => path.join(app.getPath('userData'), 'state.json');

let win = null;
let sidebar = null;
let tabs = []; // { id, url, title, favicon, pinned, loading, view|null }
let activeId = null;
let nextId = 1;
let hidden = false;      // sidebar hidden by the user (Cmd+S)
let peek = false;        // hidden sidebar temporarily shown (mouse at left edge)
let forcePeek = false;   // shown because the URL/find box is open
let htmlFullscreen = false;
let closedStack = [];
let download = null;     // { name, pct }
const pendingUrls = [];

// ---------- persistence ----------
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE(), 'utf8')); } catch { return null; }
}
let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNow, 400);
}
function saveNow() {
  const data = {
    hidden,
    active: tabs.findIndex(t => t.id === activeId),
    tabs: tabs.map(t => ({ url: t.url, title: t.title, favicon: t.favicon, pinned: t.pinned, home: t.home })),
    bounds: win && !win.isDestroyed() ? win.getNormalBounds() : undefined,
  };
  try { fs.writeFileSync(STATE_FILE(), JSON.stringify(data)); } catch {}
}

// ---------- url helpers ----------
function toUrl(input) {
  const s = input.trim();
  if (!s) return null;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s) || /^(about|chrome|file|data):/i.test(s)) return s;
  if (/^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(\/.*)?$/i.test(s)) return 'http://' + s;
  if (!/\s/.test(s) && /^[^/]+\.[a-z]{2,}(:\d+)?(\/.*)?$/i.test(s)) return 'https://' + s;
  return 'https://www.google.com/search?q=' + encodeURIComponent(s);
}

// ---------- tabs ----------
const activeTab = () => tabs.find(t => t.id === activeId) || null;

function ensureView(tab) {
  if (tab.view) return tab.view;
  const view = new WebContentsView({
    webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false },
  });
  view.setBackgroundColor('#ffffff');
  if (view.setBorderRadius) view.setBorderRadius(hidden ? 0 : 8);
  tab.view = view;
  const wc = view.webContents;

  const sync = () => { tab.url = wc.getURL() || tab.url; sendState(); save(); };
  wc.on('page-title-updated', (_e, title) => { tab.title = title; sync(); });
  wc.on('page-favicon-updated', (_e, icons) => { tab.favicon = icons[0]; sync(); });
  wc.on('did-navigate', sync);
  wc.on('did-navigate-in-page', sync);
  wc.on('did-start-loading', () => { tab.loading = true; sendState(); });
  wc.on('did-stop-loading', () => { tab.loading = false; sync(); });
  wc.on('enter-html-full-screen', () => { htmlFullscreen = true; layout(); });
  wc.on('leave-html-full-screen', () => { htmlFullscreen = false; layout(); });
  wc.on('found-in-page', (_e, r) => sidebarSend('find-result', { active: r.activeMatchOrdinal, total: r.matches }));
  wc.on('context-menu', (_e, p) => pageContextMenu(tab, p));

  wc.setWindowOpenHandler(({ url, disposition }) => {
    // Real popups (OAuth sign-in windows etc.) stay popups; everything else becomes a tab.
    if (disposition === 'new-window') return { action: 'allow' };
    newTab(url, { background: disposition === 'background-tab', after: tab.id });
    return { action: 'deny' };
  });

  wc.loadURL(tab.url || HOME);
  return view;
}

function newTab(url, { background = false, after = null, pinned = false } = {}) {
  const tab = { id: nextId++, url: url || HOME, title: url || 'New Tab', favicon: null, pinned, loading: false, view: null };
  let idx = after != null ? tabs.findIndex(t => t.id === after) + 1 : tabs.length;
  if (idx <= 0) idx = tabs.length;
  // unpinned tabs never land inside the pinned section
  if (!pinned) idx = Math.max(idx, tabs.filter(t => t.pinned).length);
  tabs.splice(idx, 0, tab);
  if (!background) activate(tab.id); else { ensureView(tab); sendState(); save(); }
  return tab;
}

function activate(id) {
  const tab = tabs.find(t => t.id === id);
  if (!tab) return;
  const prev = activeTab();
  if (prev && prev.view && prev !== tab) win.contentView.removeChildView(prev.view);
  activeId = id;
  ensureView(tab);
  layout();
  if (!forcePeek) tab.view.webContents.focus();
  sendState();
  save();
}

function closeTab(id) {
  const i = tabs.findIndex(t => t.id === id);
  if (i < 0) return;
  const [tab] = tabs.splice(i, 1);
  closedStack.push({ url: tab.url, pinned: tab.pinned, index: i });
  if (closedStack.length > 50) closedStack.shift();
  if (tab.view) {
    win.contentView.removeChildView(tab.view);
    tab.view.webContents.close();
  }
  if (activeId === id) {
    activeId = null;
    const next = tabs[i] || tabs[i - 1];
    if (next) activate(next.id);
    else { layout(); openInput('new'); }
  }
  sendState();
  save();
}

function reopenClosed() {
  const c = closedStack.pop();
  if (!c) return;
  const tab = newTab(c.url, { pinned: c.pinned, background: true });
  const i = tabs.indexOf(tab);
  tabs.splice(i, 1);
  tabs.splice(Math.min(c.index, tabs.length), 0, tab);
  activate(tab.id);
}

function cycle(dir) {
  if (!tabs.length) return;
  const i = tabs.findIndex(t => t.id === activeId);
  activate(tabs[(i + dir + tabs.length) % tabs.length].id);
}

function setPinned(id, pinned) {
  const tab = tabs.find(t => t.id === id);
  if (!tab) return;
  tabs.splice(tabs.indexOf(tab), 1);
  tab.pinned = pinned;
  const pinCount = tabs.filter(t => t.pinned).length;
  tabs.splice(pinned ? pinCount : pinCount, 0, tab);
  sendState(); save();
}

function moveTab(fromId, toId, pinned) {
  const tab = tabs.find(t => t.id === fromId);
  if (!tab || fromId === toId) return;
  tabs.splice(tabs.indexOf(tab), 1);
  tab.pinned = pinned;
  let idx;
  if (toId == null) idx = pinned ? tabs.filter(t => t.pinned).length : tabs.length;
  else idx = tabs.findIndex(t => t.id === toId);
  if (idx < 0) idx = tabs.length;
  tabs.splice(idx, 0, tab);
  sendState(); save();
}

// ---------- layout ----------
function sidebarVisible() {
  if (htmlFullscreen) return false;
  return !hidden || peek || forcePeek;
}

function layout() {
  if (!win || win.isDestroyed()) return;
  const { width: w, height: h } = win.getContentBounds();
  const tab = activeTab();
  const docked = !hidden && !htmlFullscreen;

  if (tab && tab.view) {
    win.contentView.addChildView(tab.view);
    if (tab.view.setBorderRadius) tab.view.setBorderRadius(docked ? 8 : 0);
    tab.view.setBounds(docked
      ? { x: SIDEBAR_W, y: INSET, width: Math.max(0, w - SIDEBAR_W - INSET), height: Math.max(0, h - INSET * 2) }
      : { x: 0, y: 0, width: w, height: h });
  }

  const show = sidebarVisible();
  sidebar.setVisible(show);
  if (show) {
    win.contentView.addChildView(sidebar); // re-adding moves it to the top
    sidebar.setBounds({ x: 0, y: 0, width: SIDEBAR_W, height: h });
  }
  // traffic lights only when the sidebar is on screen — a clean frame for streaming
  win.setWindowButtonVisibility(show);
  sidebarSend('mode', { hidden, overlay: hidden && show });
}

function toggleSidebar() {
  hidden = !hidden;
  peek = false;
  layout();
  save();
}

// When hidden, reveal the sidebar while the cursor rests on the window's left edge.
setInterval(() => {
  if (!win || win.isDestroyed() || !hidden || htmlFullscreen || forcePeek) return;
  if (!win.isFocused() && !peek) return;
  const p = screen.getCursorScreenPoint();
  const b = win.getContentBounds();
  const inY = p.y >= b.y && p.y <= b.y + b.height;
  const dx = p.x - b.x;
  if (!peek && inY && dx >= -2 && dx <= 6) { peek = true; layout(); }
  else if (peek && (!inY || dx > SIDEBAR_W + 24 || dx < -40)) { peek = false; layout(); }
}, 60);

// ---------- sidebar <-> main ----------
function sidebarSend(ch, payload) {
  if (sidebar && !sidebar.webContents.isDestroyed()) sidebar.webContents.send(ch, payload);
}

function sendState() {
  const t = activeTab();
  const wc = t && t.view ? t.view.webContents : null;
  sidebarSend('state', {
    tabs: tabs.map(x => ({ id: x.id, title: x.title, url: x.url, favicon: x.favicon, pinned: x.pinned, loading: x.loading })),
    activeId,
    url: t ? t.url : '',
    canBack: !!(wc && wc.navigationHistory.canGoBack()),
    canFwd: !!(wc && wc.navigationHistory.canGoForward()),
    download,
  });
}

function openInput(mode) {
  forcePeek = hidden;
  layout();
  sidebar.webContents.focus();
  const t = activeTab();
  sidebarSend('open-input', { mode, url: mode === 'url' && t ? t.url : '' });
}

function closeInput() {
  const t = activeTab();
  if (forcePeek) { forcePeek = false; layout(); }
  if (t && t.view) t.view.webContents.focus();
}

ipcMain.on('sb', (_e, cmd, a, b, c) => {
  const t = activeTab();
  const wc = t && t.view ? t.view.webContents : null;
  switch (cmd) {
    case 'activate': activate(a); break;
    case 'close': closeTab(a); break;
    case 'new': openInput('new'); break;
    case 'submit': {
      const url = toUrl(b);
      if (url) {
        if (a === 'new' || !t) newTab(url);
        else { t.url = url; ensureView(t); wc ? wc.loadURL(url) : null; }
      }
      closeInput();
      break;
    }
    case 'find': if (wc && b) wc.findInPage(b, { forward: a !== 'prev', findNext: !!c }); break;
    case 'find-stop': if (wc) wc.stopFindInPage('keepSelection'); break;
    case 'input-open': if (hidden && !forcePeek) { forcePeek = true; layout(); } break;
    case 'input-closed': closeInput(); break;
    case 'back': if (wc) wc.navigationHistory.goBack(); break;
    case 'forward': if (wc) wc.navigationHistory.goForward(); break;
    case 'reload': if (wc) wc.reload(); break;
    case 'toggle-sidebar': toggleSidebar(); break;
    case 'move': moveTab(a, b, c); break;
    case 'tab-menu': tabContextMenu(a); break;
    case 'ready': sendState(); layout(); break;
  }
});

// ---------- context menus ----------
function tabContextMenu(id) {
  const tab = tabs.find(t => t.id === id);
  if (!tab) return;
  Menu.buildFromTemplate([
    { label: tab.pinned ? 'Unpin Tab' : 'Pin Tab', click: () => setPinned(id, !tab.pinned) },
    { label: 'Duplicate Tab', click: () => newTab(tab.url, { after: id }) },
    { label: 'Copy URL', click: () => clipboard.writeText(tab.url) },
    { label: 'Open in Default Browser', click: () => shell.openExternal(tab.url) },
    { type: 'separator' },
    { label: 'Close Tab', click: () => closeTab(id) },
  ]).popup({ window: win });
}

function pageContextMenu(tab, p) {
  const wc = tab.view.webContents;
  const items = [];
  if (p.linkURL) {
    items.push(
      { label: 'Open Link in New Tab', click: () => newTab(p.linkURL, { background: true, after: tab.id }) },
      { label: 'Copy Link', click: () => clipboard.writeText(p.linkURL) },
      { type: 'separator' });
  }
  if (p.mediaType === 'image' && p.srcURL) {
    items.push(
      { label: 'Open Image in New Tab', click: () => newTab(p.srcURL, { after: tab.id }) },
      { label: 'Copy Image', click: () => wc.copyImageAt(p.x, p.y) },
      { label: 'Save Image As…', click: () => wc.downloadURL(p.srcURL) },
      { type: 'separator' });
  }
  if (p.isEditable) {
    items.push({ role: 'undo' }, { role: 'redo' }, { type: 'separator' },
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }, { type: 'separator' });
  } else if (p.selectionText) {
    const q = p.selectionText.trim().slice(0, 80);
    items.push({ role: 'copy' },
      { label: `Search Google for “${q}”`, click: () => newTab(toUrl(q.includes(' ') ? q : q + ' '), { after: tab.id }) },
      { type: 'separator' });
  }
  items.push(
    { label: 'Back', enabled: wc.navigationHistory.canGoBack(), click: () => wc.navigationHistory.goBack() },
    { label: 'Forward', enabled: wc.navigationHistory.canGoForward(), click: () => wc.navigationHistory.goForward() },
    { label: 'Reload', click: () => wc.reload() },
    { type: 'separator' },
    { label: 'Inspect Element', click: () => wc.inspectElement(p.x, p.y) });
  Menu.buildFromTemplate(items).popup({ window: win });
}

// ---------- app menu (all shortcuts live here so they work while a page has focus) ----------
function buildMenu() {
  const wc = () => { const t = activeTab(); return t && t.view ? t.view.webContents : null; };
  const zoom = d => { const w = wc(); if (w) w.setZoomLevel(d === 0 ? 0 : w.getZoomLevel() + d); };
  const tabN = n => ({ label: `Tab ${n}`, accelerator: `CmdOrCtrl+${n}`, click: () => {
    const t = n === 9 ? tabs[tabs.length - 1] : tabs[n - 1]; if (t) activate(t.id);
  } });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: 'appMenu' },
    { label: 'File', submenu: [
      { label: 'New Tab', accelerator: 'CmdOrCtrl+T', click: () => openInput('new') },
      { label: 'Open Location…', accelerator: 'CmdOrCtrl+L', click: () => openInput('url') },
      { label: 'Reopen Closed Tab', accelerator: 'CmdOrCtrl+Shift+T', click: reopenClosed },
      { label: 'Close Tab', accelerator: 'CmdOrCtrl+W', click: () => activeId != null ? closeTab(activeId) : win.close() },
      { label: 'Copy URL', accelerator: 'CmdOrCtrl+Shift+C', click: () => { const t = activeTab(); if (t) clipboard.writeText(t.url); } },
    ] },
    { label: 'Edit', submenu: [
      { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
      { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'pasteAndMatchStyle' }, { role: 'selectAll' },
      { type: 'separator' },
      { label: 'Find…', accelerator: 'CmdOrCtrl+F', click: () => openInput('find') },
    ] },
    { label: 'View', submenu: [
      { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+S', click: toggleSidebar },
      { type: 'separator' },
      { label: 'Reload', accelerator: 'CmdOrCtrl+R', click: () => wc()?.reload() },
      { label: 'Hard Reload', accelerator: 'CmdOrCtrl+Shift+R', click: () => wc()?.reloadIgnoringCache() },
      { label: 'Back', accelerator: 'CmdOrCtrl+[', click: () => wc()?.navigationHistory.goBack() },
      { label: 'Forward', accelerator: 'CmdOrCtrl+]', click: () => wc()?.navigationHistory.goForward() },
      { label: 'Back ', accelerator: 'CmdOrCtrl+Left', visible: false, click: () => wc()?.navigationHistory.goBack() },
      { label: 'Forward ', accelerator: 'CmdOrCtrl+Right', visible: false, click: () => wc()?.navigationHistory.goForward() },
      { type: 'separator' },
      { label: 'Zoom In', accelerator: 'CmdOrCtrl+=', click: () => zoom(0.5) },
      { label: 'Zoom In ', accelerator: 'CmdOrCtrl+Plus', visible: false, click: () => zoom(0.5) },
      { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', click: () => zoom(-0.5) },
      { label: 'Actual Size', accelerator: 'CmdOrCtrl+0', click: () => zoom(0) },
      { type: 'separator' },
      { label: 'Developer Tools', accelerator: 'CmdOrCtrl+Alt+I', click: () => wc()?.toggleDevTools() },
      { role: 'togglefullscreen' },
    ] },
    { label: 'Tabs', submenu: [
      { label: 'Next Tab', accelerator: 'Ctrl+Tab', click: () => cycle(1) },
      { label: 'Previous Tab', accelerator: 'Ctrl+Shift+Tab', click: () => cycle(-1) },
      { label: 'Next Tab ', accelerator: 'CmdOrCtrl+Alt+Down', click: () => cycle(1) },
      { label: 'Previous Tab ', accelerator: 'CmdOrCtrl+Alt+Up', click: () => cycle(-1) },
      { label: 'Pin / Unpin Tab', accelerator: 'CmdOrCtrl+D', click: () => { const t = activeTab(); if (t) setPinned(t.id, !t.pinned); } },
      { type: 'separator' },
      ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map(tabN),
    ] },
    { role: 'windowMenu' },
  ]));
}

// ---------- window ----------
function createWindow() {
  const st = loadState();
  hidden = !!(st && st.hidden);
  const b = (st && st.bounds) || { width: 1440, height: 900 };

  win = new BaseWindow({
    ...b,
    minWidth: 600, minHeight: 400,
    titleBarStyle: 'hidden',
    trafficLightPosition: { x: 16, y: 18 },
    backgroundColor: '#1b1a20',
    title: 'Sidebar',
  });

  sidebar = new WebContentsView({
    webPreferences: { preload: path.join(__dirname, 'sidebar-preload.js'), contextIsolation: true, sandbox: true },
  });
  sidebar.setBackgroundColor('#1b1a20');
  sidebar.webContents.loadFile(path.join(__dirname, 'sidebar.html'));
  win.contentView.addChildView(sidebar);

  if (st && st.tabs && st.tabs.length) {
    // restore lazily: only the active tab loads now, the rest load when clicked
    for (const s of st.tabs) tabs.push({ id: nextId++, url: s.url, title: s.title, favicon: s.favicon, pinned: !!s.pinned, loading: false, view: null });
    const a = tabs[Math.min(Math.max(st.active, 0), tabs.length - 1)];
    activate(a.id);
  } else {
    newTab(HOME);
  }
  for (const u of pendingUrls.splice(0)) newTab(u);

  win.on('resize', layout);
  win.on('close', saveNow);
  win.on('closed', () => { win = null; tabs = []; activeId = null; });
  layout();
}

function setupSession() {
  const ses = session.defaultSession;
  // Downloads go straight to ~/Downloads, progress shows at the bottom of the sidebar.
  ses.on('will-download', (_e, item) => {
    const dir = app.getPath('downloads');
    const ext = path.extname(item.getFilename());
    const base = path.basename(item.getFilename(), ext);
    let p = path.join(dir, item.getFilename()), n = 1;
    while (fs.existsSync(p)) p = path.join(dir, `${base} (${n++})${ext}`);
    item.setSavePath(p);
    item.on('updated', () => {
      const total = item.getTotalBytes();
      download = { name: path.basename(p), pct: total ? Math.round(item.getReceivedBytes() / total * 100) : null };
      sendState();
    });
    item.once('done', (_ev, state) => {
      download = state === 'completed' ? { name: path.basename(p), done: true, path: p } : null;
      sendState();
      setTimeout(() => { download = null; sendState(); }, 6000);
    });
  });
  const allowed = new Set(['fullscreen', 'clipboard-sanitized-write', 'clipboard-read', 'pointerLock', 'media', 'notifications', 'display-capture', 'speaker-selection']);
  ses.setPermissionRequestHandler((_wc, perm, cb) => cb(allowed.has(perm)));
  ses.setPermissionCheckHandler((_wc, perm) => allowed.has(perm));
  // Screen sharing (Meet, Zoom web): use the macOS system picker.
  ses.setDisplayMediaRequestHandler((_req, cb) => {
    desktopCapturer.getSources({ types: ['screen'] }).then(s => cb({ video: s[0] })).catch(() => cb({}));
  }, { useSystemPicker: true });
}

// ---------- app lifecycle ----------
app.on('open-url', (e, url) => {
  e.preventDefault();
  if (win) { newTab(url); win.show(); win.focus(); } else pendingUrls.push(url);
});
app.on('second-instance', (_e, argv) => {
  const url = argv.find(a => /^https?:\/\//.test(a));
  if (win) { if (url) newTab(url); win.show(); win.focus(); }
});

app.whenReady().then(() => {
  nativeTheme.themeSource = 'dark';
  setupSession();
  buildMenu();
  createWindow();
  if (process.env.SB_TEST) selfTest();
  app.on('activate', () => { if (!win) createWindow(); });
});
app.on('before-quit', () => { if (win) saveNow(); });
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

// ---------- scripted self-test (SB_TEST=<scratch userData dir>) ----------
async function selfTest() {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const out = process.env.SB_TEST;
  const shot = async name => {
    const { width: w, height: h } = win.getContentBounds();
    const parts = [];
    for (const v of win.contentView.children) {
      if (!v.getVisible || v.getVisible()) parts.push({ b: v.getBounds(), img: await v.webContents.capturePage() });
    }
    fs.writeFileSync(path.join(out, name + '.json'), JSON.stringify(parts.map(p => p.b)));
    parts.forEach((p, i) => fs.writeFileSync(path.join(out, `${name}-${i}.png`), p.img.toPNG()));
    console.log('SHOT', name, w, h, JSON.stringify(parts.map(p => p.b)));
  };
  await wait(5000);
  newTab('https://en.wikipedia.org/wiki/Web_browser');
  newTab('https://news.ycombinator.com', { background: true });
  await wait(4000);
  setPinned(tabs[0].id, true);
  await wait(500);
  await shot('docked');
  toggleSidebar(); await wait(800);
  await shot('hidden');
  openInput('url'); await wait(800);
  await shot('peek-input');
  sidebarSend('open-input', { mode: 'find', url: '' });
  closeInput(); await wait(300);
  console.log('UA', activeTab().view.webContents.getUserAgent());
  toggleSidebar(); saveNow();
  console.log('STATE', fs.readFileSync(STATE_FILE(), 'utf8').slice(0, 300));
  app.quit();
}
