const $ = id => document.getElementById(id);
let state = { tabs: [], activeId: null, url: '' };
let mode = null; // null | 'new' | 'url' | 'find'

function prettyUrl(u) {
  try { const x = new URL(u); return x.hostname.replace(/^www\./, '') + (x.pathname !== '/' ? x.pathname : ''); }
  catch { return u || ''; }
}

function tabEl(t) {
  const el = document.createElement('div');
  el.className = 'tab' + (t.id === state.activeId ? ' active' : '') + (t.loading ? ' loading' : '');
  el.draggable = true;
  el.dataset.id = t.id;
  el.title = t.title + '\n' + t.url;
  const icon = t.favicon ? Object.assign(document.createElement('img'), { src: t.favicon }) : Object.assign(document.createElement('div'), { className: 'ph' });
  if (icon.tagName === 'IMG') icon.onerror = () => icon.replaceWith(Object.assign(document.createElement('div'), { className: 'ph' }));
  const title = Object.assign(document.createElement('div'), { className: 'title', textContent: t.title || prettyUrl(t.url) });
  const x = Object.assign(document.createElement('button'), { className: 'x', textContent: '×', title: 'Close (⌘W)' });
  x.onclick = e => { e.stopPropagation(); sb.send('close', t.id); };
  el.append(icon, title, x);
  el.onmousedown = e => { if (e.button === 0 && e.target !== x) sb.send('activate', t.id); };
  el.onauxclick = e => { if (e.button === 1) sb.send('close', t.id); };
  el.oncontextmenu = e => { e.preventDefault(); sb.send('tab-menu', t.id); };
  el.ondragstart = e => { e.dataTransfer.setData('text/tab', String(t.id)); e.dataTransfer.effectAllowed = 'move'; };
  el.ondragover = e => { e.preventDefault(); e.stopPropagation(); el.classList.add('drag-over'); };
  el.ondragleave = () => el.classList.remove('drag-over');
  el.ondrop = e => {
    e.preventDefault(); e.stopPropagation(); el.classList.remove('drag-over');
    const from = Number(e.dataTransfer.getData('text/tab'));
    if (from) sb.send('move', from, t.id, t.pinned);
  };
  return el;
}

for (const sec of [$('pinned'), $('today')]) {
  sec.ondragover = e => { e.preventDefault(); sec.classList.add('drop-end'); };
  sec.ondragleave = () => sec.classList.remove('drop-end');
  sec.ondrop = e => {
    e.preventDefault(); sec.classList.remove('drop-end');
    const from = Number(e.dataTransfer.getData('text/tab'));
    if (from) sb.send('move', from, null, sec.dataset.pinned === '1');
  };
}
// dropping on the divider pins at the end of the pinned section
$('divider').ondragover = e => e.preventDefault();
$('divider').ondrop = e => { const from = Number(e.dataTransfer.getData('text/tab')); if (from) sb.send('move', from, null, true); };

function render() {
  const pinned = $('pinned'), today = $('today');
  pinned.replaceChildren(...state.tabs.filter(t => t.pinned).map(tabEl));
  today.replaceChildren(...state.tabs.filter(t => !t.pinned).map(tabEl));
  $('urltext').textContent = prettyUrl(state.url) || 'Search or enter URL';
  $('back').disabled = !state.canBack;
  $('fwd').disabled = !state.canFwd;
  const d = state.download;
  $('download').textContent = !d ? '' : d.done ? `✓ ${d.name}` : `↓ ${d.name}${d.pct != null ? ` — ${d.pct}%` : ''}`;
  const active = document.querySelector('.tab.active');
  if (active) active.scrollIntoView({ block: 'nearest' });
}

function openInput(m, value) {
  mode = m;
  const input = $('input');
  $('urlbox').classList.add('editing');
  $('findcount').textContent = '';
  input.placeholder = m === 'find' ? 'Find in page' : m === 'new' ? 'Search or enter URL — new tab' : 'Search or enter URL';
  input.value = value || '';
  input.focus();
  input.select();
  sb.send('input-open');
}
function closeInput(notify = true) {
  if (!mode) return;
  if (mode === 'find') sb.send('find-stop');
  mode = null;
  $('urlbox').classList.remove('editing');
  $('findcount').textContent = '';
  $('input').blur();
  if (notify) sb.send('input-closed');
}

$('input').addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.preventDefault(); closeInput(); }
  else if (e.key === 'Enter') {
    e.preventDefault();
    if (mode === 'find') sb.send('find', e.shiftKey ? 'prev' : 'next', $('input').value, true);
    else { const m = mode, v = $('input').value; mode = null; $('urlbox').classList.remove('editing'); sb.send('submit', m, v); }
  }
});
$('input').addEventListener('input', () => { if (mode === 'find') sb.send('find', 'next', $('input').value, false); });
$('input').addEventListener('blur', () => setTimeout(() => { if (mode && document.activeElement !== $('input')) closeInput(); }, 120));

$('urlbox').onmousedown = e => { if (!mode) { e.preventDefault(); openInput('url', state.url); } };
$('newtab').onclick = () => openInput('new', '');
$('back').onclick = () => sb.send('back');
$('fwd').onclick = () => sb.send('forward');
$('reload').onclick = () => sb.send('reload');
$('toggle').onclick = () => sb.send('toggle-sidebar');
$('clear').onclick = () => state.tabs.filter(t => !t.pinned).forEach(t => sb.send('close', t.id));

sb.on('state', s => { state = s; render(); });
sb.on('open-input', ({ mode: m, url }) => openInput(m, url));
sb.on('find-result', r => { if (mode === 'find') $('findcount').textContent = r.total ? `${r.active}/${r.total}` : '0/0'; });
sb.on('mode', m => {
  document.body.classList.toggle('overlay', !!m.overlay);
  $('toggle').title = m.hidden ? 'Keep sidebar open (⌘S)' : 'Hide sidebar (⌘S)';
});
sb.send('ready');
