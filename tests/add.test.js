const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'conf', 'spicetify', 'add.js'), 'utf8');

test('native plus opens the playlist menu on macOS', () => {
  const listeners = {};
  const shortcuts = [];
  let menuEvent;
  class Element {
    closest(selector) {
      return selector === 'button[aria-checked="false"]' ? this : null;
    }
  }
  const button = new Element();
  button.isConnected = true;
  button.__reactFiber$test = {
    memoizedProps: {
      curateDefault() {},
      handleContextMenu(event) {
        menuEvent = event;
      },
      uri: 'spotify:track:test',
    },
  };
  button.setAttribute = (name, value) => {
    if (name === 'aria-label') button.ariaLabel = value;
  };
  const Spicetify = {
    ContextMenu: {},
    Keyboard: { registerShortcut: (shortcut) => shortcuts.push(shortcut) },
    Player: {},
  };
  vm.runInNewContext(source, {
    document: {
      addEventListener() {},
      body: {},
      createElement: () => ({}),
      getElementById: () => null,
      head: { append() {} },
      querySelectorAll: () => [button],
    },
    Element,
    MutationObserver: class {
      observe() {}
    },
    navigator: { userAgentData: { platform: 'macOS' }, platform: 'MacIntel' },
    requestAnimationFrame: (callback) => callback(),
    Spicetify,
    window: {
      Spicetify,
      addEventListener: (type, handler) => {
        listeners[type] = handler;
      },
    },
  });

  const event = {
    target: button,
    type: 'click',
    preventDefault() {
      this.prevented = true;
    },
    stopPropagation() {
      this.stopped = true;
    },
  };
  listeners.click(event);
  assert.equal(button.ariaLabel, 'Add to Playlists');
  assert.equal(menuEvent.currentTarget, button);
  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true);
  assert.equal(shortcuts[0].meta, true);
});
