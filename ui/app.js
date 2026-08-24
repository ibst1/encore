'use strict';

// ── bridge ─────────────────────────────────────────────────────────────
function post(msg) {
  if (window.chrome && window.chrome.webview)
    window.chrome.webview.postMessage(msg);
}

let state = null;      // last receiveState payload
let events = [];       // raw events of the selected macro
let truncated = false;
let steps = [];        // grouped display steps: {icon, html, from, to, t}
let selSteps = new Set();

// ── vk → display label ─────────────────────────────────────────────────
const VKNAME = {
  0x08: 'Backspace', 0x09: 'Tab', 0x0D: 'Enter', 0x1B: 'Esc', 0x20: 'Space',
  0x21: 'PgUp', 0x22: 'PgDn', 0x23: 'End', 0x24: 'Home',
  0x25: '←', 0x26: '↑', 0x27: '→', 0x28: '↓',
  0x2C: 'PrtSc', 0x2D: 'Insert', 0x2E: 'Delete', 0x5D: 'Menu',
  0x90: 'NumLock', 0x91: 'ScrollLock', 0x14: 'CapsLock',
  0x6A: 'Num*', 0x6B: 'Num+', 0x6D: 'Num-', 0x6E: 'NumDec', 0x6F: 'Num/'
};
for (let i = 1; i <= 24; i++) VKNAME[0x6F + i] = 'F' + i;          // F1-F24
for (let i = 0; i <= 9; i++) VKNAME[0x60 + i] = 'Num' + i;         // numpad digits
const OEM = { 0xBA: 'ö', 0xBB: '+', 0xBC: ',', 0xBD: '-', 0xBE: '.',
  0xBF: "'", 0xC0: 'å', 0xDB: '´', 0xDC: '§', 0xDD: 'ä',
  0xDE: 'æ', 0xE2: '<' };

const MODVK = { 0x10: 'Shift', 0xA0: 'Shift', 0xA1: 'Shift',
  0x11: 'Ctrl', 0xA2: 'Ctrl', 0xA3: 'Ctrl',
  0x12: 'Alt', 0xA4: 'Alt', 0xA5: 'AltGr',
  0x5B: 'Win', 0x5C: 'Win' };

function isMod(vk) { return MODVK.hasOwnProperty(vk); }
function isPrintable(vk) {
  return (vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5A)
      || vk === 0x20 || OEM.hasOwnProperty(vk);
}
function charFor(vk, shift) {
  if (vk >= 0x41 && vk <= 0x5A) {
    const c = String.fromCharCode(vk);
    return shift ? c : c.toLowerCase();
  }
  if (vk >= 0x30 && vk <= 0x39) return String.fromCharCode(vk);
  if (vk === 0x20) return ' ';
  if (OEM.hasOwnProperty(vk)) return OEM[vk];
  return '?';
}
function keyName(vk) {
  if (VKNAME.hasOwnProperty(vk)) return VKNAME[vk];
  if (vk >= 0x41 && vk <= 0x5A) return String.fromCharCode(vk);
  if (vk >= 0x30 && vk <= 0x39) return String.fromCharCode(vk);
  if (OEM.hasOwnProperty(vk)) return OEM[vk];
  return 'vk' + vk.toString(16).toUpperCase();
}
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ── grouping: raw events → readable steps ──────────────────────────────
// Every step keeps the exact 1-based [from..to] range into the raw event
// array, so "delete selected steps" can remove precisely those events.
const MSG = { MOVE: 0x200, LD: 0x201, LU: 0x202, LDBL: 0x203, RD: 0x204,
  RU: 0x205, RDBL: 0x206, MD: 0x207, MU: 0x208, MDBL: 0x209,
  XD: 0x20B, XU: 0x20C, WHEEL: 0x20A, HWHEEL: 0x20E };
const DOWNUP = { 0x201: 0x202, 0x204: 0x205, 0x207: 0x208, 0x20B: 0x20C };
const BTNNAME = { 0x201: 'Left', 0x204: 'Right', 0x207: 'Middle', 0x20B: 'X' };
const DBLNAME = { 0x203: 'Double-click', 0x206: 'Right double-click', 0x209: 'Middle double-click' };

