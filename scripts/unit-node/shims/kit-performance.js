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
// Memory readings by path. Tests set `rssKb` and read `calls` to see which
// path a reader took; real devices answer in KB as bigint.
const hidebug = {
  rssKb: 1000n,
  calls: { getRssInfo: 0, getAppNativeMemInfo: 0, getAppNativeMemInfoAsync: 0 },
  getRssInfo() { hidebug.calls.getRssInfo += 1; return { rss: hidebug.rssKb, swapRss: 0n }; },
  getAppNativeMemInfo() { hidebug.calls.getAppNativeMemInfo += 1; return { rss: hidebug.rssKb, pss: 0n, vss: 0n }; },
  getAppNativeMemInfoAsync() {
    hidebug.calls.getAppNativeMemInfoAsync += 1;
    return Promise.resolve({ rss: hidebug.rssKb, pss: 0n, vss: 0n });
  }
};
module.exports = { hilog, hiAppEvent, hidebug };
