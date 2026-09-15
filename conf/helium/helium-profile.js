const isJXA = typeof ObjC !== 'undefined';
if (isJXA) ObjC.import('Foundation');
const fs = isJXA ? null : require('node:fs');

const preferenceValues = [
  [['helium', 'completed_onboarding'], true],
  [['helium', 'global_privacy_control'], true],
  [['helium', 'services', 'enabled'], true],
  [['helium', 'services', 'user_consented'], true],
  [['helium', 'services', 'schema_version'], 1],
  [['helium', 'services', 'disable_schema_alerts'], true],
  [['helium', 'services', 'browser_updates'], true],
  [['helium', 'services', 'ublock_assets'], true],
  [['helium', 'services', 'ext_proxy'], true],
  [['helium', 'services', 'bangs'], false],
  [['helium', 'services', 'spellcheck_files'], false],
  [['enable_do_not_track'], true],
  [['credentials_enable_service'], false],
  [['profile', 'password_manager_enabled'], false],
  [['profile', 'cookie_controls_mode'], 1],
  [['profile', 'default_content_setting_values', 'notifications'], 2],
  [['profile', 'default_content_setting_values', 'geolocation'], 2],
  [['profile', 'default_content_setting_values', 'media_stream_mic'], 2],
  [['profile', 'default_content_setting_values', 'media_stream_camera'], 2],
  [['profile', 'default_content_setting_values', 'popups'], 2],
  [['profile', 'default_content_setting_values', 'automatic_downloads'], 2],
  [['autofill', 'profile_enabled'], false],
  [['autofill', 'credit_card_enabled'], false],
  [['alternate_error_pages', 'enabled'], false],
  [['search', 'suggest_enabled'], false],
  [['background_mode', 'enabled'], false],
  [['webrtc', 'ip_handling_policy'], 'disable_non_proxied_udp'],
  [['privacy_sandbox', 'first_party_sets_enabled'], false],
  [['network_prediction_options'], 2],
];

const localStateValues = [
  [['helium', 'browser', 'default_browser_infobar_rejected'], true],
  [['helium', 'crash_reporting', 'mode'], -1],
  [['user_experience_metrics', 'reporting_enabled'], false],
  [['hardware_acceleration_mode', 'enabled'], true],
];

function readJSON(file, optional) {
  if (!isJXA) {
    if (!fs.existsSync(file)) {
      if (optional) return {};
      throw new Error(`cannot read ${file}`);
    }
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  }
  if (!$.NSFileManager.defaultManager.fileExistsAtPath(file)) {
    if (optional) return {};
    throw new Error(`cannot read ${file}`);
  }
  const data = $.NSData.dataWithContentsOfFile(file);
  if (!data) throw new Error(`cannot read ${file}`);
  const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  return JSON.parse(text);
}

function writeJSON(file, value) {
  if (!isJXA) {
    fs.writeFileSync(file, JSON.stringify(value));
    return;
  }
  const text = $(JSON.stringify(value));
  if (!text.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) {
    throw new Error(`cannot write ${file}`);
  }
}

function getValue(root, keys) {
  return keys.reduce(
    (value, key) => (value && typeof value === 'object' ? value[key] : undefined),
    root,
  );
}

function setValue(root, keys, value) {
  let current = root;
  for (let index = 0; index < keys.length - 1; index++) {
    const key = keys[index];
    if (!current[key] || typeof current[key] !== 'object' || Array.isArray(current[key]))
      current[key] = {};
    current = current[key];
  }
  current[keys[keys.length - 1]] = value;
}

function stage(argv) {
  const preferences = readJSON(argv[0], true);
  const localState = readJSON(argv[1], true);
  preferenceValues.forEach(([keys, value]) => setValue(preferences, keys, value));
  localStateValues.forEach(([keys, value]) => setValue(localState, keys, value));
  if (preferences.profile && preferences.profile.content_settings) {
    delete preferences.profile.content_settings.exceptions;
  }
  writeJSON(argv[2], preferences);
  writeJSON(argv[3], localState);
}

