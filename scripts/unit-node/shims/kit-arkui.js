const uiObserver = {
  ScrollEventType: { SCROLL_START: 0, SCROLL_STOP: 1 },
  RouterPageState: { ABOUT_TO_APPEAR: 0, ABOUT_TO_DISAPPEAR: 1, ON_PAGE_SHOW: 2, ON_PAGE_HIDE: 3, ON_BACK_PRESS: 4 },
  // Live routerPageUpdate callbacks, so tests can fire page shows and hides.
  routerPageUpdate: [],
  on(type, _context, callback) {
    if (type === 'routerPageUpdate') uiObserver.routerPageUpdate.push(callback);
  },
  off(type, _context, callback) {
    if (type === 'routerPageUpdate') {
      uiObserver.routerPageUpdate = uiObserver.routerPageUpdate.filter((c) => c !== callback);
    }
  }
};

// Records what was subscribed, so tests can tell which system event a frame
// source chose, and keeps the live callbacks per event so tests can fire them.
// `failWith` makes the next `on` throw a BusinessError-like code.
class Recorder {
  constructor() { this.calls = []; this.failWith = 0; this.callbacks = {}; }
  on(type, cb) {
    if (this.failWith !== 0) {
      const e = new Error(`${this.failWith}: Capability not supported.`);
      e.code = this.failWith;
      throw e;
    }
    this.calls.push(`on:${type}`);
    (this.callbacks[type] = this.callbacks[type] || []).push(cb);
  }
  off(type, cb) {
    this.calls.push(`off:${type}`);
    this.callbacks[type] = (this.callbacks[type] || []).filter((c) => c !== cb);
  }
}

const window = {
  // The window findWindow / getLastWindow hand out; reset with `resetFakes`.
  fake: null,
  lookups: [],
  findWindow(name) { window.lookups.push(`find:${name}`); return window.fake; },
  getLastWindow(_ctx) { window.lookups.push('last'); return Promise.resolve(window.fake); },
  resetFakes() {
    window.fake = new Recorder();
    window.fake.getUIContext = () => new UIContext();
    window.lookups = [];
    UIContext.observer = new Recorder();
  }
};

class UIContext {
  getWindowName() { return 'main'; }
  getHostContext() { return undefined; }
  getUIObserver() { return UIContext.observer; }
}
UIContext.observer = new Recorder();
window.resetFakes();

module.exports = { uiObserver, window, UIContext };
