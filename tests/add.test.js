const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'conf', 'spicetify', 'add.js'), 'utf8');

test('playlist overlay backgrounds survive missing Spicetify theme variables', () => {
  assert.match(
    source,
    /--adder-surface: var\(--background-elevated-base, var\(--spice-main, #282828\)\)/,
  );
  assert.match(source, /\.panel \{ background-color: var\(--adder-surface\)/);
  assert.match(source, /\.item-card \{[^}]*background-color: var\(--adder-fill\)/);
});

test('native plus opens the playlist menu on macOS', () => {
  const listeners = {};
  const shortcuts = [];
  let menuEvent;
  class Element {
    closest(selector) {
      return selector === 'button[aria-checked="false"]' ? this : null;
    }
  }
  const button = new Element();
  button.isConnected = true;
  button.__reactFiber$test = {
    memoizedProps: {
      curateDefault() {},
      handleContextMenu(event) {
        menuEvent = event;
      },
      uri: 'spotify:track:test',
    },
  };
  button.setAttribute = (name, value) => {
    if (name === 'aria-label') button.ariaLabel = value;
  };
  const Spicetify = {
    ContextMenu: {},
    Keyboard: { registerShortcut: (shortcut) => shortcuts.push(shortcut) },
    Player: {},
  };
  vm.runInNewContext(source, {
    document: {
      addEventListener() {},
      body: {},
      createElement: () => ({}),
      getElementById: () => null,
      head: { append() {} },
      querySelectorAll: () => [button],
    },
    Element,
    MutationObserver: class {
      observe() {}
    },
    navigator: { userAgentData: { platform: 'macOS' }, platform: 'MacIntel' },
    requestAnimationFrame: (callback) => callback(),
    Spicetify,
    window: {
      Spicetify,
      addEventListener: (type, handler) => {
        listeners[type] = handler;
      },
    },
  });

  const event = {
    target: button,
    type: 'click',
    preventDefault() {
      this.prevented = true;
    },
    stopPropagation() {
      this.stopped = true;
    },
  };
  listeners.click(event);
  assert.equal(button.ariaLabel, 'Add to Playlists');
  assert.equal(menuEvent.currentTarget, button);
  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true);
  assert.equal(shortcuts[0].meta, true);
});

function addHarness() {
  const Platform = { LocalStorageAPI: { namespace: 'first-account' } };
  const Spicetify = {
    Platform,
    Player: { data: { item: { uri: 'spotify:track:first' } } },
    ContextMenu: {},
    Keyboard: { registerShortcut() {} },
    showNotification() {},
  };
  const window = { Spicetify, addEventListener() {} };
  vm.runInNewContext(source, {
    window,
    Spicetify,
    document: {
      addEventListener() {},
      createElement: () => ({}),
      head: { append() {} },
      body: {},
      querySelectorAll: () => [],
    },
    navigator: { platform: 'MacIntel' },
    MutationObserver: class {
      observe() {}
    },
    requestAnimationFrame: (callback) => callback(),
  });
  return { api: window.JshMusic.add, Platform, Spicetify };
}

function removalHarness() {
  const h = addHarness();
  const uri = 'spotify:track:first';
  let rows = [
    { uri: 'spotify:track:before', uid: 'before' },
    { uri, uid: 'playing' },
    { uri, uid: 'duplicate' },
    { uri: 'spotify:track:after', uid: 'after' },
  ];
  let sequence = 0;
  const data = h.Spicetify.Player.data;
  data.context = { uri: 'spotify:playlist:one' };
  data.item = { uri, uid: 'playing', provider: 'context' };
  const mutations = [];
  h.Platform.PlaylistAPI = {
    getMetadata: async () => ({ canAdd: true, canRemove: true, name: 'First playlist' }),
    getContents: async (_, { offset, limit }) => ({
      items: rows.slice(offset, offset + limit),
      totalLength: rows.length,
    }),
    remove: async (context, items) => {
      mutations.push({ action: 'remove', context, items: JSON.parse(JSON.stringify(items)) });
      rows = rows.filter((row) => !items.some((item) => item.uid === row.uid));
    },
    add: async (context, items, position) => {
      mutations.push({ action: 'add', context, items, position });
      const anchor = position.before || position.after;
      const index =
        anchor === 'start'
          ? 0
          : anchor === 'end'
            ? rows.length
            : rows.findIndex((row) => row.uid === anchor.uid) + (position.after ? 1 : 0);
      rows.splice(index, 0, { uri: items[0], uid: `restored-${++sequence}` });
    },
  };
  return {
    ...h,
    data,
    mutations,
    get rows() {
      return rows;
    },
    set rows(value) {
      rows = value;
    },
    async selection() {
      h.api.removalState();
      await new Promise(setImmediate);
      return h.api.removalState();
    },
    change: (action, state = h.api.removalState()) => h.api.changePlayingPlaylist(action, state),
  };
}

test('Remove deletes the playing duplicate only; Undo restores its position and repeated Remove uses the new UID', async () => {
  const h = removalHarness();
  assert.equal((await h.selection()).enabled, true);
  assert.equal((await h.change('remove')).ok, true);
  assert.deepEqual(
    h.rows.map((row) => row.uid),
    ['before', 'duplicate', 'after'],
  );
  assert.equal(h.api.removalState().action, 'undo');
  assert.equal((await h.change('undo')).ok, true);
  assert.deepEqual(
    h.rows.map((row) => row.uid),
    ['before', 'restored-1', 'duplicate', 'after'],
  );
  assert.equal((await h.change('remove')).ok, true);
  assert.equal(h.mutations[2].items[0].uid, 'restored-1');
});

test('Undo survives pause; expires on occurrence, context, provider, track or account transition', async () => {
  for (const change of [
    (h) => {
      h.data.item.uid = 'duplicate';
    },
    (h) => {
      h.data.context.uri = 'spotify:playlist:other';
    },
    (h) => {
      h.data.item.provider = 'queue';
    },
    (h) => {
      h.data.item.uri = 'spotify:track:other';
    },
    (h) => {
      h.Platform.LocalStorageAPI.namespace = 'other-account';
    },
  ]) {
    const h = removalHarness();
    await h.selection();
    await h.change('remove');
    h.data.isPaused = true;
    assert.equal(h.api.removalState().action, 'undo');
    change(h);
    assert.equal(h.api.removalState().action, 'remove');
    h.data.item.uid = 'playing';
    assert.equal(h.api.removalState().action, 'remove');
  }
});

test('Remove fails closed for non-playlist, queued, missing UID, unknown permissions and changed selection', async () => {
  for (const change of [
    (h) => {
      h.data.context.uri = 'spotify:album:one';
    },
    (h) => {
      h.data.item.provider = 'queue';
    },
    (h) => {
      h.data.item.provider = 'autoplay';
    },
    (h) => {
      h.data.item.uid = '';
    },
    (h) => {
      h.Platform.PlaylistAPI.getMetadata = async () => ({ canAdd: true });
    },
    (h) => {
      h.Platform.PlaylistAPI.getMetadata = async () => ({ canRemove: true });
    },
  ]) {
    const h = removalHarness();
    change(h);
    assert.equal((await h.selection()).enabled, false);
    assert.equal((await h.change('remove')).ok, false);
    assert.equal(h.mutations.length, 0);
  }
  const h = removalHarness();
  const expected = await h.selection();
  h.Platform.PlaylistAPI.getMetadata = async () => {
    h.data.item.uid = 'duplicate';
    return { canAdd: true, canRemove: true };
  };
  assert.equal((await h.change('remove', expected)).ok, false);
  assert.equal(h.mutations.length, 0);
});

test('Remove serializes repeats, and an intercepted mutation never reports success', async () => {
  const h = removalHarness();
  const expected = await h.selection();
  let release;
  h.Platform.PlaylistAPI.remove = () =>
    new Promise((resolve) => {
      release = resolve;
    });
  const pending = h.change('remove', expected);
  await new Promise(setImmediate);
  assert.equal((await h.change('remove', expected)).ok, false);
  release();
  assert.equal((await pending).ok, false);
  assert.equal(h.api.removalState().action, 'remove');
});

test('Undo verifies uncertain writes and external restores without duplicating membership', async () => {
  const h = removalHarness();
  await h.selection();
  const remove = h.Platform.PlaylistAPI.remove;
  h.Platform.PlaylistAPI.remove = async (...args) => {
    await remove(...args);
    throw new Error('Lost response');
  };
  assert.equal((await h.change('remove')).ok, false);
  assert.equal(h.api.removalState().action, 'undo');
  const add = h.Platform.PlaylistAPI.add;
  h.Platform.PlaylistAPI.add = async (...args) => {
    await add(...args);
    throw new Error('Lost add response');
  };
  assert.equal((await h.change('undo')).ok, false);
  assert.equal((await h.change('undo')).ok, true);
  assert.equal(h.mutations.filter((m) => m.action === 'add').length, 1);
  assert.equal(h.api.removalState().action, 'remove');

  const external = removalHarness();
  await external.selection();
  await external.change('remove');
  external.rows.splice(1, 0, { uri: external.data.item.uri, uid: 'external-restore' });
  assert.equal((await external.change('undo')).ok, true);
  assert.equal(external.mutations.length, 1);
});

test('Undo checks fresh permissions and rejects reversed or lost placement anchors', async () => {
  for (const alter of [
    (h) => {
      h.rows.reverse();
    },
    (h) => {
      h.rows = [];
    },
    (h) => {
      h.Platform.PlaylistAPI.getMetadata = async () => ({ canRemove: true });
    },
  ]) {
    const h = removalHarness();
    await h.selection();
    await h.change('remove');
    alter(h);
    assert.equal((await h.change('undo')).ok, false);
    assert.equal(h.mutations.length, 1);
    assert.equal(h.api.removalState().action, 'undo');
  }
});

test('Undo restores boundary and sole entries; Remove reads natural order through multiple pages', async () => {
  for (const index of [0, 1, 2]) {
    const h = removalHarness();
    h.rows = [
      { uri: 'spotify:track:x', uid: 'x' },
      { uri: 'spotify:track:y', uid: 'y' },
    ];
    h.rows.splice(index, 0, { uri: h.data.item.uri, uid: 'playing' });
    await h.selection();
    await h.change('remove');
    assert.equal((await h.change('undo')).ok, true);
    assert.equal(h.rows[index].uid, 'restored-1');
  }
  const sole = removalHarness();
  sole.rows = [{ uri: sole.data.item.uri, uid: 'playing' }];
  await sole.selection();
  await sole.change('remove');
  assert.equal((await sole.change('undo')).ok, true);

  const paged = removalHarness();
  paged.rows = Array.from({ length: 205 }, (_, i) => ({ uri: 'spotify:track:other', uid: `${i}` }));
  paged.rows[150] = { uri: paged.data.item.uri, uid: 'playing' };
  await paged.selection();
  await paged.change('remove');
  assert.equal((await paged.change('undo')).ok, true);
  assert.equal(paged.rows[150].uid, 'restored-1');
});

test('Undo refuses external or uncertain matching entries at the wrong position', async () => {
  for (const lostResponse of [false, true]) {
    const h = removalHarness();
    await h.selection();
    await h.change('remove');
    if (lostResponse) {
      h.Platform.PlaylistAPI.add = async () => {
        h.rows.push({ uri: h.data.item.uri, uid: 'wrong-slot' });
        throw new Error('Lost response');
      };
      assert.equal((await h.change('undo')).ok, false);
    } else h.rows.push({ uri: h.data.item.uri, uid: 'external-wrong-slot' });
    assert.equal((await h.change('undo')).ok, false);
    assert.equal(h.api.removalState().action, 'undo');
    assert.equal(h.rows.filter((row) => row.uri === h.data.item.uri).length, 2);
  }
});

test('Undo rejects a resolved add at the wrong position and cannot remove an unrelated external restore', async () => {
  const h = removalHarness();
  await h.selection();
  await h.change('remove');
  h.Platform.PlaylistAPI.add = async () => {
    h.rows.push({ uri: h.data.item.uri, uid: 'wrong-slot' });
  };
  assert.equal((await h.change('undo')).ok, false);
  assert.equal(h.api.removalState().action, 'undo');
  const external = removalHarness();
  await external.selection();
  await external.change('remove');
  external.rows.splice(1, 0, { uri: external.data.item.uri, uid: 'external-restore' });
  assert.equal((await external.change('undo')).ok, true);
  assert.equal((await external.change('remove')).ok, false);
  assert.equal(external.mutations.length, 1);
});
