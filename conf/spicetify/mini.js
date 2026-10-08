(function mini(attempt = 0) {
  const bridge = window.JshMiniBridge;
  if (!bridge) {
    if (!/mac/i.test(navigator.userAgentData?.platform || navigator.platform)) return;
    fetch('/extensions/mini-bridge.json', { cache: 'no-store' })
      .then((response) => {
        if (!response.ok) throw new Error('Companion not installed');
        return response.json();
      })
      .then((config) => {
        if (
          !/^[a-f0-9]{64}$/.test(config.token) ||
          !Number.isInteger(config.port) ||
          config.port < 1024 ||
          config.port > 65535
        )
          throw new Error('Invalid mini bridge configuration');
        window.JshMiniBridge = config;
        mini();
      })
      .catch(() => {
        // Allow startup/apply recovery, then stay quiet when the companion is not installed.
        if (attempt < 5) setTimeout(() => mini(attempt + 1), Math.min(5000 * 2 ** attempt, 30000));
      });
    return;
  }
  const api = window.JshMusic;
  if (!api?.like || !api.love || !api.add || !Spicetify.Player?.data) {
    setTimeout(mini, 250);
    return;
  }

  const results = new Map();
  let timer;
  let stopped = false;
  const namespace = () => Spicetify.Platform?.LocalStorageAPI?.namespace || '';

  function state() {
    const item = Spicetify.Player.data?.item;
    const meta = item?.metadata || {};
    const uri = item?.uri || '';
    const supported = uri.startsWith('spotify:track:') && !meta.is_advertisement;
    return {
      account: namespace(),
      uri,
      supported,
      title: item?.name || meta.title || 'Nothing playing',
      artist:
        item?.artists
          ?.map((artist) => artist.name)
          .filter(Boolean)
          .join(', ') ||
        Object.entries(meta)
          .filter(([key]) => /^artist_name(?:_\d+)?$/.test(key))
          .map(([, name]) => name)
          .join(', ') ||
        'Artist unavailable',
      album: item?.album?.name || meta.album_title || 'Album unavailable',
      image: (
        meta.image_xlarge_url ||
        meta.image_large_url ||
        meta.image_url ||
        item?.album?.images?.[0]?.url ||
        ''
      ).replace('spotify:image:', 'https://i.scdn.co/image/'),
      liked: supported ? (api.like.state(uri) ?? null) : null,
      loved: supported ? (api.love.state(uri) ?? null) : null,
      removal: api.add.removalState(),
    };
  }

  async function execute(command) {
    if (!command || typeof command.id !== 'string' || results.has(command.id)) return;
    results.set(command.id, null); // Reserve before awaiting: repeated deliveries cannot mutate twice.
    let result;
    try {
      const validate = () => {
        if (!Number.isFinite(command.expires) || Date.now() > command.expires)
          throw new Error('Shortcut expired; try again');
        if (!namespace() || command.account !== namespace())
          throw new Error('Spotify account changed');
        if (command.uri !== Spicetify.Player.data?.item?.uri)
          throw new Error('Track changed; try again');
      };
      validate();
      if (command.value !== undefined && typeof command.value !== 'boolean')
        throw new Error('Invalid curation state');
      if (command.action === 'like')
        result = await api.like.toggle(command.uri, command.value, validate);
      else if (command.action === 'love')
        result = await api.love.toggle(command.uri, command.value, validate);
      else if (command.action === 'add') {
        api.add.toggle();
        result = { ok: true, message: '' };
      } else if (['remove', 'undo'].includes(command.action)) {
        const current = api.add.removalState();
        if (
          !current.enabled ||
          current.action !== command.action ||
          ['context', 'itemUid', 'provider', 'id'].some(
            (key) => current[key] !== command.removal?.[key],
          )
        )
          throw new Error('Playing playlist or Remove/Undo state changed');
        result = await api.add.changePlayingPlaylist(command.action, command.removal);
      } else throw new Error('Unknown mini player action');
    } catch (error) {
      result = { ok: false, message: error.message || 'Could not complete action' };
    }
    results.set(command.id, { id: command.id, ...result });
    if (results.size > 128) {
      const completed = [...results].find(([, value]) => value);
      if (completed) results.delete(completed[0]);
    }
  }

  async function sync() {
    try {
      const response = await fetch(`http://127.0.0.1:${bridge.port}/sync`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${bridge.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ state: state(), results: [...results.values()].filter(Boolean) }),
        signal: AbortSignal.timeout(3000),
      });
      if (!response.ok) throw new Error(`Companion returned ${response.status}`);
      const data = await response.json();
      for (const command of data.commands || []) execute(command);
    } catch {
      // Companion may be stopped; do not notify or restart Spotify on connection failures.
    } finally {
      if (!stopped) timer = setTimeout(sync, 750);
    }
  }

  api.mini = { state, execute };
  window.addEventListener(
    'pagehide',
    () => {
      stopped = true;
      clearTimeout(timer);
    },
    { once: true },
  );
  sync();
})();
