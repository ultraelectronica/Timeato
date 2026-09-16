// Timeato web shell.
//
// Deliberately dumb: Zig owns the state machine and builds the whole view as a
// Zylix virtual DOM tree. This file only (1) pumps wall-clock deltas into the
// engine and (2) morphs that tree into real DOM nodes.

const Timeato = {
  wasm: null,
  memory: null,
  container: null,
  ready: false,
  running: false,
  last: 0,

  async init(wasmPath, container) {
    const response = await fetch(wasmPath);
    if (!response.ok) throw new Error(`could not fetch ${wasmPath} (${response.status})`);

    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    this.wasm = instance.exports;
    this.memory = this.wasm.memory;
    this.container = container;
    this.wasm.timeato_init();
    this.ready = true;

    container.addEventListener('click', (event) => this.onClick(event));
    this.render();
    requestAnimationFrame((now) => this.loop(now));
  },

  onClick(event) {
    const button = event.target.closest('[data-action]');
    if (!button) return;
    this.wasm.timeato_dispatch(Number(button.getAttribute('data-action')));
    this.render();
  },

  view() {
    const ptr = this.wasm.timeato_render();
    const len = Number(this.wasm.timeato_render_len());
    const bytes = new Uint8Array(this.memory.buffer, ptr, len);
    return JSON.parse(new TextDecoder().decode(bytes));
  },

  render() {
    if (!this.ready) return;
    const view = this.view();
    this.running = view.running;

    const current = this.container.firstElementChild;
    const next = morph(current, view.tree);
    if (next !== current) this.container.replaceChildren(next);
  },

  // rAF is paused while the tab is hidden, so the first frame back delivers the
  // full elapsed delta. That keeps the timer honest across background tabs.
  loop(now) {
    if (this.last === 0) this.last = now;
    const delta = now - this.last;
    this.last = now;

    if (this.running && delta > 0) {
      this.wasm.timeato_tick(Math.round(delta));
      this.render();
    }
    requestAnimationFrame((next) => this.loop(next));
  },
};

function morph(element, vnode) {
  if (vnode.t === '#text') {
    if (element && element.nodeType === 3) {
      if (element.data !== vnode.x) element.data = vnode.x;
      return element;
    }
    const text = document.createTextNode(vnode.x || '');
    if (element) element.replaceWith(text);
    return text;
  }

  if (!element || element.nodeType !== 1 || element.tagName.toLowerCase() !== vnode.t) {
    const created = document.createElement(vnode.t);
    patch(created, vnode);
    if (element) element.replaceWith(created);
    return created;
  }

  patch(element, vnode);
  return element;
}

function patch(element, vnode) {
  const className = vnode.c || '';
  if (element.getAttribute('class') !== className) element.setAttribute('class', className);

  if (vnode.a) element.setAttribute('data-action', String(vnode.a));
  else element.removeAttribute('data-action');

  const children = vnode.ch || [];
  const existing = Array.from(element.childNodes);
  const total = Math.max(existing.length, children.length);

  for (let i = 0; i < total; i++) {
    const child = children[i];
    const node = existing[i];
    if (child && node) {
      const result = morph(node, child);
      if (result !== node) element.replaceChild(result, node);
    } else if (child) {
      element.appendChild(morph(null, child));
    } else if (node) {
      element.removeChild(node);
    }
  }
}