function groupEvents() {
  steps = [];
  const n = events.length;
  let i = 0;
  const push = (icon, html, from, to) => {
    const s = { icon, html, from: from + 1, to: to + 1, t: events[from].t };
    steps.push(s);
    return s;
  };

  while (i < n) {
    const e = events[i];
    if (e.kind === 'w') {
      push('⇆', 'Switch to <b>' + esc(e.exe || e.title) + '</b>'
        + (e.title ? ' <span class="txt">' + esc(e.title) + '</span>' : ''), i, i)
        .edit = { type: 'switch', exe: e.exe, title: e.title };
      i++;
    } else if (e.kind === 't') {
      push('⌨', 'Type <span class="txt">' + esc(e.text) + '</span>', i, i)
        .edit = { type: 'text', text: e.text };
      i++;
    } else if (e.kind === 's') {
      push('⌨', 'Send keys <span class="kbd">' + esc(e.keys) + '</span>', i, i)
        .edit = { type: 'send', keys: e.keys };
      i++;
    } else if (e.kind === 'd') {
      push('⏱', 'Wait ' + e.ms + ' ms', i, i)
        .edit = { type: 'pause', ms: e.ms };
      i++;
    } else if (e.kind === 'g') {
      let what = e.state === 1 ? 'Maximize' : e.state === -1 ? 'Minimize'
        : 'Move/resize to (' + e.x + ', ' + e.y + ') ' + e.w + '×' + e.h;
      push('▣', what + ' <b>' + esc(e.exe) + '</b>', i, i);
      i++;
    } else if (e.kind === 'm') {
      if (e.msg === MSG.MOVE) {
        let j = i;
        while (j < n && events[j].kind === 'm' && events[j].msg === MSG.MOVE) j++;
        const last = events[j - 1];
        push('〰', 'Mouse path (' + (j - i) + ' points → ' + last.x + ', ' + last.y + ')', i, j - 1);
        i = j;
      } else if (DBLNAME.hasOwnProperty(e.msg)) {
        push('◉', DBLNAME[e.msg] + ' at (' + e.x + ', ' + e.y + ')', i, i);
        i++;
      } else if (e.msg === MSG.WHEEL || e.msg === MSG.HWHEEL) {
        let d = (e.data >> 16) & 0xFFFF;
        if (d > 0x7FFF) d -= 0x10000;
        const dir = e.msg === MSG.WHEEL ? (d > 0 ? 'up' : 'down') : (d > 0 ? 'right' : 'left');
        push('⇅', 'Scroll ' + dir, i, i);
        i++;
      } else if (DOWNUP.hasOwnProperty(e.msg)) {
        // click or drag: find the matching up, allowing moves in between
        let j = i + 1, moves = 0;
        while (j < n && events[j].kind === 'm' && events[j].msg === MSG.MOVE) {
          moves++;
          j++;
        }
        if (j < n && events[j].kind === 'm' && events[j].msg === DOWNUP[e.msg]) {
          const up = events[j];
          if (moves > 2 && (Math.abs(up.x - e.x) > 4 || Math.abs(up.y - e.y) > 4))
            push('↖', BTNNAME[e.msg] + '-drag (' + e.x + ', ' + e.y + ') → ('
              + up.x + ', ' + up.y + ')', i, j);
          else
            push('●', (e.msg === MSG.LD ? 'Click' : BTNNAME[e.msg] + '-click')
              + ' at (' + e.x + ', ' + e.y + ')', i, j);
          i = j + 1;
        } else {
          push('●', BTNNAME[e.msg] + ' button down', i, i);
          i++;
        }
      } else {
        push('○', 'Mouse button up', i, i);
        i++;
      }
    } else if (e.kind === 'k') {
      if (isMod(e.vk) && !e.up) {
        // modifier chord: consume until every held modifier is released,
        // collect the non-modifier keys pressed inside
        const held = new Set([e.vk]);
        const mods = new Set([MODVK[e.vk]]);
        const keys = [];
        let j = i + 1;
        let shiftOnlyText = MODVK[e.vk] === 'Shift';
        while (j < n && held.size) {
          const x = events[j];
          if (x.kind !== 'k') { j++; continue; }
          if (isMod(x.vk)) {
            if (x.up) held.delete(x.vk);
            else { held.add(x.vk); mods.add(MODVK[x.vk]); if (MODVK[x.vk] !== 'Shift') shiftOnlyText = false; }
          } else if (!x.up) {
            keys.push(x.vk);
            if (!isPrintable(x.vk)) shiftOnlyText = false;
          }
          j++;
        }
        const to = j - 1;
        if (shiftOnlyText && keys.length) {
          // Shift held for capitals — render as typed text instead of a chord
          const txt = keys.map(vk => charFor(vk, true)).join('');
          push('⌨', 'Type <span class="txt">' + esc(txt) + '</span>', i, to)
            .edit = { type: 'text', text: txt };
        } else if (keys.length) {
          const combo = [...mods].join('+') + '+' + keys.map(keyName).join(', ');
          push('⌨', '<span class="kbd">' + esc(combo) + '</span>', i, to);
        } else {
          push('⌨', '<span class="kbd">' + esc([...mods].join('+')) + ' (tap)</span>', i, to);
        }
        i = j;
      } else if (!e.up && isPrintable(e.vk)) {
        // plain typing run
        let txt = '', j = i;
        while (j < n) {
          const x = events[j];
          if (x.kind !== 'k') break;
          if (isMod(x.vk)) break;
          if (!isPrintable(x.vk)) break;
          if (!x.up) txt += charFor(x.vk, false);
          j++;
        }
        push('⌨', 'Type <span class="txt">' + esc(txt) + '</span>', i, j - 1)
          .edit = { type: 'text', text: txt };
        i = j;
      } else if (!e.up) {
        // special key: consume its up if it comes next
        let to = i;
        if (i + 1 < n && events[i + 1].kind === 'k' && events[i + 1].vk === e.vk && events[i + 1].up)
          to = i + 1;
        push('⌨', '<span class="kbd">' + esc(keyName(e.vk)) + '</span>', i, to);
        i = to + 1;
      } else {
        push('⌨', '<span class="kbd">' + esc(keyName(e.vk)) + ' up</span>', i, i);
        i++;
      }
    } else {
      i++;
    }
  }
}

