const appRecovery = {
  enableAppRecovery: () => {},
  restartApp: () => {},
  RestartFlag: { ALWAYS_RESTART: 1 },
  SaveOccasionFlag: { SAVE_WHEN_ERROR: 1 },
  SaveModeFlag: { SAVE_WITH_FILE: 1 }
};
module.exports = appRecovery;
module.exports.default = appRecovery;
