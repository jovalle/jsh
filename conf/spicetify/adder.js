(function adder() {
  if (!window.Spicetify?.Player || !Spicetify.ContextMenu) {
    setTimeout(adder, 250);
    return;
  }

  const OVERLAY_ID = 'adder';
  const RESULT_LIMIT = 100;
  let activeOverlay = null;

  function normalize(value) {
    return value.normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase();
  }

  function fuzzyScore(query, value) {
    if (!query) return 0;

    const exactIndex = value.indexOf(query);
    if (exactIndex !== -1) return exactIndex;

    let queryIndex = 0;
    let previousMatch = -1;
    let score = 100;

    for (
      let valueIndex = 0;
      valueIndex < value.length && queryIndex < query.length;
      valueIndex += 1
    ) {
      if (value[valueIndex] !== query[queryIndex]) continue;

      const gap = previousMatch === -1 ? valueIndex : valueIndex - previousMatch - 1;
      const wordStart = valueIndex === 0 || /[\s_\-/.]/.test(value[valueIndex - 1]);
      score += gap - (wordStart ? 2 : 0);
      previousMatch = valueIndex;
      queryIndex += 1;
    }

    return queryIndex === query.length ? score : Number.POSITIVE_INFINITY;
  }

  function isTrack(uri) {
    if (typeof uri !== 'string') return false;
    if (uri.startsWith('spotify:track:')) return true;

    try {
      const parsed = Spicetify.URI?.fromString?.(uri);
      const trackType = Spicetify.URI?.Type?.TRACK;
      return Boolean(trackType && parsed?.type === trackType);
    } catch {
      return false;
    }
  }

  function isAlbum(uri) {
    if (typeof uri !== 'string') return false;
    if (uri.startsWith('spotify:album:')) return true;

    try {
      const parsed = Spicetify.URI?.fromString?.(uri);
      const albumType = Spicetify.URI?.Type?.ALBUM;
      return Boolean(albumType && parsed?.type === albumType);
    } catch {
      return false;
    }
  }

  function isSupportedTarget(uri) {
    return isTrack(uri) || isAlbum(uri);
  }

  function getCurationAPI() {
    return Object.values(Spicetify.Platform).find(
      (api) =>
        api &&
        typeof api.getCurationContexts === 'function' &&
        typeof api.curateItems === 'function',
    );
  }

  function uniquePlaylists(playlists) {
    return playlists.filter(
      (playlist, index, all) =>
        playlist.uri.startsWith('spotify:playlist:') &&
        all.findIndex(({ uri }) => uri === playlist.uri) === index,
    );
  }

  async function loadWithCurationAPI(itemUri, curationAPI) {
    const response = await curationAPI.getCurationContexts({
      curatedItemUri: itemUri,
      flatten: true,
      limit: 1000,
      offset: 0,
    });

    return uniquePlaylists(
      (response.items || [])
        .filter((item) => item?.uri && item.name)
        .map((item) => ({
          count: Number.isFinite(item.trackCount) ? item.trackCount : item.totalLength,
          folder: item.fromFolder?.name,
          image: item.images?.[0]?.url,
          name: item.name,
          saved: Boolean(item.hasCuratedItems),
          uri: item.uri,
        })),
    );
  }

  async function loadWithCosmos() {
    const root = await Spicetify.CosmosAsync.get('sp://core-playlist/v1/rootlist');
    const playlists = [];

    function visit(rows) {
      for (const row of rows || []) {
        const uri = row.link || row.uri;
        if (row.type === 'playlist' && uri && row.name) {
          playlists.push({
            count: Number.isFinite(row.total_length) ? row.total_length : undefined,
            folder: undefined,
            image: undefined,
            name: row.name,
            saved: false,
            uri,
          });
        }
        visit(row.rows);
      }
    }

    visit(root.rows);
    return uniquePlaylists(playlists);
  }

  async function loadPlaylists(itemUri) {
    const curationAPI = getCurationAPI();
    if (curationAPI) {
      try {
        return {
          curationAPI,
          playlists: await loadWithCurationAPI(itemUri, curationAPI),
        };
      } catch {
        // Fall through to the documented Cosmos rootlist endpoint.
      }
    }

    return {
      curationAPI: null,
      playlists: await loadWithCosmos(),
    };
  }

  async function albumTrackUris(albumUri) {
    const albumId = albumUri.split(':')[2];
    const trackUris = [];
    let endpoint = `https://api.spotify.com/v1/albums/${albumId}/tracks?limit=50`;
    while (endpoint) {
      const page = await Spicetify.CosmosAsync.get(endpoint);
      trackUris.push(...(page.items || []).map(({ uri }) => uri).filter(isTrack));
      endpoint = page.next;
    }
    return trackUris;
  }

  async function updatePlaylist(playlist, itemUri, curationAPI) {
    const remove = playlist.saved;

    if (curationAPI) {
      await curationAPI.curateItems(
        itemUri,
        remove ? [] : [playlist.uri],
        remove ? [playlist.uri] : [],
      );
      return;
    }

    const playlistId = playlist.uri.split(':')[2];
    const endpoint = `https://api.spotify.com/v1/playlists/${playlistId}/items`;
    const itemUris = isAlbum(itemUri) ? await albumTrackUris(itemUri) : [itemUri];
    for (let index = 0; index < itemUris.length; index += 100) {
      const batch = itemUris.slice(index, index + 100);
      if (remove) {
        await Spicetify.CosmosAsync.del(endpoint, {
          items: batch.map((uri) => ({ uri })),
        });
      } else {
        await Spicetify.CosmosAsync.post(endpoint, { uris: batch });
      }
    }
  }

  function spotifyPath(uri) {
    if (!uri) return null;
    try {
      return Spicetify.URI.fromString(uri).toURLPath(true);
    } catch {
      return null;
    }
  }

  function artworkUrl(item) {
    const url =
      item.album?.images?.[0]?.url ||
      item.images?.[0]?.url ||
      item.metadata?.image_xlarge_url ||
      item.metadata?.image_url;
    return url?.replace('spotify:image:', 'https://i.scdn.co/image/');
  }

  function metadataYear(item) {
    const releaseDate =
      item.metadata?.album_release_date ||
      item.metadata?.release_date ||
      item.metadata?.['album.release_date'];
    return /^\d{4}/.test(releaseDate || '') ? releaseDate.slice(0, 4) : '';
  }

  async function loadReleaseYear(trackUri) {
    const trackId = trackUri.split(':')[2];
    if (!trackId) return '';
    const track = await Spicetify.CosmosAsync.get(`https://api.spotify.com/v1/tracks/${trackId}`);
    return /^\d{4}/.test(track.album?.release_date || '')
      ? track.album.release_date.slice(0, 4)
      : '';
  }

  function createOverlay(itemUri, item = Spicetify.Player.data.item, followPlayer = true) {
    if (activeOverlay?.root.isConnected) activeOverlay.close();
    let currentItemUri = itemUri;
    let playlistLoadId = 0;
    const root = document.createElement('div');
    root.id = OVERLAY_ID;
    root.innerHTML = `
      <style>
        #${OVERLAY_ID} { align-items: center; background: rgb(0 0 0 / 72%); box-sizing: border-box; color: var(--spice-text); display: flex; inset: 0; justify-content: center; padding: 24px; position: fixed; z-index: 1000; }
        #${OVERLAY_ID} * { box-sizing: border-box; }
        #${OVERLAY_ID} .panel { background: var(--spice-main); border: 1px solid rgb(255 255 255 / 8%); border-radius: 8px; box-shadow: 0 20px 64px rgb(0 0 0 / 55%); display: grid; grid-template-rows: auto auto minmax(0, 1fr); height: min(620px, calc(100vh - 48px)); min-height: 300px; overflow: hidden; width: min(560px, 100%); }
        #${OVERLAY_ID} .header { align-items: center; background: var(--spice-card); border-radius: 6px; display: grid; gap: 16px; grid-template-columns: 112px minmax(0, 1fr); height: 136px; margin: 16px; padding: 12px; }
        #${OVERLAY_ID} .artwork-link { border-radius: 4px; display: block; height: 112px; overflow: hidden; width: 112px; }
        #${OVERLAY_ID} .artwork { background: var(--spice-main); display: block; height: 100%; object-fit: cover; width: 100%; }
        #${OVERLAY_ID} .artwork-fallback { align-items: center; color: var(--spice-subtext); display: flex; justify-content: center; }
        #${OVERLAY_ID} .artwork-fallback svg { height: 34px; width: 34px; }
        #${OVERLAY_ID} .track-info { min-width: 0; }
        #${OVERLAY_ID} .track-title { color: var(--spice-text); display: block; font-size: 22px; font-weight: 700; line-height: 27px; margin-bottom: 7px; overflow: hidden; text-decoration: none; text-overflow: ellipsis; white-space: nowrap; }
        #${OVERLAY_ID} .artists { color: var(--spice-subtext); font-size: 14px; font-weight: 600; line-height: 20px; margin-bottom: 5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        #${OVERLAY_ID} .release { color: var(--spice-subtext); font-size: 12px; line-height: 18px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        #${OVERLAY_ID} .metadata-link { color: inherit; text-decoration: none; }
        #${OVERLAY_ID} .track-title:hover, #${OVERLAY_ID} .metadata-link:hover { text-decoration: underline; }
        #${OVERLAY_ID} .search { margin: 0 16px 12px; position: relative; }
        #${OVERLAY_ID} .search svg { color: var(--spice-subtext); height: 18px; left: 14px; pointer-events: none; position: absolute; top: 50%; transform: translateY(-50%); width: 18px; }
        #${OVERLAY_ID} input { background: var(--spice-card); border: 1px solid transparent; border-radius: 6px; color: inherit; font: inherit; font-size: 16px; min-height: 44px; outline: none; padding: 10px 14px 10px 42px; transition: border-color 120ms ease, box-shadow 120ms ease; width: 100%; }
        #${OVERLAY_ID} input::placeholder { color: var(--spice-subtext); opacity: 1; }
        #${OVERLAY_ID} input:focus-visible { border-color: var(--spice-button); box-shadow: inset 0 0 0 1px var(--spice-button); }
        #${OVERLAY_ID} [role="listbox"] { min-height: 0; overflow: auto; padding: 0 8px 8px; scroll-padding: 4px; scrollbar-gutter: stable; }
        #${OVERLAY_ID} [role="option"] { align-items: center; border-radius: 6px; cursor: pointer; display: grid; gap: 10px; grid-template-columns: 40px minmax(0, 1fr) 28px; min-height: 52px; padding: 6px 8px; transition: background-color 100ms ease; }
        #${OVERLAY_ID} [role="option"]:hover, #${OVERLAY_ID} [role="option"].active { background: var(--spice-card); }
        #${OVERLAY_ID} [role="option"].busy { opacity: 0.7; }
        #${OVERLAY_ID} [role="option"] img, #${OVERLAY_ID} [role="option"] .cover { align-items: center; background: var(--spice-card); border-radius: 4px; display: flex; height: 40px; justify-content: center; object-fit: cover; width: 40px; }
        #${OVERLAY_ID} .cover svg { color: var(--spice-subtext); height: 18px; width: 18px; }
        #${OVERLAY_ID} .details { min-width: 0; }
        #${OVERLAY_ID} .name { font-size: 14px; font-weight: 600; line-height: 20px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        #${OVERLAY_ID} .meta { color: var(--spice-subtext); font-size: 12px; line-height: 18px; }
        #${OVERLAY_ID} .status { align-items: center; border: 1px solid var(--spice-subtext); border-radius: 50%; color: transparent; display: flex; height: 18px; justify-content: center; width: 18px; }
        #${OVERLAY_ID} .status svg { height: 12px; width: 12px; }
        #${OVERLAY_ID} .status.saved { background: #1ed760; border-color: #1ed760; color: #000; }
        #${OVERLAY_ID} .status.busy { animation: adder-spin 700ms linear infinite; border-color: var(--spice-subtext); border-top-color: #1ed760; }
        #${OVERLAY_ID} .empty { color: var(--spice-subtext); padding: 40px 16px; text-align: center; }
        #${OVERLAY_ID} .sr-only { clip: rect(0, 0, 0, 0); clip-path: inset(50%); height: 1px; overflow: hidden; position: absolute; white-space: nowrap; width: 1px; }
        @keyframes adder-spin { to { transform: rotate(360deg); } }
        @media (max-width: 480px) { #${OVERLAY_ID} { padding: 12px; } #${OVERLAY_ID} .panel { height: min(620px, calc(100vh - 24px)); } #${OVERLAY_ID} .header { gap: 12px; grid-template-columns: 88px minmax(0, 1fr); height: 112px; margin: 12px; padding: 12px; } #${OVERLAY_ID} .artwork-link { height: 88px; width: 88px; } #${OVERLAY_ID} .track-title { font-size: 19px; line-height: 24px; } }
        @media (prefers-reduced-motion: reduce) { #${OVERLAY_ID} * { scroll-behavior: auto !important; transition: none !important; } #${OVERLAY_ID} .status.busy { animation: none; } }
      </style>
    `;

    const panel = document.createElement('section');
    panel.className = 'panel';
    panel.setAttribute('aria-label', `Add ${isAlbum(itemUri) ? 'album' : 'track'} to playlists`);
    panel.setAttribute('aria-modal', 'true');
    panel.setAttribute('role', 'dialog');

    const header = document.createElement('header');
    header.className = 'header';

    function createSpotifyLink(label, uri, className) {
      const path = spotifyPath(uri);
      const element = document.createElement(path ? 'a' : 'span');
      element.className = className;
      element.textContent = label;
      if (path) {
        element.href = path;
        element.addEventListener('click', (event) => {
          event.preventDefault();
          close();
          Spicetify.Platform.History.push(path);
        });
      }
      return element;
    }

    function renderItemCard(targetItem) {
      const renderedItemUri = targetItem.uri;
      const album = isAlbum(renderedItemUri);
      const albumUri = album
        ? renderedItemUri
        : targetItem.album?.uri || targetItem.metadata?.album_uri;
      const artworkLink = createSpotifyLink('', albumUri, 'artwork-link');
      artworkLink.setAttribute(
        'aria-label',
        `Open ${
          targetItem.album?.name || targetItem.metadata?.album_title || targetItem.name || 'album'
        }`,
      );
      const imageUrl = artworkUrl(targetItem);
      if (imageUrl) {
        const artwork = document.createElement('img');
        artwork.className = 'artwork';
        artwork.alt = '';
        artwork.src = imageUrl;
        artworkLink.append(artwork);
      } else {
        const artwork = document.createElement('span');
        artwork.className = 'artwork artwork-fallback';
        artwork.innerHTML =
          '<svg aria-hidden="true" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>';
        artworkLink.append(artwork);
      }

      const itemInfo = document.createElement('div');
      itemInfo.className = 'track-info';
      const trackTitle = createSpotifyLink(
        targetItem.name || `Current ${album ? 'album' : 'track'}`,
        targetItem.uri,
        'track-title',
      );
      trackTitle.title = targetItem.name || `Current ${album ? 'album' : 'track'}`;

      const artists = document.createElement('div');
      artists.className = 'artists';
      const creditedArtists = targetItem.artists?.length
        ? targetItem.artists
        : [
            {
              name: targetItem.metadata?.artist_name || 'Unknown artist',
              uri: targetItem.metadata?.artist_uri,
            },
          ];
      creditedArtists.forEach((artist, index) => {
        if (index) artists.append(document.createTextNode(', '));
        artists.append(createSpotifyLink(artist.name, artist.uri, 'metadata-link'));
      });

      const release = document.createElement('div');
      release.className = 'release';
      const albumName =
        targetItem.album?.name || targetItem.metadata?.album_title || 'Unknown album';
      if (album) {
        release.append(document.createTextNode('Album'));
      } else {
        release.append(createSpotifyLink(albumName, albumUri, 'metadata-link'));
      }
      const year = document.createElement('span');
      const initialYear = metadataYear(targetItem);
      if (initialYear) {
        year.textContent = ` · ${initialYear}`;
        release.append(year);
      } else if (!album) {
        loadReleaseYear(renderedItemUri)
          .then((loadedYear) => {
            if (!loadedYear || currentItemUri !== renderedItemUri || !release.isConnected) return;
            year.textContent = ` · ${loadedYear}`;
            release.append(year);
          })
          .catch(() => {});
      }
      itemInfo.append(trackTitle, artists, release);
      header.replaceChildren(artworkLink, itemInfo);
    }

    renderItemCard(item);

    const search = document.createElement('div');
    search.className = 'search';
    search.innerHTML =
      '<svg aria-hidden="true" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"></circle><path d="m21 21-4.35-4.35"></path></svg>';
    const input = document.createElement('input');
    input.type = 'search';
    input.placeholder = 'Find a playlist';
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.setAttribute('aria-autocomplete', 'list');
    input.setAttribute('aria-controls', `${OVERLAY_ID}-results`);
    input.setAttribute('aria-expanded', 'true');
    input.setAttribute('aria-label', 'Find a playlist');
    input.setAttribute('role', 'combobox');
    search.append(input);

    const list = document.createElement('div');
    list.id = `${OVERLAY_ID}-results`;
    list.setAttribute('aria-label', 'Playlists');
    list.setAttribute('aria-multiselectable', 'true');
    list.setAttribute('role', 'listbox');
    const live = document.createElement('div');
    live.className = 'sr-only';
    live.setAttribute('aria-live', 'polite');
    live.setAttribute('role', 'status');
    panel.append(header, search, list, live);
    root.append(panel);
    document.body.append(root);

    let allPlaylists = [];
    let curationAPI = null;
    let selectedIndex = 0;
    let visiblePlaylists = [];

    function close() {
      playlistLoadId += 1;
      window.removeEventListener('keydown', onKeyDown, true);
      if (followPlayer) Spicetify.Player.removeEventListener('songchange', onSongChange);
      root.remove();
      activeOverlay = null;
    }

    function updateActive(scroll = false) {
      [...list.querySelectorAll('[role="option"]')].forEach((row, index) => {
        row.classList.toggle('active', index === selectedIndex);
      });

      const row = list.querySelectorAll('[role="option"]')[selectedIndex];
      if (!row) {
        input.removeAttribute('aria-activedescendant');
        return;
      }

      input.setAttribute('aria-activedescendant', row.id);
      if (scroll) row.scrollIntoView({ block: 'nearest' });
    }

    function updateRow(playlist) {
      if (!playlist.row?.isConnected) return;
      const status = playlist.row.querySelector('.status');
      status.className = `status${playlist.busy ? ' busy' : playlist.saved ? ' saved' : ''}`;
      status.innerHTML =
        playlist.saved && !playlist.busy
          ? '<svg aria-hidden="true" fill="none" viewBox="0 0 16 16" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.25"><path d="m3.5 8.2 2.8 2.8 6.2-6.2"></path></svg>'
          : '';
      playlist.row.classList.toggle('busy', playlist.busy);
      playlist.row.setAttribute('aria-disabled', String(playlist.busy));
      playlist.row.setAttribute(
        'aria-label',
        `${playlist.name}, ${playlist.saved ? 'saved' : 'not saved'}`,
      );
      playlist.row.setAttribute('aria-selected', String(playlist.saved));
    }

    async function togglePlaylist(playlist) {
      if (!playlist || playlist.busy) return;

      const targetItemUri = currentItemUri;
      const wasSaved = playlist.saved;
      playlist.busy = true;
      updateRow(playlist);
      try {
        await updatePlaylist(playlist, targetItemUri, curationAPI);
        if (currentItemUri !== targetItemUri) return;
        playlist.saved = !wasSaved;
        const message = `${playlist.saved ? 'Saved to' : 'Removed from'} ${playlist.name}`;
        live.textContent = message;
        Spicetify.showNotification(message);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        live.textContent = `Could not update ${playlist.name}. ${message}`;
        Spicetify.showNotification(`Could not update ${playlist.name}`, true);
      } finally {
        playlist.busy = false;
        updateRow(playlist);
      }
    }

    function render() {
      list.replaceChildren();
      for (const playlist of allPlaylists) playlist.row = null;

      if (!visiblePlaylists.length) {
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = allPlaylists.length ? 'No matching playlists' : 'No playlists found';
        list.append(empty);
        input.removeAttribute('aria-activedescendant');
        return;
      }

      visiblePlaylists.forEach((playlist, index) => {
        const row = document.createElement('div');
        row.id = `${OVERLAY_ID}-playlist-${index}`;
        row.setAttribute('role', 'option');
        row.tabIndex = -1;

        const cover = playlist.image
          ? document.createElement('img')
          : document.createElement('span');
        if (playlist.image) {
          cover.alt = '';
          cover.src = playlist.image;
        } else {
          cover.className = 'cover';
          cover.innerHTML =
            '<svg aria-hidden="true" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>';
        }

        const details = document.createElement('span');
        details.className = 'details';
        const name = document.createElement('div');
        name.className = 'name';
        name.textContent = playlist.name;
        name.title = playlist.name;
        const meta = document.createElement('div');
        meta.className = 'meta';
        meta.textContent =
          [
            playlist.folder,
            Number.isFinite(playlist.count) ? `${playlist.count.toLocaleString()} songs` : null,
          ]
            .filter(Boolean)
            .join(' / ') || 'Playlist';
        details.append(name, meta);

        const status = document.createElement('span');
        status.className = 'status';
        status.setAttribute('aria-hidden', 'true');
        row.append(cover, details, status);
        row.addEventListener('mouseenter', () => {
          selectedIndex = visiblePlaylists.indexOf(playlist);
          updateActive();
        });
        row.addEventListener('mousedown', (event) => event.preventDefault());
        row.addEventListener('click', () => togglePlaylist(playlist));
        playlist.row = row;
        list.append(row);
        updateRow(playlist);
      });

      updateActive();
    }

    function filterPlaylists() {
      const query = normalize(input.value.trim());
      visiblePlaylists = allPlaylists
        .map((playlist) => ({ playlist, score: fuzzyScore(query, normalize(playlist.name)) }))
        .filter(({ score }) => Number.isFinite(score))
        .sort(
          (left, right) =>
            left.score - right.score ||
            Number(right.playlist.saved) - Number(left.playlist.saved) ||
            left.playlist.name.localeCompare(right.playlist.name),
        )
        .slice(0, RESULT_LIMIT)
        .map(({ playlist }) => playlist);
      selectedIndex = 0;
      render();
      live.textContent = `${visiblePlaylists.length} matching ${
        visiblePlaylists.length === 1 ? 'playlist' : 'playlists'
      }`;
    }

    async function refreshPlaylists() {
      const loadId = ++playlistLoadId;
      const loading = document.createElement('div');
      loading.className = 'empty';
      loading.textContent = 'Loading playlists...';
      list.replaceChildren(loading);
      input.removeAttribute('aria-activedescendant');

      try {
        const result = await loadPlaylists(currentItemUri);
        if (!root.isConnected || loadId !== playlistLoadId) return;
        curationAPI = result.curationAPI;
        allPlaylists = result.playlists;
        filterPlaylists();
      } catch (error) {
        if (!root.isConnected || loadId !== playlistLoadId) return;
        const message = error instanceof Error ? error.message : String(error);
        list.replaceChildren();
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = 'Could not load playlists. Try again.';
        list.append(empty);
        live.textContent = `Could not load playlists. ${message}`;
        Spicetify.showNotification('Could not load playlists', true);
      }
    }

    function onSongChange(event) {
      const nextItem = event?.data?.item || Spicetify.Player.data?.item;
      if (!isTrack(nextItem?.uri) || nextItem.uri === currentItemUri) return;
      currentItemUri = nextItem.uri;
      renderItemCard(nextItem);
      refreshPlaylists();
    }

    function onKeyDown(event) {
      if (event.key === 'Escape') {
        event.preventDefault();
        close();
        return;
      }
      if (!root.isConnected || !visiblePlaylists.length) return;

      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        selectedIndex =
          (selectedIndex + (event.key === 'ArrowDown' ? 1 : -1) + visiblePlaylists.length) %
          visiblePlaylists.length;
        updateActive(true);
      } else if (event.key === 'Enter' || event.code === 'Space') {
        event.preventDefault();
        togglePlaylist(visiblePlaylists[selectedIndex]);
      } else if (
        document.activeElement !== input &&
        !event.isComposing &&
        !event.metaKey &&
        !event.ctrlKey &&
        !event.altKey &&
        (event.key.length === 1 || event.key === 'Backspace' || event.key === 'Delete')
      ) {
        input.focus();
      }
    }

    input.addEventListener('input', filterPlaylists);
    root.addEventListener('mousedown', (event) => {
      if (event.target === root) close();
    });
    window.addEventListener('keydown', onKeyDown, true);
    if (followPlayer) Spicetify.Player.addEventListener('songchange', onSongChange);
    activeOverlay = { close, root };

    requestAnimationFrame(() => input.focus());
    refreshPlaylists();
  }

  function toggleOverlay() {
    if (activeOverlay?.root.isConnected) {
      activeOverlay.close();
      return;
    }

    const trackUri = Spicetify.Player.data?.item?.uri;
    if (!isTrack(trackUri)) {
      Spicetify.showNotification('Play a track before opening Adder', true);
      return;
    }

    createOverlay(trackUri);
  }

  async function openContextOverlay(uris) {
    const targetUri = uris?.find(isSupportedTarget);
    if (!targetUri) return;

    const playerItem = Spicetify.Player.data?.item;
    if (playerItem?.uri === targetUri) {
      createOverlay(targetUri, playerItem, false);
      return;
    }

    const itemType = isAlbum(targetUri) ? 'album' : 'track';
    const itemId = targetUri.split(':')[2];
    try {
      let item;
      if (itemType === 'album') {
        const response = await Spicetify.GraphQL.Request(Spicetify.GraphQL.Definitions.getAlbum, {
          uri: targetUri,
          locale: Spicetify.Locale.getLocale(),
          offset: 0,
          limit: 1,
        });
        const album = response.data?.albumUnion;
        item = {
          artists: (album?.artists?.items || []).map((artist) => ({
            name: artist.profile?.name,
            uri: artist.uri,
          })),
          images: album?.coverArt?.sources,
          metadata: { release_date: album?.date?.isoString },
          name: album?.name,
          uri: album?.uri || targetUri,
        };
      } else {
        item = await Spicetify.CosmosAsync.get(`https://api.spotify.com/v1/tracks/${itemId}`);
      }
      createOverlay(targetUri, item, false);
    } catch {
      Spicetify.showNotification(`Could not load ${itemType}`, true);
    }
  }

  function contextUriFromTarget(target) {
    let element = target instanceof Element ? target : target?.parentElement;
    while (element) {
      const fiberKey = Object.getOwnPropertyNames(element).find((key) =>
        key.startsWith('__reactFiber$'),
      );
      let fiber = fiberKey ? element[fiberKey] : null;
      for (let level = 0; fiber && level < 30; level += 1, fiber = fiber.return) {
        const props = fiber.memoizedProps;
        const candidates = [
          props?.item?.uri,
          props?.track?.uri,
          props?.data?.item?.uri,
          props?.data?.uri,
          props?.entity?.uri,
          props?.uri,
          ...(Array.isArray(props?.uris) ? props.uris : []),
        ];
        const uri = candidates.find(isSupportedTarget);
        if (uri) return uri;
      }
      element = element.parentElement;
    }
    return null;
  }

  function injectContextItem(targetUri) {
    const nativeLabel = Spicetify.Locale?.get?.('contextmenu.add-to-playlist') || 'Add to playlist';
    const nativeItem = [...document.querySelectorAll('[role="menuitem"]')].find(
      (item) => item.getClientRects().length && item.textContent.trim().startsWith(nativeLabel),
    );
    const menu = nativeItem?.closest('[role="menu"]');
    if (!nativeItem || !menu || menu.querySelector('[data-jsh-adder-context-item]')) return false;

    const wrapper = nativeItem.parentElement?.cloneNode(true);
    const button = wrapper?.querySelector('[role="menuitem"]');
    if (!wrapper || !button) return false;

    button.dataset.jshAdderContextItem = '';
    button.removeAttribute('aria-expanded');
    const icon = button.querySelector('svg.e-10451-icon:not(.main-contextMenu-subMenuIcon)');
    if (icon) {
      icon.style.removeProperty('--encore-icon-fill');
      icon.removeAttribute('stroke');
      icon.removeAttribute('stroke-linecap');
      icon.removeAttribute('stroke-linejoin');
      icon.removeAttribute('stroke-width');
      icon.setAttribute('fill', 'currentColor');
      icon.setAttribute('viewBox', '0 0 16 16');
      icon.innerHTML =
        '<path d="M11.25 5.75a.75.75 0 0 1-.75.75H6.5v4a.75.75 0 0 1-1.5 0V6.5H1a.75.75 0 0 1 0-1.5h4V1a.75.75 0 0 1 1.5 0v4h4a.75.75 0 0 1 .75.75zM15.75 12.25a.75.75 0 0 1-.75.75H13v2a.75.75 0 0 1-1.5 0v-2H9.5a.75.75 0 0 1 0-1.5h2V9.5a.75.75 0 0 1 1.5 0v2h2a.75.75 0 0 1 .75.75z"></path>';
    }
    button.querySelector('.main-contextMenu-menuItemIconWrapper')?.remove();
    const label = button.querySelector('[data-encore-id="type"]');
    if (label) {
      label.textContent = 'Add to playlists';
    } else {
      button.textContent = 'Add to playlists';
    }
    button.addEventListener('click', (event) => {
      event.preventDefault();
      openContextOverlay([targetUri]).then(() => {
        const input = document.querySelector(`#${OVERLAY_ID} input`);
        if (!input) return;
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          input.dispatchEvent(
            new PointerEvent(type, {
              bubbles: true,
              composed: true,
              pointerId: 1,
              pointerType: 'mouse',
            }),
          );
        }
      });
    });
    nativeItem.parentElement.insertAdjacentElement('afterend', wrapper);
    return true;
  }

  let contextMenuObserver = null;
  document.addEventListener(
    'contextmenu',
    (event) => {
      const targetUri = contextUriFromTarget(event.target);
      contextMenuObserver?.disconnect();
      if (!targetUri) return;

      contextMenuObserver = new MutationObserver(() => {
        if (injectContextItem(targetUri)) contextMenuObserver.disconnect();
      });
      contextMenuObserver.observe(document.body, { childList: true, subtree: true });
      requestAnimationFrame(() => injectContextItem(targetUri));
      setTimeout(() => contextMenuObserver?.disconnect(), 2000);
    },
    true,
  );

  const isMac = /Mac|iPhone|iPad/.test(navigator.userAgentData?.platform || navigator.platform);
  const shortcut = { key: 'p', meta: isMac, ctrl: !isMac, shift: true };
  const handledEvents = new WeakSet();
  const handleShortcut = (event) => {
    if (handledEvents.has(event)) return;
    const key = event.key?.toLocaleLowerCase();
    const modifier = event.metaKey || event.ctrlKey;
    if (key !== 'p' || !event.shiftKey || !modifier || event.altKey) return;

    handledEvents.add(event);
    event.preventDefault();
    event.stopPropagation();
    toggleOverlay();
  };

  // Keep Spicetify's shortcut registration for compatibility with its keymap,
  // and also listen at the window level for current desktop Spotify builds
  // where Mousetrap may not receive modified key events.
  try {
    Spicetify.Keyboard?.registerShortcut(shortcut, handleShortcut);
    if (isMac) {
      Spicetify.Keyboard?.registerShortcut({ key: 'p', ctrl: true, shift: true }, handleShortcut);
    }
  } catch {
    // The native listener below remains the portable fallback.
  }
  window.addEventListener('keydown', handleShortcut, true);
})();
