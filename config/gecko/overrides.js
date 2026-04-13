/****************************************************************************
 * Local Gecko overrides                                                     *
 ****************************************************************************/

// Waterfox 6.7 Appearance: Proton with the Default system-aware palette.
user_pref('browser.theme.waterfox.browserStyle', 'proton');
user_pref('browser.theme.enableWaterfoxCustomizations', 2);
user_pref('browser.nova.enabled', false);
user_pref('browser.theme.waterfox.mode', 'system');
user_pref('browser.theme.waterfox.color', 'default');
user_pref('layout.css.prefers-color-scheme.content-override', 2);

// Waterfox macOS Library menus: avoid wireframe menu icons overlapping labels.
user_pref('userChrome.icon.global_menu', false);
