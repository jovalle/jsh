(function spotifix() {
  const routePrefix = '/search/spotifix-random-playlist-';

  if (
    !window.Spicetify?.CosmosAsync ||
    !Spicetify.Player?.playUri ||
    !Spicetify.Platform?.History
  ) {
    setTimeout(spotifix, 250);
    return;
  }

  let handlingRoute = false;

  function playlistUris(rows) {
    const uris = [];

    function visit(items) {
      for (const item of items || []) {
        const uri = item.link || item.uri;
        if (item.type === 'playlist' && uri?.startsWith('spotify:playlist:')) uris.push(uri);
        visit(item.rows);
      }
    }

    visit(rows);
    return [...new Set(uris)];
  }

  function randomItem(items) {
    const value = new Uint32Array(1);
    window.crypto.getRandomValues(value);
    return items[value[0] % items.length];
  }

  async function playRandomPlaylist() {
    const root = await Spicetify.CosmosAsync.get('sp://core-playlist/v1/rootlist');
    const playlists = playlistUris(root.rows);
    if (!playlists.length) throw new Error('No saved playlists found');

    const uri = randomItem(playlists);
    Spicetify.Player.setShuffle(true);
    await Spicetify.Player.playUri(uri);
    const path = Spicetify.URI.fromString(uri).toURLPath(true);
    Spicetify.Platform.History.replace(path);
  }

  async function handleRoute(location = Spicetify.Platform.History.location) {
    if (handlingRoute || !location?.pathname?.startsWith(routePrefix)) return;
    handlingRoute = true;
    try {
      await playRandomPlaylist();
    } catch (error) {
      console.error('[spotifix] Failed to play a random playlist', error);
      Spicetify.showNotification(`Spotifix: ${error.message}`, true);
    } finally {
      handlingRoute = false;
    }
  }

  Spicetify.Platform.History.listen(handleRoute);
  handleRoute();
})();
