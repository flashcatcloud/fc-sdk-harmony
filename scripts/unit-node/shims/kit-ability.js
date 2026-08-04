// Minimal runtime shapes; types are erased by transpilation.
const errorManager = {
  on: () => 1,
  off: () => {}
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
