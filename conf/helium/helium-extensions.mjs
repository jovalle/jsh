import fs from 'node:fs';

async function browserTarget(port) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const targets = await fetch(`http://127.0.0.1:${port}/json/list`).then((response) =>
      response.json(),
    );
    const page = targets.find((item) => item.type === 'page');
    if (page) return page;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Helium did not create a browser page');
}

async function configure(port, extensionIds) {
  const page = await browserTarget(port);
  const socket = new WebSocket(page.webSocketDebuggerUrl, {
    headers: { Origin: 'http://127.0.0.1' },
  });
  const pending = new Map();
  let sequence = 0;
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    message.error ? reject(new Error(message.error.message)) : resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', () => reject(new Error('cannot connect to Helium')), {
      once: true,
    });
  });
  const call = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++sequence;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  await call('Page.navigate', { url: 'chrome://extensions/' });
  for (let attempt = 0; attempt < 100; attempt++) {
    const location = await call('Runtime.evaluate', {
      expression: 'location.href',
      returnByValue: true,
    });
    if (location.result.value.startsWith('chrome://extensions')) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  const expression = `(${async function (ids) {
    let extensions = [];
    for (let attempt = 0; attempt < 120; attempt++) {
      extensions = await chrome.developerPrivate.getExtensionsInfo({
        includeDisabled: true,
        includeTerminated: true,
      });
      if (ids.every((id) => extensions.some((extension) => extension.id === id))) break;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    const missing = ids.filter((id) => !extensions.some((extension) => extension.id === id));
    if (missing.length) throw new Error(`extensions not installed: ${missing.join(', ')}`);
    await Promise.all(
      extensions
        .filter((extension) => ids.includes(extension.id) && extension.state !== 'ENABLED')
        .map((extension) => chrome.management.setEnabled(extension.id, true)),
    );
    for (let attempt = 0; attempt < 100; attempt++) {
      extensions = await chrome.developerPrivate.getExtensionsInfo({
        includeDisabled: true,
        includeTerminated: true,
      });
      const managed = extensions.filter((extension) => ids.includes(extension.id));
      if (
        managed.every(
          (extension) => extension.state === 'ENABLED' && extension.pinnedToToolbar !== undefined,
        )
      )
        break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    let managed = extensions.filter((extension) => ids.includes(extension.id));
    await Promise.all(
      managed.map((extension) =>
        chrome.developerPrivate.updateExtensionConfiguration({
          extensionId: extension.id,
          incognitoAccess: true,
        }),
      ),
    );
    for (let attempt = 0; attempt < 100; attempt++) {
      extensions = await chrome.developerPrivate.getExtensionsInfo({
        includeDisabled: true,
        includeTerminated: true,
      });
      managed = extensions.filter((extension) => ids.includes(extension.id));
      if (
        managed.every(
          (extension) => extension.state === 'ENABLED' && extension.pinnedToToolbar !== undefined,
        )
      )
        break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    for (const extension of managed) {
      try {
        await chrome.developerPrivate.updateExtensionConfiguration({
          extensionId: extension.id,
          pinnedToToolbar: true,
        });
      } catch (error) {
        throw new Error(`${extension.id}: ${error.message}`);
      }
    }
    extensions = await chrome.developerPrivate.getExtensionsInfo({
      includeDisabled: true,
      includeTerminated: true,
    });
    return ids.map((id) => {
      const extension = extensions.find((item) => item.id === id);
      return {
        id,
        incognito: extension.incognitoAccess.isActive,
        pinned: extension.pinnedToToolbar ?? null,
        state: extension.state,
      };
    });
  }})(${JSON.stringify(extensionIds)})`;
  const response = await call('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  let failure;
  if (response.exceptionDetails) {
    failure = new Error(
      response.exceptionDetails.exception?.description || response.exceptionDetails.text,
    );
  } else {
    const states = response.result.value;
    const invalid = states.filter(
      (state) => !state.incognito || state.pinned === false || state.state !== 'ENABLED',
    );
    if (invalid.length) failure = new Error(`invalid extension state: ${JSON.stringify(invalid)}`);
  }
  await call('Browser.close').catch(() => {});
  socket.close();
  if (failure) throw failure;
}

function verifyState(secureFile, preferencesFile, ids) {
  const separator = ids.indexOf('--');
  const extensionIds = ids.slice(0, separator);
  const incognitoIds = ids.slice(separator + 1);
  const settings = JSON.parse(fs.readFileSync(secureFile, 'utf8')).extensions?.settings || {};
  const pinned =
    JSON.parse(fs.readFileSync(preferencesFile, 'utf8')).extensions?.pinned_extensions || [];
  const missing = extensionIds.filter((id) => !settings[id]);
  const temporary = extensionIds.filter((id) => settings[id]?.location === 8);
  const unavailable = incognitoIds.filter((id) => settings[id]?.incognito !== true);
  const unpinned = extensionIds.filter((id) => !pinned.includes(id));
  if (missing.length) console.error(`extensions missing: ${missing.join(', ')}`);
  if (temporary.length)
    console.error(`extensions registered only for command-line launches: ${temporary.join(', ')}`);
  if (unavailable.length)
    console.error(`extensions unavailable in Incognito: ${unavailable.join(', ')}`);
  if (unpinned.length) console.error(`extensions not pinned: ${unpinned.join(', ')}`);
  if (missing.length || temporary.length || unavailable.length || unpinned.length)
    process.exitCode = 1;
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case 'configure':
      await configure(args[0], args.slice(1));
      break;
    case 'verify-state':
      verifyState(args[0], args[1], args.slice(2));
      break;
    default:
      throw new Error(`unknown command: ${command || '(missing)'}`);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