function verifyValues(root, expected) {
  expected.forEach(([keys, wanted]) => {
    const actual = getValue(root, keys);
    if (actual !== wanted) {
      throw new Error(
        `${keys.join('.')} is ${JSON.stringify(actual)}, expected ${JSON.stringify(wanted)}`,
      );
    }
  });
}

function verify(argv) {
  const preferences = readJSON(argv[0], false);
  const localState = readJSON(argv[1], false);
  verifyValues(preferences, preferenceValues);
  verifyValues(localState, localStateValues);
  const exceptions = getValue(preferences, ['profile', 'content_settings', 'exceptions']);
  if (exceptions === undefined) return;
  Object.entries(exceptions).forEach(([type, values]) => {
    if (type === 'has_migrated_local_network_access' && values === true) return;
    if (!values || typeof values !== 'object' || Array.isArray(values)) {
      throw new Error(`invalid content-setting exception category: ${type}`);
    }
    const origins = Object.keys(values);
    if (type === 'site_engagement' && origins.every((origin) => origin.startsWith('chrome://')))
      return;
    if (origins.length) throw new Error(`content-setting exceptions remain: ${type}`);
  });
}

function verifyPolicy(argv) {
  if (!isJXA) throw new Error('managed preference verification requires macOS');
  const domainName = argv.shift();
  const domain = $(domainName);
  const settingsKey = $('ExtensionSettings');
  const forceListKey = $('ExtensionInstallForcelist');
  $.CFPreferencesAppSynchronize(domain);
  if (
    !Boolean($.CFPreferencesAppValueIsForced(settingsKey, domain)) ||
    !Boolean($.CFPreferencesAppValueIsForced(forceListKey, domain))
  ) {
    throw new Error('Helium extension policies are not managed preferences');
  }
  const defaults = $.NSUserDefaults.alloc.initWithSuiteName(domainName);
  const settings = ObjC.deepUnwrap(defaults.dictionaryForKey(settingsKey));
  const forceList = ObjC.deepUnwrap(defaults.arrayForKey(forceListKey));
  const separator = argv.indexOf('--');
  const settingsIDs = argv.slice(0, separator);
  const forceIDs = argv.slice(separator + 1);
  settingsIDs.forEach((id) => {
    if (settings?.[id]?.toolbar_pin !== 'force_pinned')
      throw new Error(`managed pin policy is invalid for ${id}`);
  });
  forceIDs.forEach((id) => {
    if (!forceList?.includes(id)) throw new Error(`managed install policy is invalid for ${id}`);
  });
}

function policyValues(argv) {
  const separator = argv.indexOf('--');
  const settingsIDs = argv.slice(0, separator);
  const forceIDs = argv.slice(separator + 1);
  return {
    ExtensionInstallForcelist: forceIDs,
    ExtensionSettings: Object.fromEntries(
      settingsIDs.map((id) => [id, { toolbar_pin: 'force_pinned' }]),
    ),
  };
}

function stagePolicy(argv) {
  const policyFile = argv.shift();
  writeJSON(policyFile, policyValues(argv));
}

function verifyPolicyFile(argv) {
  const policyFile = argv.shift();
  const actual = readJSON(policyFile, false);
  const expected = policyValues(argv);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error('Helium extension policy does not match the managed configuration');
  }
}

function pinExtensions(argv) {
  const preferencesFile = argv.shift();
  const preferences = readJSON(preferencesFile, false);
  setValue(preferences, ['extensions', 'pinned_extensions'], argv);
  writeJSON(preferencesFile, preferences);
}

function run(argv) {
  const command = argv.shift();
  if (command === 'stage') return stage(argv);
  if (command === 'verify') return verify(argv);
  if (command === 'verify-policy') return verifyPolicy(argv);
  if (command === 'stage-policy') return stagePolicy(argv);
  if (command === 'verify-policy-file') return verifyPolicyFile(argv);
  if (command === 'pin-extensions') return pinExtensions(argv);
  throw new Error(`unknown command: ${command || '(missing)'}`);
}

if (!isJXA) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
