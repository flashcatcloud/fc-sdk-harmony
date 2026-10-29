const uiObserver = {
  on: () => {},
  off: () => {},
  ScrollEventType: { SCROLL_START: 0, SCROLL_STOP: 1 }
};

// Records what was subscribed, so tests can tell which system event a frame
// source chose. `failWith` makes the next `on` throw a BusinessError-like code.
class Recorder {
  constructor() { this.calls = []; this.failWith = 0; }
  on(type, cb) {
    if (this.failWith !== 0) {
      const e = new Error(`${this.failWith}: Capability not supported.`);
      e.code = this.failWith;
      throw e;
    }
    this.calls.push(`on:${type}`);
  }
  off(type, cb) { this.calls.push(`off:${type}`); }
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
