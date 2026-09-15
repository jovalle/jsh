(function applyJshSpotifySettings() {
  const settings = window.Spicetify?.Platform?.SettingsAPI;
  if (!settings?.quality || !settings?.playback || !settings?.viewportZoom) {
    setTimeout(applyJshSpotifySettings, 100);
    return;
  }

  const desiredSettings = [
    [settings.quality.streamingQuality, 5],
    [settings.quality.downloadAudioQuality, 5],
    [settings.quality.autoAdjustQuality, false],
    [settings.quality.normalizeVolume, true],
    [settings.quality.volumeLevel, 1],
    [settings.playback.audioCrossfade, true],
    [settings.playback.audioCrossfadeMs, 3000],
    [settings.viewportZoom, -122],
  ];

  Promise.all(
    desiredSettings.map(async ([setting, desiredValue]) => {
      if ((await setting.getValue()) !== desiredValue) await setting.setValue(desiredValue);
    }),
  ).catch((error) => console.error('[jsh-settings] Failed to apply Spotify settings', error));

  for (const key of Object.keys(localStorage).filter((key) => key.endsWith(':items-view'))) {
    if (localStorage.getItem(key) === '2') continue;
    localStorage.setItem(key, '2');
    if (sessionStorage.getItem('jsh-settings:compact-reload') !== '1') {
      sessionStorage.setItem('jsh-settings:compact-reload', '1');
      location.reload();
    }
  }
})();
