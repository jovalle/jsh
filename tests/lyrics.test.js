const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('lyrics window follows playback, allows browsing, resyncs and rejects stale track responses', async () => {
  class Element extends EventTarget {
    children = [];
    attributes = {};
    style = {};
    clientHeight = 400;
    offsetHeight = 40;
    offsetTop = 500;
    append(...children) {
      const start = this.children.length;
      this.children.push(...children);
      children.forEach((child, i) => {
        child.offsetTop += (start + i) * 60;
      });
    }
    replaceChildren(...children) {
      this.children = [];
      this.append(...children);
    }
    setAttribute(key, value) {
      this.attributes[key] = value;
    }
    removeAttribute(key) {
      delete this.attributes[key];
    }
    focus() {}
    scrollTo({ top }) {
      this.scrollTop = top;
    }
  }
  function document() {
    const nodes = [];
    return {
      documentElement: {},
      head: new Element(),
      body: new Element(),
      createElement(tag) {
        const node = new Element();
        node.tag = tag;
        nodes.push(node);
        return node;
      },
      getElementById(id) {
        return nodes.find((node) => node.id === id);
      },
    };
  }
  const window = new EventTarget();
  let popup,
    tick,
    progress = 0,
    opens = 0,
    clears = 0;
  const requests = [];
  const builder = new Proxy(
    {},
    {
      get: (_, key) =>
        key === 'send' ? () => new Promise((resolve) => requests.push(resolve)) : () => builder,
    },
  );
  const Spicetify = {
    Player: {
      data: { item: { uri: 'spotify:track:first', name: 'First' } },
      getProgress: () => progress,
    },
    Platform: { RequestBuilder: { build: () => builder } },
    showNotification() {
      assert.fail('Unexpected notification');
    },
  };
  window.Spicetify = Spicetify;
  window.documentPictureInPicture = {
    async requestWindow() {
      opens++;
      popup = new EventTarget();
      popup.document = document();
      popup.focus = () => {};
      popup.outerWidth = 460;
      popup.outerHeight = 640;
      popup.resizeTo = (width, height) => {
        popup.outerWidth = width;
        popup.outerHeight = height;
      };
      popup.setInterval = (callback) => {
        tick = callback;
        return 1;
      };
      popup.clearInterval = () => clears++;
      popup.close = () => {
        popup.closed = true;
        popup.dispatchEvent(new Event('pagehide'));
      };
      return popup;
    },
  };
  vm.runInNewContext(fs.readFileSync('conf/spicetify/lyrics.js', 'utf8'), {
    window,
    document: document(),
    Spicetify,
    navigator: { platform: 'MacIntel' },
    console,
    setTimeout,
  });
  const flush = () => new Promise((resolve) => setImmediate(resolve));
  function shortcut() {
    const event = new Event('keydown');
    Object.assign(event, { code: 'KeyL', key: '¬', altKey: true, metaKey: true });
    window.dispatchEvent(event);
  }
  const response = (label) => ({
    body: {
      lyrics: {
        syncType: 'LINE_SYNCED',
        lines: [0, 1000, 2000].map((start) => ({
          startTimeMs: String(start),
          words: `${label}${start}`,
        })),
      },
    },
  });
  shortcut();
  shortcut();
  await flush();
  assert.equal(opens, 1);
  requests.shift()(response('first'));
  await flush();
  const list = popup.document.getElementById('lines');
  const viewport = popup.document.body.children[0];
  assert.equal(viewport.tag, 'main');
  assert.equal(popup.document.body.children.length, 2);
  assert.ok(!popup.document.body.children.some((node) => node.tag === 'header'));
  assert.equal(popup.document.body.children[1].textContent, undefined);
  assert.equal(list.children[0].attributes['aria-current'], 'true');
  const zoom = new Event('keydown', { cancelable: true });
  Object.assign(zoom, { key: '+', ctrlKey: true });
  popup.dispatchEvent(zoom);
  assert.equal(list.style.fontSize, '30px');
  assert.equal(zoom.defaultPrevented, true);
  const mainZoom = new Event('keydown', { cancelable: true });
  Object.assign(mainZoom, { key: '-', metaKey: true });
  window.dispatchEvent(mainZoom);
  assert.equal(list.style.fontSize, '30px');
  assert.equal(mainZoom.defaultPrevented, false);
  const reset = new Event('keydown', { cancelable: true });
  Object.assign(reset, { key: 'º', code: 'Digit0', altKey: true });
  popup.dispatchEvent(reset);
  assert.equal(list.style.fontSize, '28px');
  const context = new Event('contextmenu', { cancelable: true });
  popup.dispatchEvent(context);
  assert.equal(context.defaultPrevented, true);
  assert.equal(popup.document.getElementById('menu'), undefined);
  const initial = viewport.scrollTop;
  progress = 1000;
  tick();
  assert.ok(viewport.scrollTop > initial);
  viewport.dispatchEvent(new Event('wheel'));
  const browsed = viewport.scrollTop;
  progress = 2000;
  tick();
  assert.equal(viewport.scrollTop, browsed);
  assert.equal(list.children[2].attributes['aria-current'], 'true');
  popup.dispatchEvent(new Event('contextmenu', { cancelable: true }));
  assert.ok(viewport.scrollTop > browsed, 'right-click resumes following after browsing');
  viewport.dispatchEvent(new Event('wheel'));
  viewport.scrollTop = 0;
  const resync = new Event('keydown');
  Object.assign(resync, { key: 's' });
  popup.dispatchEvent(resync);
  assert.ok(viewport.scrollTop > 0, 'S still resyncs');
  const beforeResize = viewport.scrollTop;
  viewport.clientHeight = 600;
  popup.dispatchEvent(new Event('resize'));
  assert.equal(viewport.scrollTop, beforeResize - 100);
  Spicetify.Player.data.item = { uri: 'spotify:track:second' };
  tick();
  Spicetify.Player.data.item = { uri: 'spotify:track:third' };
  tick();
  requests.pop()(response('third'));
  await flush();
  requests.shift()(response('second'));
  await flush();
  assert.equal(list.children[0].children[0].textContent, 'third0');
  const grip = popup.document.body.children[1];
  grip.onkeydown({ key: 'ArrowLeft', preventDefault() {} });
  assert.equal(popup.outerWidth, 440);
  for (let n = 0; n < 20; n++) grip.onkeydown({ key: 'ArrowUp', preventDefault() {} });
  assert.equal(popup.outerHeight, 240);
  const escape = new Event('keydown');
  Object.assign(escape, { key: 'Escape' });
  popup.dispatchEvent(escape);
  assert.equal(popup.closed, true);
  assert.equal(clears, 1);
  shortcut();
  await flush();
  assert.equal(opens, 2);
  shortcut();
  assert.equal(popup.closed, true);
  requests.shift()(response('closed'));
  await flush();
  assert.equal(clears, 2);
  shortcut();
  await flush();
  assert.equal(opens, 3);
  const toggle = new Event('keydown');
  Object.assign(toggle, { code: 'KeyL', key: '¬', altKey: true, metaKey: true });
  popup.dispatchEvent(toggle);
  assert.equal(popup.closed, true);
  assert.equal(clears, 3);
});

