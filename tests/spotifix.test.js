const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'conf', 'spicetify', 'spotifix.js'),
  'utf8',
);

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
    crypto: {
      getRandomValues(value) {
        value[0] = randomValues.shift();
        return value;
      },
    },
  };

  vm.runInNewContext(source, { console, Spicetify, Uint32Array, window });
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
