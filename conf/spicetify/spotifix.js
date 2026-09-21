(function spotifix() {
  const playRoute =
    /^\/search\/spotifix-play-(library|180g|liked|playlist)-(sequential|shuffle|smart-shuffle)-/;
  const likedSongsUri = 'spotify:collection:tracks';

  if (!window.Spicetify || !Spicetify.Player?.playUri || !Spicetify.Platform?.History) {
    setTimeout(spotifix, 250);
    return;
  }

  let handlingRoute = false;
  let lastSafePath = null;

  function playlistsFrom(rows) {
    const playlists = [];

    function visit(items) {
      for (const item of items || []) {
        if (!item) continue;
        const uri = item.link || item.uri;
        if (item.type === 'playlist' && uri?.startsWith('spotify:playlist:')) {
          playlists.push({ name: item.name, uri });
        }
        visit(item.rows || item.items);
      }
    }

    visit(rows);
    return [...new Map(playlists.map((playlist) => [playlist.uri, playlist])).values()];
  }

  function playlistSources(playlists) {
    return [likedSongsUri, ...playlists.map((playlist) => playlist.uri)];
  }

  async function platformAPI(name, method) {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const api = Spicetify.Platform[name];
      if (typeof api?.[method] === 'function') return api;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Spotify ${name} is not ready`);
  }

  async function loadPlaylists() {
    const rootlistAPI = await platformAPI('RootlistAPI', 'getContents');
    const root = await rootlistAPI.getContents();
    return playlistsFrom(root?.items || root?.rows);
  }

  function randomItem(items) {
    return items[randomIndex(items.length)];
  }

  function randomIndex(length) {
    const value = new Uint32Array(1);
    const limit = Math.floor(0x100000000 / length) * length;
    do window.crypto.getRandomValues(value);
    while (value[0] >= limit);
    return value[0] % length;
  }

  function locationPath(location) {
    return `${location.pathname || '/'}${location.search || ''}${location.hash || ''}`;
  }

  function showContext(uri) {
    const path = Spicetify.URI.fromString(uri).toURLPath(true);
    lastSafePath = path;
    Spicetify.Platform.History.replace(path);
  }

  async function trackCount(uri) {
    if (uri === likedSongsUri) {
      const libraryAPI = await platformAPI('LibraryAPI', 'getTracks');
      const response = await libraryAPI.getTracks({ offset: 0, limit: 50000 });
      return response.items?.length;
    }

    const playlistAPI = await platformAPI('PlaylistAPI', 'getContents');
    const response = await playlistAPI.getContents(uri, { offset: 0, limit: 1 });
    return response.totalLength;
  }

  async function randomNonemptySource(sources) {
    const remaining = [...sources];

    while (remaining.length) {
      const uri = randomItem(remaining);
      remaining.splice(remaining.indexOf(uri), 1);
      const count = await trackCount(uri);
      if (!Number.isInteger(count) || count < 1) continue;
      return { count, uri };
    }

    throw new Error('No tracks found in the selected source');
  }

  async function selectPlayback(selector) {
    if (selector === 'liked') {
      const selected = await randomNonemptySource([likedSongsUri]);
      return { uri: selected.uri, index: randomIndex(selected.count) };
    }

    const playlists = await loadPlaylists();

    if (selector === 'playlist') {
      const selected = await randomNonemptySource(playlists.map((playlist) => playlist.uri));
      return { uri: selected.uri };
    }

    if (selector === '180g') {
      const playlist = playlists.find((item) => item.name?.toLowerCase() === '180g');
      if (!playlist) throw new Error('The 180g playlist was not found');

      const playlistAPI = await platformAPI('PlaylistAPI', 'getContents');
      const response = await playlistAPI.getContents(playlist.uri, { offset: 0, limit: 50000 });
      const albums = [
        ...new Set((response.items || []).map((item) => item.album?.uri).filter(Boolean)),
      ];
      if (!albums.length) throw new Error('No albums found in the 180g playlist');
      return { uri: randomItem(albums) };
    }

    const selected = await randomNonemptySource(playlistSources(playlists));
    return { uri: selected.uri, index: randomIndex(selected.count) };
  }

  async function setPlaybackMode(uri, mode) {
    if (mode === 'sequential') {
      Spicetify.Player.setShuffle(false);
      return;
    }

    if (mode === 'shuffle') {
      Spicetify.Player.setShuffle(true);
      return;
    }

    const contextualShuffle = Spicetify.Player.origin?._contextualShuffle;
    if (typeof contextualShuffle?.setContextualShuffleMode !== 'function') {
      throw new Error('Smart Shuffle is not available in this Spotify client');
    }
    await contextualShuffle.setContextualShuffleMode(uri, 2);
  }

  async function playSelection(selector, mode) {
    const selection = await selectPlayback(selector);
    Spicetify.Player.setShuffle(false);
    if (Number.isInteger(selection.index)) {
      await Spicetify.Player.playUri(selection.uri, {}, { skipTo: { index: selection.index } });
    } else {
      await Spicetify.Player.playUri(selection.uri);
    }
    await setPlaybackMode(selection.uri, mode);
    showContext(selection.uri);
  }

  async function handleRoute(location = Spicetify.Platform.History.location) {
    const pathname = location?.pathname;
    const route = pathname?.match(playRoute);
    if (!route) {
      if (!handlingRoute && pathname) lastSafePath = locationPath(location);
      return;
    }
    if (handlingRoute) return;

    handlingRoute = true;
    Spicetify.Platform.History.replace(lastSafePath || '/');
    try {
      await playSelection(route[1], route[2]);
    } catch (error) {
      console.error('[spotifix] Failed to select random playback', error);
      Spicetify.showNotification(`Spotifix: ${error.message}`, true);
    } finally {
      handlingRoute = false;
    }
  }

  Spicetify.Platform.History.listen(handleRoute);
  handleRoute();
})();
