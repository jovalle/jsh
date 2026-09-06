/****************************************************************************
 * Waterfox preferences                                                     *
 ****************************************************************************/

user_pref('browser.theme.enableWaterfoxCustomizations', 1);
user_pref('browser.nova.enabled', false);
user_pref('ui.systemUsesDarkTheme', 1);
user_pref('layout.css.prefers-color-scheme.content-override', 2);

user_pref('userChrome.tab.connect_to_window', true);
user_pref('userChrome.tab.color_like_toolbar', true);
user_pref('userChrome.tab.lepton_like_padding', false);
user_pref('userChrome.tab.photon_like_padding', true);
user_pref('userChrome.tab.dynamic_separator', false);
user_pref('userChrome.tab.static_separator', true);
user_pref('userChrome.tab.static_separator.selected_accent', false);
user_pref('userChrome.tab.bar_separator', false);
user_pref('userChrome.tab.newtab_button_like_tab', false);
user_pref('userChrome.tab.newtab_button_smaller', true);
user_pref('userChrome.tab.newtab_button_proton', false);
user_pref('userChrome.icon.panel_full', false);
user_pref('userChrome.icon.panel_photon', true);
user_pref('userChrome.tab.box_shadow', false);
user_pref('userChrome.tab.bottom_rounded_corner', false);
user_pref('userChrome.tab.photon_like_contextline', true);
user_pref('userChrome.rounding.square_tab', true);
user_pref('userChrome.theme.monospace', true);

user_pref('sidebar.revamp', false);
user_pref('sidebar.verticalTabs', false);
user_pref('browser.tabs.verticalTabs.tree.enabled', false);

user_pref('extensions.activeThemeID', 'default-theme@mozilla.org');
user_pref('toolkit.legacyUserProfileCustomizations.stylesheets', true);

user_pref('app.update.enabled', true);
user_pref('app.update.auto', true);
user_pref('app.update.disabledForTesting', false);
user_pref('extensions.update.enabled', true);
user_pref('extensions.update.autoUpdateDefault', true);

user_pref('userChrome.icon.global_menu', false);

user_pref('browser.search.separatePrivateDefault', true);
user_pref('browser.search.separatePrivateDefault.ui.enabled', true);

user_pref('privacy.history.custom', true);
user_pref('browser.privatebrowsing.autostart', false);
user_pref('places.history.enabled', false);
user_pref('browser.formfill.enable', false);
user_pref('privacy.sanitize.sanitizeOnShutdown', false);

user_pref('privacy.globalprivacycontrol.enabled', false);
user_pref('privacy.globalprivacycontrol.was_ever_enabled', false);
user_pref('network.http.sendRefererHeader', 0);

user_pref('extensions.formautofill.addresses.enabled', false);
user_pref('extensions.formautofill.creditCards.enabled', false);

user_pref('network.trr.excluded-domains', 'techn.is,go');
user_pref('browser.fixup.domainwhitelist.go', true);
