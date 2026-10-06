import Foundation

/// The single self-contained page (inline CSS and JS) that a computer's browser loads from
/// `/<token>/`. It talks to TransferServer's endpoints relative to that prefix:
/// `api/list?dir=`, `file/<path>[?dl=1]`, `PUT upload?dir=&name=[&sub=]` and `POST mkdir?dir=&name=`.
enum TransferWebPage {
    static let data = Data(html.utf8)

    static let contentSecurityPolicy = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    private static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<title>FileBox · Wi-Fi 传输</title>
<style>
:root{--bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--muted:#8a8a8e;--line:#e5e5ea;--hover:#f4f4f8;--accent:#007aff;--danger:#e5352b;--ok:#2fb350}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f2f2f7;--muted:#98989f;--line:#38383a;--hover:#26262a;--accent:#0a84ff;--danger:#ff453a;--ok:#30d158}}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{margin:0;background:var(--bg);color:var(--text)}
body{font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line)}
.bar{max-width:1000px;margin:0 auto;padding:12px 16px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
h1{font-size:18px;margin:0;font-weight:600}
.tag{font-size:12px;color:var(--accent);border:1px solid var(--accent);border-radius:6px;padding:0 6px}
#free{color:var(--muted);font-size:13px;margin-left:auto}
main{max-width:1000px;margin:0 auto;padding:16px}
.crumbs{display:flex;flex-wrap:wrap;align-items:center;gap:6px;font-size:16px;margin-bottom:12px}
.crumbs a{color:var(--accent);text-decoration:none}
.crumbs a:hover{text-decoration:underline}
.crumbs .sep{color:var(--muted)}
.crumbs .current{font-weight:600}
.tools{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:8px;padding:6px 14px;cursor:pointer}
button:hover{background:var(--hover)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
button.link{border:none;background:none;color:var(--accent);padding:0 4px;font-size:13px}
.hint{color:var(--muted);font-size:13px;margin:0 0 16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden;margin-bottom:16px}
.message{padding:12px 16px;color:var(--danger);border-bottom:1px solid var(--line)}
table{width:100%;border-collapse:collapse}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover{background:var(--hover)}
th{font-weight:500;color:var(--muted);font-size:13px}
th[data-sort]{cursor:pointer;user-select:none}
th.sorted::after{content:" ▾"}
th.sorted.asc::after{content:" ▴"}
td.name{white-space:normal;word-break:break-all;width:100%}
td.name a{color:inherit;text-decoration:none}
td.name a:hover{color:var(--accent);text-decoration:underline}
.icon{display:inline-block;width:1.7em}
td.size,td.date{color:var(--muted);font-size:13px}
td.act a{color:var(--accent);text-decoration:none}
td.act a:hover{text-decoration:underline}
.empty{padding:40px 16px;text-align:center;color:var(--muted)}
.uphead{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--line)}
.uphead span{flex:1;color:var(--muted);font-size:13px}
.uploads ul{list-style:none;margin:0;padding:0;max-height:320px;overflow:auto}
.uploads li{padding:10px 16px;border-bottom:1px solid var(--line)}
.uploads li:last-child{border-bottom:none}
.row1{display:flex;gap:8px;align-items:baseline}
.row1 .n{flex:1;word-break:break-all}
.row1 .s{color:var(--muted);font-size:13px;white-space:nowrap}
.progress{height:6px;border-radius:3px;background:var(--line);overflow:hidden;margin-top:6px}
.progress i{display:block;height:100%;width:0;background:var(--accent);transition:width .2s}
li.done .progress i{background:var(--ok)}
li.fail .progress i{background:var(--danger)}
li.fail .s{color:var(--danger);white-space:normal}
.drop{position:fixed;inset:0;z-index:9;display:none;align-items:center;justify-content:center;background:rgba(0,122,255,.12);border:3px dashed var(--accent);pointer-events:none}
.drop div{background:var(--card);padding:18px 28px;border-radius:14px;font-size:18px;box-shadow:0 8px 30px rgba(0,0,0,.2)}
body.dragging .drop{display:flex}
footer{color:var(--muted);font-size:12px;text-align:center;padding:0 16px 24px}
@media (max-width:640px){th.date,td.date{display:none}}
</style>
</head>
<body>
<header><div class="bar"><h1>FileBox</h1><span class="tag">Wi-Fi 传输</span><span id="free"></span></div></header>
<main>
<nav id="crumbs" class="crumbs"></nav>
<div class="tools">
<button id="uploadBtn" class="primary">上传文件</button>
<button id="folderBtn">上传文件夹</button>
<button id="mkdirBtn">新建文件夹</button>
<button id="refreshBtn">刷新</button>
</div>
<p class="hint">也可以把文件或文件夹直接拖到这个页面，上传到当前文件夹。传输时请让手机上的 FileBox 停在「Wi-Fi 传输」页面、屏幕常亮。</p>
<input type="file" id="fileInput" multiple hidden>
<input type="file" id="folderInput" webkitdirectory multiple hidden>
<section id="uploads" class="card uploads" hidden>
<div class="uphead"><b>上传</b><span id="upSummary"></span><button id="clearDone" class="link">清除已结束</button></div>
<ul id="upList"></ul>
</section>
<div class="card">
<div id="message" class="message" hidden></div>
<table id="table" hidden>
<thead><tr><th data-sort="name">名称</th><th data-sort="size">大小</th><th data-sort="date" class="date">修改时间</th><th></th></tr></thead>
<tbody id="rows"></tbody>
</table>
<div id="empty" class="empty" hidden>这个文件夹是空的，可以把文件拖到这里上传</div>
</div>
</main>
<footer>局域网传输使用 http。浏览器如果提示下载“不安全”，选择“保留”即可。</footer>
<div class="drop"><div>松开鼠标，上传到「<span id="dropTarget"></span>」</div></div>
<script>
(() => {
'use strict';
const base = '/' + location.pathname.split('/')[1] + '/';
const $ = id => document.getElementById(id);
const collator = new Intl.Collator('zh-CN', { numeric: true, sensitivity: 'base' });
const PARALLEL = 2;
let dir = '';
let entries = [];
let freeBytes = null;
let sortKey = 'date';
let sortAsc = false;
let reloadTimer = 0;
let dragDepth = 0;
let running = 0;
const tasks = [];

function el(tag, props, ...kids) {
  const node = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (key === 'class') node.className = value;
      else if (key === 'text') node.textContent = value;
      else node[key] = value;
    }
  }
  for (const kid of kids) if (kid != null) node.append(kid);
  return node;
}

const enc = path => path.split('/').map(encodeURIComponent).join('/');
const join = (a, b) => (a ? a + '/' + b : b);
const hrefFor = d => '#/' + (d ? enc(d) : '');
const folderName = () => (dir ? dir.split('/').pop() : '全部文件');

function fmtSize(n) {
  if (n < 1024) return n + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
  return (n < 10 ? n.toFixed(1) : Math.round(n)) + ' ' + units[i];
}

function fmtDate(ms) {
  const d = new Date(ms);
  const p = n => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function icon(entry) {
  if (entry.dir) return '📁';
  const ext = entry.name.includes('.') ? entry.name.split('.').pop().toLowerCase() : '';
  if (/^(jpe?g|png|gif|heic|heif|webp|bmp|tiff?|dng)$/.test(ext)) return '🖼️';
  if (/^(mp4|mov|m4v|avi|mkv|webm|3gp)$/.test(ext)) return '🎬';
  if (/^(mp3|m4a|aac|wav|flac|aiff?|ogg|opus)$/.test(ext)) return '🎵';
  if (/^(zip|rar|7z|tar|gz)$/.test(ext)) return '🗜️';
  if (ext === 'pdf') return '📕';
  return '📄';
}

function showMessage(text) {
  $('message').textContent = text;
  $('message').hidden = !text;
}

function dirFromHash() {
  const raw = location.hash.replace(/^#\/?/, '');
  try {
    return raw.split('/').filter(Boolean).map(decodeURIComponent).join('/');
  } catch (e) {
    return '';
  }
}

window.addEventListener('hashchange', () => {
  dir = dirFromHash();
  load();
});

async function load() {
  const wanted = dir;
  let res;
  let data = null;
  try {
    res = await fetch(base + 'api/list?dir=' + encodeURIComponent(wanted), { cache: 'no-store' });
    data = await res.json().catch(() => null);
  } catch (e) {
    if (wanted === dir) {
      showMessage('连接不上手机。请确认手机上的 FileBox 停在「Wi-Fi 传输」页面、屏幕亮着，然后刷新本页。');
      $('empty').hidden = true;
    }
    return;
  }
  if (wanted !== dir) return;
  if (!res.ok || !data) {
    entries = [];
    showMessage(data && data.error ? data.error : '这个地址已经失效。FileBox 每次开启 Wi-Fi 传输都会生成新地址，请按手机上显示的地址重新打开。');
    render();
    return;
  }
  showMessage('');
  entries = Array.isArray(data.items) ? data.items : [];
  if (typeof data.free === 'number') {
    freeBytes = data.free;
    $('free').textContent = '手机剩余空间 ' + fmtSize(data.free);
  }
  render();
}

function compare(a, b) {
  if (a.dir !== b.dir) return a.dir ? -1 : 1;
  let result = 0;
  if (sortKey === 'size') result = a.size - b.size;
  else if (sortKey === 'date') result = a.mtime - b.mtime;
  if (result === 0) result = collator.compare(a.name, b.name);
  return sortAsc ? result : -result;
}

function render() {
  const nav = $('crumbs');
  nav.replaceChildren();
  const parts = dir ? dir.split('/') : [];
  const crumb = (label, target, current) => current
    ? el('span', { class: 'current', text: label })
    : el('a', { href: hrefFor(target), text: label });
  nav.append(crumb('全部文件', '', parts.length === 0));
  parts.forEach((part, i) => {
    nav.append(el('span', { class: 'sep', text: '›' }));
    nav.append(crumb(part, parts.slice(0, i + 1).join('/'), i === parts.length - 1));
  });
  document.title = folderName() + ' · FileBox';

  for (const th of document.querySelectorAll('th[data-sort]')) {
    th.classList.toggle('sorted', th.dataset.sort === sortKey);
    th.classList.toggle('asc', th.dataset.sort === sortKey && sortAsc);
  }

  const rows = $('rows');
  rows.replaceChildren();
  const list = entries.slice().sort(compare);
  $('table').hidden = list.length === 0;
  $('empty').hidden = list.length > 0 || !$('message').hidden;
  for (const entry of list) {
    const path = join(dir, entry.name);
    const fileURL = base + 'file/' + enc(path);
    const link = entry.dir
      ? el('a', { href: hrefFor(path), text: entry.name })
      : el('a', { href: fileURL, target: '_blank', rel: 'noopener', title: '在新标签页打开', text: entry.name });
    const action = entry.dir ? null : el('a', { href: fileURL + '?dl=1', download: entry.name, text: '下载' });
    rows.append(el('tr', null,
      el('td', { class: 'name' }, el('span', { class: 'icon', text: icon(entry) }), link),
      el('td', { class: 'size', text: entry.dir ? '' : fmtSize(entry.size) }),
      el('td', { class: 'date', text: fmtDate(entry.mtime) }),
      el('td', { class: 'act' }, action)));
  }
}

for (const th of document.querySelectorAll('th[data-sort]')) {
  th.addEventListener('click', () => {
    const key = th.dataset.sort;
    if (sortKey === key) {
      sortAsc = !sortAsc;
    } else {
      sortKey = key;
      sortAsc = key === 'name';
    }
    render();
  });
}

$('refreshBtn').addEventListener('click', () => load());
$('uploadBtn').addEventListener('click', () => $('fileInput').click());
$('folderBtn').addEventListener('click', () => $('folderInput').click());

$('fileInput').addEventListener('change', event => {
  enqueue(Array.from(event.target.files, file => ({ file, sub: '' })));
  event.target.value = '';
});

$('folderInput').addEventListener('change', event => {
  enqueue(Array.from(event.target.files, file => ({
    file,
    sub: (file.webkitRelativePath || '').split('/').slice(0, -1).join('/'),
  })));
  event.target.value = '';
});

$('mkdirBtn').addEventListener('click', async () => {
  const name = prompt('新文件夹的名称', '新建文件夹');
  if (name === null || !name.trim()) return;
  const target = dir;
  try {
    const res = await fetch(base + 'mkdir?dir=' + encodeURIComponent(target) + '&name=' + encodeURIComponent(name.trim()), { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || ('错误 ' + res.status));
    if (target === dir) load();
  } catch (e) {
    alert('新建文件夹失败：' + (e instanceof TypeError ? '连接不上手机' : e.message));
  }
});

function enqueue(items) {
  if (!items.length) return;
  for (const { file, sub } of items) {
    const task = { file, sub, dir, state: 'wait', started: 0, xhr: null };
    task.bar = el('i');
    task.status = el('span', { class: 's', text: '等待中 · ' + fmtSize(file.size) });
    task.cancel = el('button', { class: 'link', text: '取消', onclick: () => cancel(task) });
    task.li = el('li', null,
      el('div', { class: 'row1' }, el('span', { class: 'n', text: (sub ? sub + '/' : '') + file.name }), task.status, task.cancel),
      el('div', { class: 'progress' }, task.bar));
    $('upList').append(task.li);
    tasks.push(task);
  }
  $('uploads').hidden = false;
  pump();
  summary();
}

function pump() {
  for (const task of tasks) {
    if (running >= PARALLEL) break;
    if (task.state === 'wait') start(task);
  }
}

function start(task) {
  if (freeBytes !== null && task.file.size > freeBytes) {
    finish(task, 'fail', '手机存储空间不足');
    return;
  }
  task.state = 'up';
  running++;
  task.started = Date.now();
  task.status.textContent = '0%';
  const xhr = new XMLHttpRequest();
  task.xhr = xhr;
  let url = base + 'upload?dir=' + encodeURIComponent(task.dir) + '&name=' + encodeURIComponent(task.file.name);
  if (task.sub) url += '&sub=' + encodeURIComponent(task.sub);
  xhr.open('PUT', url);
  xhr.upload.onprogress = event => {
    if (!event.lengthComputable || task.state !== 'up') return;
    const pct = event.total ? Math.floor(event.loaded * 100 / event.total) : 100;
    const seconds = (Date.now() - task.started) / 1000;
    const speed = seconds > 0.5 ? ' · ' + fmtSize(event.loaded / seconds) + '/s' : '';
    task.bar.style.width = pct + '%';
    task.status.textContent = event.loaded >= event.total ? '正在保存…' : pct + '%' + speed;
  };
  xhr.onload = () => {
    let data = {};
    try { data = JSON.parse(xhr.responseText); } catch (e) {}
    if (xhr.status >= 200 && xhr.status < 300) {
      finish(task, 'done', data.name && data.name !== task.file.name ? '完成，已保存为「' + data.name + '」' : '完成');
    } else {
      finish(task, 'fail', data.error || ('失败（错误 ' + xhr.status + '）'));
    }
  };
  xhr.onerror = () => finish(task, 'fail', '连接中断：请确认手机上的 FileBox 在前台');
  xhr.onabort = () => finish(task, 'fail', '已取消');
  xhr.send(task.file);
}

function finish(task, state, text) {
  if (task.state !== 'up' && task.state !== 'wait') return;
  if (task.state === 'up') running--;
  task.state = state;
  task.status.textContent = text;
  task.li.className = state;
  if (state === 'done') task.bar.style.width = '100%';
  task.cancel.remove();
  if (state === 'done' && task.dir === dir) {
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(load, 300);
  }
  pump();
  summary();
}

function cancel(task) {
  if (task.state === 'up' && task.xhr) task.xhr.abort();
  else if (task.state === 'wait') finish(task, 'fail', '已取消');
}

function summary() {
  const count = state => tasks.filter(task => task.state === state).length;
  const left = count('wait') + count('up');
  const failed = count('fail');
  $('upSummary').textContent = left
    ? '还剩 ' + left + ' 个'
    : '全部结束：成功 ' + count('done') + ' 个' + (failed ? '，失败 ' + failed + ' 个' : '');
}

$('clearDone').addEventListener('click', () => {
  for (let i = tasks.length - 1; i >= 0; i--) {
    if (tasks[i].state === 'done' || tasks[i].state === 'fail') {
      tasks[i].li.remove();
      tasks.splice(i, 1);
    }
  }
  if (tasks.length) summary(); else $('uploads').hidden = true;
});

window.addEventListener('beforeunload', event => {
  if (tasks.some(task => task.state === 'wait' || task.state === 'up')) {
    event.preventDefault();
    event.returnValue = '';
  }
});

const hasFiles = event => !!event.dataTransfer && Array.from(event.dataTransfer.types || []).includes('Files');

window.addEventListener('dragenter', event => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  if (dragDepth++ === 0) {
    $('dropTarget').textContent = folderName();
    document.body.classList.add('dragging');
  }
});

window.addEventListener('dragover', event => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'copy';
});

window.addEventListener('dragleave', event => {
  if (!hasFiles(event)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) document.body.classList.remove('dragging');
});

window.addEventListener('drop', event => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging');
  collect(event.dataTransfer).then(enqueue);
});

// Folder entries must be taken synchronously inside the drop event; walking them can happen later.
function collect(transfer) {
  const items = Array.from(transfer.items || []).filter(item => item.kind === 'file');
  const roots = items.map(item => (item.webkitGetAsEntry ? item.webkitGetAsEntry() : null));
  if (!roots.length || roots.some(root => !root)) {
    return Promise.resolve(Array.from(transfer.files || [], file => ({ file, sub: '' })));
  }
  const found = [];
  return (async () => {
    for (const root of roots) await walk(root, '', found);
    return found;
  })();
}

async function walk(entry, sub, found) {
  if (entry.isFile) {
    try {
      found.push({ file: await new Promise((resolve, reject) => entry.file(resolve, reject)), sub });
    } catch (e) {}
  } else if (entry.isDirectory) {
    const path = join(sub, entry.name);
    const reader = entry.createReader();
    for (;;) {
      let batch;
      try {
        batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
      } catch (e) {
        break;
      }
      if (!batch.length) break;
      for (const child of batch) await walk(child, path, found);
    }
  }
}

dir = dirFromHash();
load();
})();
</script>
</body>
</html>
"""#
}
