/****************************************************************************
 * Waterfox preferences                                                     *
 ****************************************************************************/

user_pref('sidebar.revamp', false);
user_pref('sidebar.verticalTabs', false);
user_pref('browser.tabs.verticalTabs.tree.enabled', false);

user_pref('app.update.enabled', true);
user_pref('app.update.auto', true);
user_pref('app.update.disabledForTesting', false);
user_pref('extensions.update.enabled', true);
user_pref('extensions.update.autoUpdateDefault', true);

user_pref('browser.search.separatePrivateDefault', true);
user_pref('browser.search.separatePrivateDefault.ui.enabled', true);
user_pref('accessibility.typeaheadfind', false);

user_pref('privacy.history.custom', true);
user_pref('browser.privatebrowsing.autostart', false);
user_pref('places.history.enabled', false);
user_pref('browser.formfill.enable', false);
user_pref('privacy.sanitize.sanitizeOnShutdown', false);

user_pref('dom.storage_access.enabled', false);
user_pref('privacy.globalprivacycontrol.enabled', false);
user_pref('privacy.globalprivacycontrol.was_ever_enabled', false);
user_pref('network.http.sendRefererHeader', 2);

user_pref('extensions.formautofill.addresses.enabled', false);
user_pref('extensions.formautofill.creditCards.enabled', false);

user_pref('network.trr.excluded-domains', 'techn.is,go');
user_pref('browser.fixup.domainwhitelist.go', true);
