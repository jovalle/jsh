const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(`${__dirname}/../conf/spicetify/mini.js`, 'utf8');

function harness() {
  const calls = [];
  const reports = [];
  let resync;
  const Spicetify = {
    Player: {
      data: { item: { uri: 'spotify:track:first', name: 'First', artists: [], metadata: {} } },
    },
    Platform: { LocalStorageAPI: { namespace: 'account' } },
  };
  const window = {
    JshMiniBridge: { token: 'a'.repeat(64), port: 47683 },
    JshMusic: {
      like: {
        state: () => undefined,
        toggle: async (uri) => {
          calls.push(uri);
          return { ok: true, message: 'Liked' };
        },
      },
      love: { state: () => false, toggle: async () => ({ ok: true }) },
      add: {
        removalState: () => ({
          enabled: true,
          action: 'remove',
          context: 'spotify:playlist:one',
          itemUid: 'playing',
          provider: 'context',
          id: '',
        }),
        changePlayingPlaylist: async (action, selection) => {
          calls.push({ action, selection });
          return { ok: true };
        },
        toggle: () => calls.push('add'),
      },
    },
    addEventListener() {},
  };
  vm.runInNewContext(source, {
    window,
    Spicetify,
    setTimeout(callback) {
      resync = callback;
    },
    clearTimeout() {},
    AbortSignal,
    fetch: async (_, options) => {
      reports.push(JSON.parse(options.body));
      return { ok: true, json: async () => ({ commands: [] }) };
    },
  });
  const command = (id, action = 'like') => ({
    id,
    action,
    uri: 'spotify:track:first',
    account: 'account',
    expires: Date.now() + 5000,
  });
  return {
    api: window.JshMusic.mini,
    window,
    Spicetify,
    calls,
    command,
    reports,
    resync: () => resync(),
  };
}

test('mini exposes track metadata and curation state without requesting removed audio or genre metadata', () => {
  const h = harness();
  const state = h.api.state();
  assert.equal(state.title, 'First');
  assert.equal(state.artist, 'Artist unavailable');
  assert.equal(state.album, 'Album unavailable');
  for (const field of ['key', 'bpm', 'genres']) assert.equal(field in state, false);
  h.Spicetify.getAudioData = () => assert.fail('Removed audio metadata must not be requested');
  h.Spicetify.CosmosAsync = {
    get: () => assert.fail('Removed artist genres must not be requested'),
  };
  h.Spicetify.Player.data.item = {
    uri: 'spotify:track:second',
    artists: [{ uri: 'spotify:artist:one', name: 'Artist' }],
  };
  assert.equal(h.api.state().artist, 'Artist');
  assert.equal(state.liked, null);
  assert.equal(state.loved, false);
});

test('mini rejects expired, account changed, track changed, and retired playlist shortcut commands', async () => {
  const h = harness();
  await h.api.execute({ ...h.command('expired'), expires: Date.now() - 1 });
  await h.api.execute({ ...h.command('account'), account: 'other' });
  await h.api.execute({ ...h.command('track'), uri: 'spotify:track:other' });
  await h.api.execute({ ...h.command('slot', 'quick-add'), slot: 2 });
  await h.api.execute(h.command('unknown', 'eval'));
  assert.equal(h.calls.length, 0);
});

test('mini reserves command IDs before awaiting and routes each action once', async () => {
  const h = harness();
  let release;
  h.window.JshMusic.like.toggle = (uri) => {
    h.calls.push(uri);
    return new Promise((resolve) => {
      release = resolve;
    });
  };
  const pending = h.api.execute(h.command('same'));
  await h.api.execute(h.command('same'));
  assert.equal(h.calls.length, 1);
  release({ ok: true });
  await pending;
  await h.api.execute(h.command('same'));
  assert.equal(h.calls.length, 1);
  await h.api.execute(h.command('add', 'add'));
  assert.equal(h.calls[1], 'add');
});

test('mini forwards explicit Like/Love targets and a context check to queued writes', async () => {
  const h = harness();
  const received = [];
  for (const action of ['like', 'love']) {
    h.window.JshMusic[action].toggle = async (uri, value, validate) => {
      received.push({ action, uri, value });
      validate();
      h.Spicetify.Player.data.item.uri = 'spotify:track:other';
      assert.throws(validate, /Track changed/);
      return { ok: true };
    };
    h.Spicetify.Player.data.item.uri = 'spotify:track:first';
    await h.api.execute({ ...h.command(action, action), value: false });
  }
  assert.deepEqual(
    received.map(({ value }) => value),
    [false, false],
  );
  h.Spicetify.Player.data.item.uri = 'spotify:track:first';
  await h.api.execute({ ...h.command('invalid'), value: 'false' });
  assert.equal(received.length, 2);
});

