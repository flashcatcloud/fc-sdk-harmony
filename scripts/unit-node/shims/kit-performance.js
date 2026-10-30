const hilog = {
  debug: () => {}, info: () => {}, warn: () => {}, error: () => {}, fatal: () => {},
  isLoggable: () => false
};
// `watchers` and `eventConfigs` record what the SDK registered, so a test can
// deliver system events to a watcher and see the sampling config it set.
const hiAppEvent = {
  domain: { OS: 'OS' },
  event: { APP_CRASH: 'APP_CRASH', APP_FREEZE: 'APP_FREEZE', MAIN_THREAD_JANK: 'MAIN_THREAD_JANK' },
  watchers: [],
  eventConfigs: [],
  addWatcher: (watcher) => { hiAppEvent.watchers.push(watcher); return {}; },
  removeWatcher: (watcher) => {
    hiAppEvent.watchers = hiAppEvent.watchers.filter((w) => w.name !== watcher.name);
  },
  setEventConfig: (name, config) => {
    hiAppEvent.eventConfigs.push({ name, config });
    return Promise.resolve();
  }
};
module.exports = { hilog, hiAppEvent };