// ── rendering ──────────────────────────────────────────────────────────
function fmtDur(ms) {
  if (ms < 1000) return ms + ' ms';
  if (ms < 60000) return (ms / 1000).toFixed(1) + ' s';
  return Math.floor(ms / 60000) + ':' + String(Math.round(ms % 60000 / 1000)).padStart(2, '0') + ' min';
}

function renderList() {
  const ul = document.getElementById('recList');
  ul.innerHTML = '';
  if (!state || !state.recordings.length) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No recordings yet';
    ul.appendChild(li);
    return;
  }
  for (const r of state.recordings) {
    const li = document.createElement('li');
    if (r.name === state.current) li.classList.add('selected');
    li.innerHTML = '<span class="nm"></span><span class="meta"></span>';
    li.querySelector('.nm').textContent = r.name;
    li.querySelector('.meta').textContent = r.events + ' · ' + fmtDur(r.durMs);
    li.addEventListener('click', () => post({ action: 'select', name: r.name }));
    ul.appendChild(li);
  }
}

function renderSteps() {
  groupEvents();
  selSteps.clear();
  updateDelBtn();
  const body = document.getElementById('stepsBody');
  body.innerHTML = '';
  document.getElementById('stepsEmpty').style.display =
    (state && state.current && steps.length) ? 'none' : '';
  document.getElementById('truncNote').hidden = !truncated;
  const t0 = events.length ? events[0].t : 0;
  steps.forEach((s, idx) => {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td class="n">' + (idx + 1) + '</td><td class="ic">' + s.icon
      + '</td><td class="lb">' + s.html + '</td><td class="tm">+' + fmtDur(s.t - t0) + '</td>';
    tr.addEventListener('click', ev => {
      if (!ev.ctrlKey && !ev.shiftKey) selSteps.clear();
      if (selSteps.has(idx)) selSteps.delete(idx); else selSteps.add(idx);
      [...body.children].forEach((row, k) => row.classList.toggle('sel', selSteps.has(k)));
      updateDelBtn();
    });
    body.appendChild(tr);
  });
}

function updateDelBtn() {
  document.getElementById('btnDelSteps').disabled = !selSteps.size || truncated;
  const one = selSteps.size === 1 ? steps[[...selSteps][0]] : null;
  document.getElementById('btnEditStep').disabled = truncated || !(one && one.edit);
}

// ── step modal (add / edit) ────────────────────────────────────────────
let stepMode = null;   // {mode:'add', at} | {mode:'edit', from, to}

function showStepModal(mode, preset) {
  stepMode = mode;
  const $ = id => document.getElementById(id);
  $('stepModalTitle').textContent = mode.mode === 'edit' ? 'Edit step' : 'Add step';
  const p = preset || { type: 'text' };
  $('stType').value = p.type;
  $('stType').disabled = mode.mode === 'edit';
  $('stText').value = p.text || '';
  $('stMs').value = p.ms != null ? p.ms : '';
  $('stKeys').value = p.keys || '';
  $('stExe').value = p.exe || '';
  $('stTitle').value = p.title || '';
  applyStepType();
  $('stepModal').hidden = false;
}

function applyStepType() {
  const type = document.getElementById('stType').value;
  document.querySelectorAll('.st-field').forEach(el => {
    el.style.display = el.dataset.for === type ? '' : 'none';
  });
}

function renderState() {
  if (!state) return;
  renderList();
  const rec = document.getElementById('btnRecord');
  rec.textContent = state.recording ? '■ Stop recording' : '● Record';
  rec.classList.toggle('rec', state.recording);
  document.getElementById('btnPlay').disabled = state.recording || state.playing || !state.current;
  document.getElementById('btnStop').disabled = !state.playing;
  const st = document.getElementById('status');
  st.textContent = state.recording ? 'recording…' : state.playing ? 'playing…' : '';
  st.classList.toggle('live', state.recording || state.playing);
  document.getElementById('macroName').textContent = state.current || '–';
  const cur = state.recordings.find(r => r.name === state.current);
  document.getElementById('macroMeta').textContent =
    cur ? cur.events + ' events · ' + fmtDur(cur.durMs) : '';
  const p = state.macroProps || {};
  document.getElementById('pRepeat').value = p.repeat != null ? p.repeat : '';
  document.getElementById('pPause').value = p.pause != null ? p.pause : '';
  document.getElementById('pSpeed').value = p.speed != null ? p.speed : '';
  document.getElementById('pMode').value = p.mode || '';
}

