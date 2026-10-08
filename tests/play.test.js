const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'conf', 'spicetify', 'play.js'), 'utf8');

async function runRoute(pathname, randomValues, options = {}) {
  const playlistItems = options.rootItems || [
    { name: 'First', uri: 'spotify:playlist:first', type: 'playlist' },
    {
      items: [{ name: 'Second', uri: 'spotify:playlist:second', type: 'playlist' }],
      type: 'folder',
    },
  ];
  const calls = {
    contextualShuffle: null,
    history: [],
    library: null,
    notifications: [],
    play: null,
    playlist: [],
    rootlist: 0,
    shuffle: [],
  };
  const Spicetify = {
    Platform: {
      LibraryAPI: {
        async getTracks(options) {
          calls.library = options;
          return { items: Array.from({ length: 5 }, (_, index) => ({ uri: `track:${index}` })) };
        },
      },
      History: {
        listen() {},
        location: { pathname },
        replace(value) {
          calls.history.push(value);
          calls.replace = value;
        },
      },
      PlaylistAPI: {
        async getContents(uri, requestOptions) {
          calls.playlist.push({ options: requestOptions, uri });
          return options.playlists?.[uri] || { items: [], totalLength: 7 };
        },
      },
      RootlistAPI: {
        async getContents() {
          calls.rootlist += 1;
          return { items: playlistItems };
        },
      },
    },
    Player: {
      data: { context: { uri: 'spotify:playlist:current' } },
      origin: {
        _contextualShuffle: {
          async setContextualShuffleMode(uri, mode) {
            calls.contextualShuffle = { mode, uri };
          },
        },
      },
      async playUri(...args) {
        calls.play = args;
      },
      setShuffle(value) {
        calls.shuffle.push(value);
      },
    },
    URI: {
      fromString(uri) {
        return { toURLPath: () => `/context/${uri}` };
      },
    },
    showNotification(message) {
      calls.notifications.push(message);
    },
  };
  const window = {
    Spicetify,
    addEventListener() {},
    crypto: {
      getRandomValues(value) {
        value[0] = randomValues.shift();
        return value;
      },
    },
  };

  vm.runInNewContext(source, { console, Spicetify, Uint32Array, URLSearchParams, window });
  for (let attempt = 0; attempt < 20 && !calls.play; attempt += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.ok(calls.play, 'shuffle route did not start playback');
  assert.deepEqual(calls.notifications, []);
  return calls;
}

test('default play starts sequentially from a random Liked Songs position', async () => {
  const calls = await runRoute('/search/spotifix-play-library-sequential-test', [0, 3]);

  assert.deepEqual(calls.shuffle, [false, false]);
  assert.equal(
    JSON.stringify(calls.play),
    JSON.stringify(['spotify:collection:tracks', {}, { skipTo: { index: 3 } }]),
  );
  assert.equal(JSON.stringify(calls.library), JSON.stringify({ offset: 0, limit: 50000 }));
});

test('default play starts sequentially from a random playlist position', async () => {
  const calls = await runRoute('/search/spotifix-play-library-sequential-test', [1, 4]);

  assert.deepEqual(calls.shuffle, [false, false]);
  assert.equal(
    JSON.stringify(calls.play),
    JSON.stringify(['spotify:playlist:first', {}, { skipTo: { index: 4 } }]),
  );
  assert.equal(
    JSON.stringify(calls.playlist[0]),
    JSON.stringify({
      options: { offset: 0, limit: 1 },
      uri: 'spotify:playlist:first',
    }),
  );
});

test('liked selector starts at a random Liked Songs position', async () => {
  const calls = await runRoute('/search/spotifix-play-liked-sequential-test', [0, 2]);

  assert.equal(
    JSON.stringify(calls.play),
    JSON.stringify(['spotify:collection:tracks', {}, { skipTo: { index: 2 } }]),
  );
});

test('playlist selector starts a random saved playlist from the beginning', async () => {
  const calls = await runRoute('/search/spotifix-play-playlist-sequential-test', [1]);

  assert.equal(calls.rootlist, 1);
  assert.deepEqual(calls.play, ['spotify:playlist:second']);
});

test('180g selector deduplicates albums and plays one from the beginning', async () => {
  const calls = await runRoute('/search/spotifix-play-180g-sequential-test', [1], {
    rootItems: [{ name: '180g', type: 'playlist', uri: 'spotify:playlist:180g' }],
    playlists: {
      'spotify:playlist:180g': {
        items: [
          { album: { uri: 'spotify:album:first' } },
          { album: { uri: 'spotify:album:first' } },
          { album: { uri: 'spotify:album:second' } },
        ],
        totalLength: 3,
      },
    },
  });

  assert.equal(calls.history[0], '/');
  assert.deepEqual(calls.play, ['spotify:album:second']);
  assert.equal(calls.history.at(-1), '/context/spotify:album:second');
});

test('shuffle modifier enables normal shuffle after selecting playback', async () => {
  const calls = await runRoute('/search/spotifix-play-liked-shuffle-test', [0, 2]);

  assert.deepEqual(calls.shuffle, [false, true]);
  assert.equal(calls.contextualShuffle, null);
});

test('smart-shuffle modifier enables contextual smart shuffle', async () => {
  const calls = await runRoute('/search/spotifix-play-liked-smart-shuffle-test', [0, 2]);

  assert.deepEqual(calls.shuffle, [false]);
  assert.deepEqual(calls.contextualShuffle, { mode: 2, uri: 'spotify:collection:tracks' });
});

class Element {
  constructor(selector) {
    this.selector = selector;
  }

  closest(selector) {
    return selector.split(', ').includes(this.selector) ? this : null;
  }
}

const barTitle = '.main-nowPlayingWidget-trackInfo .main-trackInfo-name a';

function clickTitle(playerData, eventOverrides = {}) {
  const pushed = [];
  const listeners = [];
  const Spicetify = {
    Platform: {
      History: {
        listen() {},
        location: { pathname: '/' },
        push(value) {
          pushed.push({ pathname: value.pathname, search: value.search });
        },
      },
    },
    Player: { data: playerData, playUri() {} },
    URI: {
      fromString(uri) {
        const [, type, id] = uri.split(':');
        return { toURLPath: () => `/${type}/${id}` };
      },
    },
  };
  const window = {
    Spicetify,
    addEventListener(type, listener, capture) {
      listeners.push({ capture, listener, type });
    },
  };
  vm.runInNewContext(source, { console, Element, Spicetify, URLSearchParams, window });

  const event = {
    button: 0,
    defaultPrevented: false,
    propagationStopped: false,
    target: new Element(barTitle),
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {
      this.propagationStopped = true;
    },
    ...eventOverrides,
  };
  for (const { capture, listener, type } of listeners) {
    if (type === 'click' && capture) listener(event);
  }
  return { event, pushed };
}

test('now-playing title highlights the playing row in its playlist', () => {
  const { event, pushed } = clickTitle({
    context: { uri: 'spotify:playlist:abc' },
    item: { uid: 'row1', uri: 'spotify:track:t1' },
    index: { pageIndex: 2, pageURI: 'spotify:playlist:abc:page:2', itemIndex: 37 },
  });

  assert.deepEqual(pushed, [
    {
      pathname: '/playlist/abc',
      search:
        '?uid=row1&uri=spotify%3Atrack%3At1&page=2&pageUri=spotify%3Aplaylist%3Aabc%3Apage%3A2&index=37',
    },
  ]);
  assert.equal(event.defaultPrevented, true);
  assert.equal(event.propagationStopped, true);
});

test('now-playing view title also opens the playing context', () => {
  const { pushed } = clickTitle(
    {
      context: { uri: 'spotify:collection:tracks' },
      item: { uid: 'row2', uri: 'spotify:track:t2' },
      index: { pageIndex: 0, pageURI: 'spotify:collection:tracks:page:0', itemIndex: 41 },
    },
    { target: new Element('.main-nowPlayingView-trackInfo .main-trackInfo-name a') },
  );

  assert.deepEqual(pushed, [
    {
      pathname: '/collection/tracks',
      search:
        '?uid=row2&uri=spotify%3Atrack%3At2&page=0&pageUri=spotify%3Acollection%3Atracks%3Apage%3A0&index=41',
    },
  ]);
});

test('now-playing title uses the playing item index in an album context', () => {
  const { pushed } = clickTitle({
    context: { uri: 'spotify:album:alb' },
    item: { uid: 'row3', uri: 'spotify:track:t3' },
    index: { pageIndex: 0, itemIndex: 12 },
  });

  assert.deepEqual(pushed, [
    {
      pathname: '/album/alb',
      search: '?uid=row3&uri=spotify%3Atrack%3At3&page=0&index=12',
    },
  ]);
});

test('now-playing title opens the album when the track is its own context', () => {
  const { event, pushed } = clickTitle({
    context: { uri: 'spotify:track:t4' },
    item: { uid: 'row4', uri: 'spotify:track:t4', album: { uri: 'spotify:album:alb' } },
    index: { pageIndex: 0, itemIndex: 0 },
  });

  assert.deepEqual(pushed, [
    {
      pathname: '/album/alb',
      search: '?uid=row4&uri=spotify%3Atrack%3At4&page=0&index=0&highlight=spotify%3Atrack%3At4',
    },
  ]);
  assert.equal(event.defaultPrevented, true);
});

test('modified now-playing title clicks keep native behavior', () => {
  const { event, pushed } = clickTitle(
    {
      context: { uri: 'spotify:playlist:abc' },
      item: { uid: 'row1', uri: 'spotify:track:t1' },
    },
    { metaKey: true },
  );

  assert.deepEqual(pushed, []);
  assert.equal(event.defaultPrevented, false);
});

test('clicks outside the now-playing title are ignored', () => {
  const { event, pushed } = clickTitle(
    {
      context: { uri: 'spotify:playlist:abc' },
      item: { uid: 'row1', uri: 'spotify:track:t1' },
    },
    { target: new Element('.main-trackInfo-artists a') },
  );

  assert.deepEqual(pushed, []);
  assert.equal(event.defaultPrevented, false);
});
