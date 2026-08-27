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
let selMacros = new Set();   // sidebar multi-selection (Ctrl/Shift-click)
let lastRecIdx = -1;         // anchor row for Shift-click ranges
let dragSteps = null;        // [from,to] event ranges while steps are dragged
let dragStepIdxs = null;     // selected step indices while dragging (for in-macro reorder)
let restoreStepSel = null;   // [first,last] step range to re-select after re-render
let propsDirty = false;      // unsaved edits in the per-recording props fields
let lastCurrent = null;      // to reset propsDirty when another macro is picked
let stepLoops = [];          // repeat brackets: {from,to (step idx), count, leEv}

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

  stepLoops = [];
  const _lstack = [];
  while (i < n) {
    const e = events[i];
    if (e.kind === 'ls') {           // repeat markers render as brackets, not steps
      _lstack.push({ start: steps.length });
      i++;
    } else if (e.kind === 'le') {
      const b = _lstack.pop();
      if (b) stepLoops.push({ from: b.start, to: steps.length - 1, count: e.count, leEv: i + 1 });
      i++;
    } else if (e.kind === 'cw') {
      push('⧉', 'Wait for clipboard change (≤ ' + fmtDur(e.ms) + ')', i, i)
        .edit = { type: 'clipwait', timeout: e.ms };
      i++;
    } else if (e.kind === 'w') {
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
    } else if (e.kind === 'v') {
      push('⎘', 'Type next data value <span class="kbd">{value'
        + (e.col > 1 ? ':' + e.col : '') + '}</span> (column ' + e.col + ')', i, i)
        .edit = { type: 'value', col: e.col };
      i++;
    } else if (e.kind === 'ww') {
      push('⏳', 'Wait for window <b>' + esc(e.exe || e.title) + '</b>'
        + (e.title && e.exe ? ' <span class="txt">' + esc(e.title) + '</span>' : '')
        + ' (≤ ' + fmtDur(e.ms) + (e.active ? ', active' : '') + ')', i, i)
        .edit = { type: 'waitwin', exe: e.exe, title: e.title, timeout: e.ms, active: e.active };
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

function renamePrompt(name) {
  const nn = prompt('Name for the recording:', name);
  if (nn && nn.trim() && nn.trim() !== name)
    post({ action: 'rename', name, newName: nn.trim() });
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
  // drop selections whose recording was deleted or renamed since last render
  selMacros = new Set(
    [...selMacros].filter(n => state.recordings.some(r => r.name === n)));
  state.recordings.forEach((r, i) => {
    const li = document.createElement('li');
    if (r.name === state.current) li.classList.add('selected');
    if (selMacros.has(r.name)) li.classList.add('multisel');
    li.innerHTML = '<span class="nm"></span><span class="meta"></span>';
    li.querySelector('.nm').textContent = r.name;
    li.querySelector('.meta').textContent = r.events + ' · ' + fmtDur(r.durMs);
    li.title = 'Double-click or right-click to rename · Ctrl/Shift-click to select several'
      + (r.name === state.current
          ? ' · ' + (prettyHk((state.settings || {}).playKey) || 'F12') + ' plays this recording'
          : '');
    li.addEventListener('click', ev => {
      if (ev.ctrlKey) {                    // toggle this row in the selection
        if (selMacros.has(r.name)) selMacros.delete(r.name);
        else selMacros.add(r.name);
        lastRecIdx = i;
        renderList();
      } else if (ev.shiftKey && lastRecIdx >= 0) {   // extend from the anchor
        const a = Math.min(lastRecIdx, i), b = Math.max(lastRecIdx, i);
        for (let j = a; j <= b; j++) selMacros.add(state.recordings[j].name);
        renderList();
      } else {
        selMacros.clear();
        lastRecIdx = i;
        renderList();                      // clear stale marks before AHK answers
        post({ action: 'select', name: r.name });
      }
    });
    // steps dragged from the step list can be dropped here:
    // plain drop moves them, Ctrl+drop copies them
    li.addEventListener('dragover', ev => {
      if (!dragSteps || r.name === state.current) return;
      ev.preventDefault();
      ev.dataTransfer.dropEffect = ev.ctrlKey ? 'copy' : 'move';
      li.classList.add('droptarget');
    });
    li.addEventListener('dragleave', () => li.classList.remove('droptarget'));
    li.addEventListener('drop', ev => {
      li.classList.remove('droptarget');
      if (!dragSteps || r.name === state.current) return;
      ev.preventDefault();
      post({ action: 'copyStepsTo', target: r.name, ranges: dragSteps,
             move: ev.ctrlKey ? 0 : 1 });
      dragSteps = null;
    });
    li.addEventListener('dblclick', () => renamePrompt(r.name));
    li.addEventListener('contextmenu', ev => {
      ev.preventDefault();
      renamePrompt(r.name);
    });
    ul.appendChild(li);
  });
}

function renderSteps() {
  groupEvents();
  selSteps.clear();
  // a just-completed move re-selects the moved block, so Move up/down and
  // drag-reorder can be repeated without re-clicking the step
  if (restoreStepSel) {
    const [a, b] = restoreStepSel;
    restoreStepSel = null;
    for (let i = Math.max(0, a); i <= Math.min(b, steps.length - 1); i++)
      selSteps.add(i);
  }
  updateDelBtn();
  const body = document.getElementById('stepsBody');
  body.innerHTML = '';
  document.getElementById('stepsEmpty').style.display =
    (state && state.current && steps.length) ? 'none' : '';
  document.getElementById('truncNote').hidden = !truncated;
  const t0 = events.length ? events[0].t : 0;
  // nesting level per bracket + gutter width
  const lvl = new Map();
  for (const l of stepLoops) {
    let v = 0;
    for (const o of stepLoops)
      if (o !== l && o.from <= l.from && o.to >= l.to) v++;
    lvl.set(l, v);
  }
  const maxDepth = stepLoops.length ? Math.max(...stepLoops.map(l => lvl.get(l))) + 1 : 0;
  steps.forEach((s, idx) => {
    // the pause before this step = gap between the previous step's last
    // event and this step's first event; click the cell to change it
    const gap = idx === 0 ? 0 : s.t - events[steps[idx - 1].to - 1].t;
    const tr = document.createElement('tr');
    if (selSteps.has(idx)) tr.classList.add('sel');
    let gut = '';
    if (maxDepth) {
      gut = '<td class="lgut" style="width:' + (maxDepth * 10 + 6) + 'px">';
      for (const l of stepLoops) {
        if (l.to < l.from || idx < l.from || idx > l.to) continue;
        const left = lvl.get(l) * 10 + 2;
        gut += '<span class="lg' + (idx === l.from ? ' top' : '') + (idx === l.to ? ' bot' : '')
             + '" style="left:' + left + 'px"></span>';
        if (idx === l.from)
          gut += '<span class="lgc" style="left:' + left + 'px" data-le="' + l.leEv
               + '" data-count="' + l.count
               + '" title="Click to change the repeat count (0 removes the bracket)">×' + l.count + '</span>';
      }
      gut += '</td>';
    }
    tr.innerHTML = gut + '<td class="n">' + (idx + 1) + '</td><td class="ic">' + s.icon
      + '</td><td class="lb">' + s.html + '</td><td class="tm"></td>';
    tr.querySelectorAll('.lgc').forEach(el => el.addEventListener('click', ev => {
      ev.stopPropagation();
      if (truncated) return;
      const v = prompt('Repeat count (0 removes the bracket):', el.dataset.count);
      const c = parseInt(v, 10);
      if (!isNaN(c) && c >= 0)
        post({ action: 'setRepeatCount', at: +el.dataset.le, count: c });
    }));
    const tm = tr.querySelector('.tm');
    if (idx === 0) {
      tm.textContent = 'start';
    } else {
      const span = document.createElement('span');
      span.className = 'gap';
      span.textContent = '+' + fmtDur(gap);
      span.title = 'Total +' + fmtDur(s.t - t0) + ' — click to change the pause before this step';
      span.addEventListener('click', ev => {
        ev.stopPropagation();
        if (truncated) return;
        const inp = document.createElement('input');
        inp.className = 'gapEdit';
        inp.value = gap;
        const commit = () => {
          const ms = parseInt(inp.value, 10);
          if (!isNaN(ms) && ms >= 0 && ms !== gap)
            post({ action: 'setDelay', at: s.from, ms });
          else
            renderSteps();
        };
        inp.addEventListener('keydown', ke => {
          if (ke.key === 'Enter') inp.blur();
          if (ke.key === 'Escape') { inp.removeEventListener('blur', commit); renderSteps(); }
        });
        inp.addEventListener('blur', commit);
        tm.replaceChildren(inp);
        inp.focus();
        inp.select();
      });
      tm.replaceChildren(span);
    }
    tr.draggable = true;
    tr.addEventListener('dragstart', ev => {
      // dragging inside the delay-edit input must stay text selection
      if (truncated || (ev.target && ev.target.tagName === 'INPUT')) {
        ev.preventDefault();
        return;
      }
      if (!selSteps.has(idx)) {            // dragging an unselected row selects it
        selSteps.clear();
        selSteps.add(idx);
        [...body.children].forEach((row, k) => row.classList.toggle('sel', selSteps.has(k)));
        updateDelBtn();
      }
      dragStepIdxs = [...selSteps].sort((a, b) => a - b);
      dragSteps = dragStepIdxs.map(j => [steps[j].from, steps[j].to]);
      ev.dataTransfer.setData('text/plain', 'encore-steps');
      ev.dataTransfer.effectAllowed = 'copyMove';
    });
    tr.addEventListener('dragend', () => {
      dragSteps = null;
      dragStepIdxs = null;
      document.querySelectorAll('#recList li.droptarget')
        .forEach(el => el.classList.remove('droptarget'));
      document.querySelectorAll('#stepsBody tr.droprow-above, #stepsBody tr.droprow-below')
        .forEach(el => el.classList.remove('droprow-above', 'droprow-below'));
    });
    // In-macro reorder: drop a contiguous selection on another row to move
    // the block before (dropping above it) or after it (dropping below).
    tr.addEventListener('dragover', ev => {
      if (!dragStepIdxs || truncated) return;
      const a = dragStepIdxs[0], b = dragStepIdxs[dragStepIdxs.length - 1];
      if (b - a + 1 !== dragStepIdxs.length) return;   // non-contiguous: no reorder
      if (idx >= a && idx <= b) return;                // over the block itself
      ev.preventDefault();
      ev.dataTransfer.dropEffect = 'move';
      tr.classList.toggle('droprow-above', idx < a);
      tr.classList.toggle('droprow-below', idx > b);
    });
    tr.addEventListener('dragleave', () =>
      tr.classList.remove('droprow-above', 'droprow-below'));
    tr.addEventListener('drop', ev => {
      tr.classList.remove('droprow-above', 'droprow-below');
      if (!dragStepIdxs || truncated) return;
      const a = dragStepIdxs[0], b = dragStepIdxs[dragStepIdxs.length - 1];
      if (b - a + 1 !== dragStepIdxs.length || (idx >= a && idx <= b)) return;
      ev.preventDefault();
      ev.stopPropagation();
      const n = b - a + 1;
      if (idx < a) {
        restoreStepSel = [idx, idx + n - 1];
        post({ action: 'moveEvents', from: steps[a].from, to: steps[b].to,
               destFrom: steps[idx].from, destTo: steps[idx].to, dir: 'up' });
      } else {
        restoreStepSel = [idx - n + 1, idx];
        post({ action: 'moveEvents', from: steps[a].from, to: steps[b].to,
               destFrom: steps[idx].from, destTo: steps[idx].to, dir: 'down' });
      }
      dragSteps = null;
      dragStepIdxs = null;
    });
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
  document.getElementById('btnRepeat').disabled = !selSteps.size || truncated;
  const oneIdx = selSteps.size === 1 ? [...selSteps][0] : -1;
  const one = oneIdx >= 0 ? steps[oneIdx] : null;
  document.getElementById('btnEditStep').disabled = truncated || !(one && one.edit);
  document.getElementById('btnMoveUp').disabled = truncated || oneIdx < 1;
  document.getElementById('btnMoveDown').disabled =
    truncated || oneIdx < 0 || oneIdx >= steps.length - 1;
}

function moveStep(dir) {
  if (selSteps.size !== 1) return;
  const idx = [...selSteps][0];
  const s = steps[idx];
  const dest = steps[idx + (dir === 'up' ? -1 : 1)];
  if (!dest) return;
  const ni = idx + (dir === 'up' ? -1 : 1);
  restoreStepSel = [ni, ni];        // keep the moved step selected
  post({ action: 'moveEvents', from: s.from, to: s.to,
    destFrom: dest.from, destTo: dest.to, dir });
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
  $('stTimeout').value = p.timeout != null ? p.timeout : '10000';
  $('stActive').value = p.active ? '1' : '0';
  $('stCol').value = p.col != null ? p.col : '1';
  applyStepType();
  $('stepModal').hidden = false;
}

function applyStepType() {
  const type = document.getElementById('stType').value;
  document.querySelectorAll('.st-field').forEach(el => {
    el.style.display = el.dataset.for.split(' ').includes(type) ? '' : 'none';
  });
}

function prettyHk(hk) {
  if (!hk) return '';
  const map = { '^': 'Ctrl+', '!': 'Alt+', '+': 'Shift+', '#': 'Win+' };
  let mods = '', i = 0;
  while (i < hk.length && map[hk[i]]) { mods += map[hk[i]]; i++; }
  return mods + hk.slice(i);
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
  // actions that need a selected recording: disable rather than no-op
  const noMacro = !state.current;
  for (const id of ['btnRename', 'btnDelete', 'btnExportAhk', 'btnAddStep',
                    'btnTrim', 'btnSchedule', 'btnSaveProps', 'btnSaveData',
                    'btnCliHelp'])
    document.getElementById(id).disabled = noMacro;
  // hotkey tooltips reflect whatever keys are configured
  const pk = prettyHk((state.settings || {}).playKey) || 'F12';
  const rk = prettyHk((state.settings || {}).recordKey) || 'Shift+F12';
  document.getElementById('btnPlay').title = pk + ' plays the selected recording';
  document.getElementById('btnRecord').title = rk + ' starts and stops recording';
  document.getElementById('btnStop').title = 'Esc or ' + pk + ' stops recording and playback';
  if (state.current !== lastCurrent) {   // another macro picked: fields are its own
    lastCurrent = state.current;
    propsDirty = false;
  }
  // A state push (recording toggled, playback started with F12, …) must not
  // wipe unsaved edits in the props fields — that was "global repeat clears
  // when I press F12". Fields refresh again after Save or macro switch.
  if (!propsDirty) {
    const p = state.macroProps || {};
    document.getElementById('pRepeat').value = p.repeat != null ? p.repeat : '';
    document.getElementById('pPause').value = p.pause != null ? p.pause : '';
    document.getElementById('pSpeed').value = p.speed != null ? p.speed : '';
    document.getElementById('pMode').value = p.mode || '';
    document.getElementById('pHotkey').value = p.hotkey || '';
    document.getElementById('pCoords').value = p.coords || '';
  }
  const dt = document.getElementById('dataText');
  if (document.activeElement !== dt)   // don't clobber while the user types
    dt.value = state.dataText || '';
  updateDataPanel();
}

// ── data panel visibility ──────────────────────────────────────────────
// Explicit choice (the Data button) persists in localStorage; without one
// the panel auto-opens when the macro has a data list or a {value} step.
let hasVStep = false;

function dataPanelChoice() {
  try { return localStorage.getItem('encoreDataPanel'); } catch (e) { return null; }
}

function updateDataPanel() {
  const dt = document.getElementById('dataText');
  const rows = (dt.value.match(/^.*\S.*$/gm) || []).length;
  document.getElementById('dataInfo').textContent = rows ? '· ' + rows + ' rows' : '';
  const choice = dataPanelChoice();
  const visible = choice !== null ? choice === '1' : (rows > 0 || hasVStep);
  document.getElementById('dataPanel').hidden = !visible;
  const btn = document.getElementById('btnDataPanel');
  btn.classList.toggle('active', visible);
  btn.textContent = rows ? 'Data · ' + rows : 'Data';
}

function toggleDataPanel(show) {
  try { localStorage.setItem('encoreDataPanel', show ? '1' : '0'); } catch (e) {}
  updateDataPanel();
}

// ── AHK entry points ───────────────────────────────────────────────────
window.receiveState = function (st) {
  state = st;
  renderState();
};
window.receiveMacro = function (payload) {
  events = payload.events || [];
  truncated = !!payload.truncated;
  hasVStep = events.some(e => e.kind === 'v');
  renderSteps();
  updateDataPanel();
};
window.setMacroFolder = function (dir) {
  const el = document.getElementById('sMacroFolder');
  if (el) el.value = dir;
};
window.receiveTask = function (t) {
  const el = document.getElementById('schStatus');
  if (el) el.textContent = t.exists ? t.info : 'No schedule for this macro.';
  renderAllTasks(t.all || []);
};

function renderAllTasks(list) {
  const wrap = document.getElementById('schAllWrap');
  const tbl = document.getElementById('schAll');
  if (!wrap || !tbl) return;
  wrap.hidden = list.length === 0;
  tbl.innerHTML = '';
  list.forEach(t => {
    const tr = document.createElement('tr');
    if (t.orphan) tr.className = 'orphan';
    const name = document.createElement('td');
    name.textContent = t.name;
    // An orphan still fires — say so, rather than showing a name that means nothing.
    name.title = t.orphan ? 'The macro for this schedule no longer exists' : t.name;
    const next = document.createElement('td');
    next.textContent = t.next || '';
    const act = document.createElement('td');
    const del = document.createElement('button');
    del.textContent = '✕';
    del.title = 'Remove this schedule';
    del.addEventListener('click', () => {
      if (!confirm('Remove the schedule for "' + t.name + '"?')) return;
      post({ action: 'removeTaskNamed', name: t.name });
      document.getElementById('schStatus').textContent = 'Removing…';
    });
    act.appendChild(del);
    tr.append(name, next, act);
    tbl.appendChild(tr);
  });
}

// ── UI wiring ──────────────────────────────────────────────────────────
window.addEventListener('DOMContentLoaded', () => {
  const $ = id => document.getElementById(id);
  $('btnRecord').addEventListener('click', () => post({ action: 'record' }));
  $('btnPlay').addEventListener('click', () => post({ action: 'play' }));
  $('btnStop').addEventListener('click', () => post({ action: 'stop' }));
  $('btnFolder').addEventListener('click', () => post({ action: 'openFolder' }));
  $('btnRename').addEventListener('click', () => {
    if (state && state.current) renamePrompt(state.current);
  });
  $('btnExportAhk').addEventListener('click', () => {
    if (state && state.current) post({ action: 'exportAhk' });
  });
  $('btnDelete').addEventListener('click', () => {
    if (!state) return;
    const names = selMacros.size ? [...selMacros]
                : state.current ? [state.current] : [];
    if (!names.length) return;
    const q = names.length === 1
      ? 'Delete the recording "' + names[0] + '"?'
      : 'Delete these ' + names.length + ' recordings?\n\n' + names.join('\n');
    if (confirm(q)) {
      post({ action: 'deleteMany', names });
      selMacros.clear();
    }
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
      exe: $('stExe').value.trim(), title: $('stTitle').value.trim(),
      timeout: $('stTimeout').value.trim(), active: $('stActive').value,
      col: $('stCol').value.trim() };
    if (stepMode.mode === 'edit')
      post({ action: 'setStep', from: stepMode.from, to: stepMode.to, ...spec });
    else
      post({ action: 'insertStep', at: stepMode.at, ...spec });
    $('stepModal').hidden = true;
  });
  $('btnSaveData').addEventListener('click', () => {
    if (state && state.current)
      post({ action: 'saveData', text: $('dataText').value });
  });
  $('btnDataPanel').addEventListener('click', () =>
    toggleDataPanel($('dataPanel').hidden));
  $('btnDataClose').addEventListener('click', () => toggleDataPanel(false));
  $('dataText').addEventListener('input', updateDataPanel);
  $('btnRepeat').addEventListener('click', () => {
    if (!selSteps.size || truncated) return;
    const sel = [...selSteps].sort((a, b) => a - b);
    const a = sel[0], b = sel[sel.length - 1];
    if (b - a + 1 !== sel.length) { alert('Select a contiguous block of steps.'); return; }
    const v = prompt('Play the selected step' + (sel.length > 1 ? 's' : '')
      + ' how many times?', '2');
    const c = parseInt(v, 10);
    if (isNaN(c) || c < 2) return;
    restoreStepSel = [a, b];       // brackets are not steps — indices keep
    post({ action: 'repeatSteps', from: steps[a].from, to: steps[b].to, count: c });
  });
  $('btnMoveUp').addEventListener('click', () => moveStep('up'));
  $('btnMoveDown').addEventListener('click', () => moveStep('down'));
  $('btnCliHelp').addEventListener('click', () => {
    if (!state || !state.current) return;
    const base = state.cliBase || '"Encore.exe"';
    $('cliName').textContent = state.current;
    $('cliPlayCmd').textContent = base + ' "' + state.current + '"';
    $('cliRunCmd').textContent = "Run '" + base + ' "' + state.current + '"' + "'";
    $('cliModal').hidden = false;
  });
  $('cliCopyPlay').addEventListener('click', () =>
    post({ action: 'copyText', text: $('cliPlayCmd').textContent }));
  $('cliCopyRun').addEventListener('click', () =>
    post({ action: 'copyText', text: $('cliRunCmd').textContent }));
  $('cliReadme').addEventListener('click', () => post({ action: 'openReadme' }));
  $('cliClose').addEventListener('click', () => { $('cliModal').hidden = true; });
  $('btnTrim').addEventListener('click', () => {
    if (state && state.current) post({ action: 'trim' });
  });
  $('btnSchedule').addEventListener('click', () => {
    if (!state || !state.current) return;
    $('schName').textContent = state.current;
    $('schStatus').textContent = 'Checking…';
    $('scheduleModal').hidden = false;
    post({ action: 'queryTask' });
  });
  const schFields = () => {
    const f = $('schFreq').value;
    $('schDayRow').style.display = f === 'WEEKLY' ? '' : 'none';
    $('schDateRow').style.display = f === 'ONCE' ? '' : 'none';
  };
  $('schFreq').addEventListener('change', schFields);
  schFields();
  $('btnSchClose').addEventListener('click', () => { $('scheduleModal').hidden = true; });
  $('btnSchCreate').addEventListener('click', () => {
    post({ action: 'scheduleTask', freq: $('schFreq').value,
      time: $('schTime').value.trim(), day: $('schDay').value,
      date: $('schDate').value.trim() });
    $('schStatus').textContent = 'Creating…';
  });
  $('btnSchRemove').addEventListener('click', () => {
    post({ action: 'removeTask' });
    $('schStatus').textContent = 'Removing…';
  });
  // The props fields AUTO-SAVE: a typed Repeat that was never saved looked
  // saved (the field kept the value) but played once — the classic missed-
  // Save trap. change fires on blur/select, the debounced input catches
  // "type 3, press F12 immediately" without a blur in between.
  const saveProps = () => {
    if (!state || !state.current) return;
    propsDirty = false;
    post({ action: 'saveMacroSettings',
      repeat: $('pRepeat').value.trim(), pause: $('pPause').value.trim(),
      speed: $('pSpeed').value.trim(), mode: $('pMode').value,
      hotkey: $('pHotkey').value.trim(), coords: $('pCoords').value });
  };
  let propsSaveTimer = null;
  for (const id of ['pRepeat', 'pPause', 'pSpeed', 'pMode', 'pHotkey', 'pCoords']) {
    const el = $(id);
    el.addEventListener('input', () => {
      propsDirty = true;
      clearTimeout(propsSaveTimer);
      propsSaveTimer = setTimeout(saveProps, 600);
    });
    el.addEventListener('change', () => { clearTimeout(propsSaveTimer); saveProps(); });
  }
  $('btnSaveProps').addEventListener('click', () => { clearTimeout(propsSaveTimer); saveProps(); });
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
    $('sCountdown').value = s.countdownMs != null ? s.countdownMs : '1000';
    $('sOsd').value = s.playbackOsd ? '1' : '0';
    $('sMacroFolder').value = s.macroFolder || '';
    $('settingsModal').hidden = false;
  });
  $('sBrowse').addEventListener('click', () => post({ action: 'browseMacroFolder' }));
  $('btnSettingsCancel').addEventListener('click', () => { $('settingsModal').hidden = true; });
  $('btnSettingsSave').addEventListener('click', () => {
    post({ action: 'saveSettings',
      recordKey: $('sRecordKey').value.trim(), playKey: $('sPlayKey').value.trim(),
      mode: $('sMode').value, speed: $('sSpeed').value.trim(),
      fixedDelayMs: $('sFixedDelay').value.trim(), repeat: $('sRepeat').value.trim(),
      repeatPauseMs: $('sRepeatPause').value.trim(), anchors: $('sAnchors').value,
      countdownMs: $('sCountdown').value.trim(), playbackOsd: $('sOsd').value,
      macroFolder: $('sMacroFolder').value.trim() });
    $('settingsModal').hidden = true;
  });
  post({ action: 'ready' });
});