test('mini retries unavailable or invalid bootstrap configuration and then connects', async () => {
  const h = harness();
  delete h.window.JshMiniBridge;
  let retry;
  const delays = [];
  let requests = 0;
  let synced = false;
  vm.runInNewContext(source, {
    window: h.window,
    Spicetify: h.Spicetify,
    navigator: { platform: 'MacIntel' },
    AbortSignal,
    setTimeout(callback, delay) {
      delays.push(delay);
      retry = callback;
    },
    clearTimeout() {},
    fetch: async (url) => {
      if (url === '/extensions/mini-bridge.json') {
        requests += 1;
        if (requests === 1) return { ok: false };
        return {
          ok: true,
          json: async () => (requests === 2 ? {} : { token: 'a'.repeat(64), port: 47683 }),
        };
      }
      synced = true;
      return { ok: true, json: async () => ({ commands: [] }) };
    },
  });
  await new Promise(setImmediate);
  assert.equal(typeof retry, 'function');
  retry();
  await new Promise(setImmediate);
  assert.equal(h.window.JshMiniBridge, undefined);
  retry();
  await new Promise(setImmediate);
  assert.equal(requests, 3);
  assert.equal(synced, true);
  assert.equal(h.window.JshMiniBridge.port, 47683);
  assert.deepEqual(delays.slice(0, 2), [5000, 10000]);
});

test('mini bounds and backs off bootstrap retries when the companion is absent', async () => {
  const h = harness();
  delete h.window.JshMiniBridge;
  const pending = [];
  const delays = [];
  let requests = 0;
  vm.runInNewContext(source, {
    window: h.window,
    Spicetify: h.Spicetify,
    navigator: { platform: 'MacIntel' },
    setTimeout(callback, delay) {
      pending.push(callback);
      delays.push(delay);
    },
    fetch: async () => {
      requests += 1;
      return { ok: false };
    },
  });
  await new Promise(setImmediate);
  for (let attempt = 0; attempt < 5; attempt++) {
    assert.equal(pending.length, 1);
    pending.shift()();
    await new Promise(setImmediate);
  }
  assert.equal(requests, 6);
  assert.equal(pending.length, 0);
  assert.deepEqual(delays, [5000, 10000, 20000, 30000, 30000]);
});

test('mini captures playlist occurrence and Undo identity; rejects stale or unavailable removals', async () => {
  const h = harness();
  const removal = h.api.state().removal;
  await h.api.execute({ ...h.command('remove', 'remove'), removal });
  assert.equal(h.calls[0].action, 'remove');
  await h.api.execute({ ...h.command('remove', 'remove'), removal });
  assert.equal(h.calls.length, 1);
  for (const patch of [
    { context: 'spotify:playlist:other' },
    { itemUid: 'duplicate' },
    { provider: 'queue' },
    { id: 'old' },
  ]) {
    await h.api.execute({
      ...h.command(JSON.stringify(patch), 'remove'),
      removal: { ...removal, ...patch },
    });
  }
  h.window.JshMusic.add.removalState = () => ({ ...removal, action: 'undo', id: 'record' });
  await h.api.execute({ ...h.command('stale', 'remove'), removal });
  await h.api.execute({ ...h.command('undo', 'undo'), removal: h.api.state().removal });
  assert.equal(h.calls.length, 2);
  assert.equal(h.calls[1].action, 'undo');
  h.window.JshMusic.add.removalState = () => ({ ...removal, enabled: false });
  await h.api.execute({ ...h.command('disabled', 'remove'), removal });
  assert.equal(h.calls.length, 2);
});

test('Add toggles the picker silently and retired playlist shortcuts cannot mutate', async () => {
  const h = harness();
  await h.api.execute(h.command('add-silent', 'add'));
  await h.api.execute({ ...h.command('retired-slot', 'quick-add'), slot: 0 });
  await h.resync();
  const results = h.reports.at(-1).results;
  assert.equal(results.find((r) => r.id === 'add-silent').message, '');
  assert.equal(results.find((r) => r.id === 'retired-slot').ok, false);
  assert.deepEqual(h.calls, ['add']);
});
