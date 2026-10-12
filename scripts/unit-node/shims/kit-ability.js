// Minimal runtime shapes; types are erased by transpilation.
// Observers are kept so a test can fire the OS callbacks (uncaught exception,
// unhandled rejection) the way the runtime would.
const lastObservers = {};
const errorManager = {
  on: (type, observer) => {
    lastObservers[type] = observer;
    return 1;
  },
  off: () => {},
  lastObservers
};
const bundleManager = {
  BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
  getBundleInfoForSelfSync: () => ({
    name: 'com.test.bundle',
    versionName: '1.0.0-test',
    versionCode: 1
  })
};
const common = {};
module.exports = { errorManager, bundleManager, common, ApplicationStateChangeCallback: undefined };
