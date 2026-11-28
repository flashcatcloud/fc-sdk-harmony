// i18n: the preferred languages and the system time zone; tests set them.
const i18n = {
  languages: ['zh-Hans-CN', 'en-US'],
  timeZoneId: 'Asia/Shanghai',
  System: { getPreferredLanguageList: () => i18n.languages.slice() },
  getTimeZone: () => ({ getID: () => i18n.timeZoneId })
};
module.exports = { i18n };