// ── AHK entry points ───────────────────────────────────────────────────
window.receiveState = function (st) {
  state = st;
  renderState();
};
window.receiveMacro = function (payload) {
  events = payload.events || [];
  truncated = !!payload.truncated;
  renderSteps();
};

// ── UI wiring ──────────────────────────────────────────────────────────
window.addEventListener('DOMContentLoaded', () => {
  const $ = id => document.getElementById(id);
  $('btnRecord').addEventListener('click', () => post({ action: 'record' }));
  $('btnPlay').addEventListener('click', () => post({ action: 'play' }));
  $('btnStop').addEventListener('click', () => post({ action: 'stop' }));
  $('btnFolder').addEventListener('click', () => post({ action: 'openFolder' }));
  $('btnRename').addEventListener('click', () => {
    if (!state || !state.current) return;
    const name = prompt('Name for the recording:', state.current);
    if (name && name.trim() && name !== state.current)
      post({ action: 'rename', name: state.current, newName: name.trim() });
  });
  $('btnDelete').addEventListener('click', () => {
    if (!state || !state.current) return;
    if (confirm('Delete the recording "' + state.current + '"?'))
      post({ action: 'delete', name: state.current });
  });
  $('btnDelSteps').addEventListener('click', () => {
    if (!selSteps.size) return;
    const ranges = [...selSteps].sort((a, b) => a - b).map(i => [steps[i].from, steps[i].to]);
    post({ action: 'deleteEvents', ranges });
  });
  $('btnAddStep').addEventListener('click', () => {
    if (!state || !state.current) return;
    const sel = [...selSteps].sort((a, b) => a - b);
    const at = sel.length ? steps[sel[sel.length - 1]].to + 1 : events.length + 1;
    showStepModal({ mode: 'add', at });
  });
  $('btnEditStep').addEventListener('click', () => {
    if (selSteps.size !== 1) return;
    const s = steps[[...selSteps][0]];
    if (!s.edit) return;
    showStepModal({ mode: 'edit', from: s.from, to: s.to }, s.edit);
  });
  $('stType').addEventListener('change', applyStepType);
  $('btnStepCancel').addEventListener('click', () => { $('stepModal').hidden = true; });
  $('btnStepSave').addEventListener('click', () => {
    const spec = { type: $('stType').value, text: $('stText').value,
      ms: $('stMs').value.trim(), keys: $('stKeys').value,
      exe: $('stExe').value.trim(), title: $('stTitle').value.trim() };
    if (stepMode.mode === 'edit')
      post({ action: 'setStep', from: stepMode.from, to: stepMode.to, ...spec });
    else
      post({ action: 'insertStep', at: stepMode.at, ...spec });
    $('stepModal').hidden = true;
  });
  $('btnSaveProps').addEventListener('click', () => {
    post({ action: 'saveMacroSettings',
      repeat: $('pRepeat').value.trim(), pause: $('pPause').value.trim(),
      speed: $('pSpeed').value.trim(), mode: $('pMode').value });
  });
  $('btnSettings').addEventListener('click', () => {
    if (!state) return;
    const s = state.settings;
    $('sRecordKey').value = s.recordKey;
    $('sPlayKey').value = s.playKey;
    $('sMode').value = s.mode;
    $('sSpeed').value = s.speed;
    $('sFixedDelay').value = s.fixedDelayMs;
    $('sRepeat').value = s.repeat;
    $('sRepeatPause').value = s.repeatPauseMs;
    $('sAnchors').value = s.anchors ? '1' : '0';
    $('settingsModal').hidden = false;
  });
  $('btnSettingsCancel').addEventListener('click', () => { $('settingsModal').hidden = true; });
  $('btnSettingsSave').addEventListener('click', () => {
    post({ action: 'saveSettings',
      recordKey: $('sRecordKey').value.trim(), playKey: $('sPlayKey').value.trim(),
      mode: $('sMode').value, speed: $('sSpeed').value.trim(),
      fixedDelayMs: $('sFixedDelay').value.trim(), repeat: $('sRepeat').value.trim(),
      repeatPauseMs: $('sRepeatPause').value.trim(), anchors: $('sAnchors').value });
    $('settingsModal').hidden = true;
  });
  post({ action: 'ready' });
});