const patch = fs.readFileSync(
  require('node:path').join(__dirname, '../conf/spicetify/lyrics.ini'),
  'utf8',
);
const find = patch.match(/^dwp-panel-section\.js_find_1001 = (.+)$/m)[1];
const replacement = patch.match(/^dwp-panel-section\.js_repl_1001 = (.+)$/m)[1];
// The real props passed to Spotify's native lyric renderer in 1.3.1.
const original = 'data:{...t,isTimeSynced:!o&&t.isTimeSynced},format:"card",isSnippet:o,';
const props = process.env.LYRICS_PREVIEW_UNPATCHED
  ? original
  : original.replace(new RegExp(find), replacement);

test('collapsed synced lyrics retain timing and the full line set; capped and unsynced previews stay intact', () => {
  for (const collapsed of [true, false]) {
    for (const synced of [true, false]) {
      for (const capStatus of ['NOT_CAPPED', 'CAPPED']) {
        const t = {
          isTimeSynced: synced,
          capStatus,
          lyrics: ['first', 'later'],
          previewLines: ['first'],
        };
        const result = vm.runInNewContext(`({${props}})`, { t, o: collapsed });
        const preview = collapsed && (!synced || capStatus === 'CAPPED');
        assert.equal(result.isSnippet, preview);
        assert.equal(result.data.isTimeSynced, synced && (!collapsed || capStatus !== 'CAPPED'));
        assert.equal(result.data.lyrics, t.lyrics);
        assert.equal(result.data.previewLines, t.previewLines);
      }
    }
  }
  assert.equal(props.replace(new RegExp(find), replacement), props, 'patch is idempotent');
});
