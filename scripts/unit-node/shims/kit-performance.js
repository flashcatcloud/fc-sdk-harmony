const hilog = {
  debug: () => {}, info: () => {}, warn: () => {}, error: () => {}, fatal: () => {},
  isLoggable: () => false
};
const hiAppEvent = {
  domain: { OS: 'OS' },
  event: { APP_CRASH: 'APP_CRASH', APP_FREEZE: 'APP_FREEZE' },
  addWatcher: () => ({}),
  removeWatcher: () => {}
};
module.exports = { hilog, hiAppEvent };
