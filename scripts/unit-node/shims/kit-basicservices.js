const nodeZlib = require('node:zlib');
const deviceInfo = {
  brand: 'TestBrand', productModel: 'TestModel', osFullName: 'OpenHarmony-5.0.0',
  sdkApiVersion: 12, deviceType: 'phone', marketName: 'Test'
};
const zlib = {
  ReturnStatus: { OK: 0, STREAM_END: 1, NEED_DICT: 2 },
  createZipSync: () => ({
    // Real RFC1950 output via node:zlib so compression behavior is genuine.
    compress: async (dest, source, sourceLen) => {
      const input = Buffer.from(source, 0, sourceLen ?? source.byteLength);
      const compressed = nodeZlib.deflateSync(input);
      if (compressed.byteLength > dest.byteLength) {
        throw new Error('17800007: output buffer too small');
      }
      compressed.copy(Buffer.from(dest));
      return { status: 0, destLen: compressed.byteLength };
    }
  })
};
// elapsedMs: what the elapsed clock answers when a test sets it; null reads the host's.
// asleepMs: deep sleep since boot, counted by the STARTUP clock only.
// failing: the clock throws, as a system call may.
const systemDateTime = {
  TimeType: { STARTUP: 0, ACTIVE: 1 },
  elapsedMs: null,
  asleepMs: 0,
  failing: false,
  getUptime: (type, nanoseconds) => {
    if (systemDateTime.failing) {
      throw new Error('13000001: Network connection error or OS error.');
    }
    if (systemDateTime.elapsedMs !== null) {
      const ms = systemDateTime.elapsedMs + (type === systemDateTime.TimeType.STARTUP ? systemDateTime.asleepMs : 0);
      return nanoseconds ? ms * 1e6 : ms;
    }
    return Number(process.hrtime.bigint() / (nanoseconds ? 1n : 1000000n));
  }
};
// batterySOC / powerMode: what the system reports; tests set them (a getter that throws models a failing call).
const batteryInfo = { batterySOC: 80 };
const power = {
  DevicePowerMode: { MODE_NORMAL: 600, MODE_POWER_SAVE: 601, MODE_PERFORMANCE: 602, MODE_EXTREME_POWER_SAVE: 603,
    MODE_CUSTOM_POWER_SAVE: 650 },
  powerMode: 600,
  getPowerMode: () => power.powerMode
};
// Subscribers record their events and callback; `deliver` fires every live one that listens.
const commonEventManager = {
  subscribers: [],
  createSubscriberSync: (info) => ({ events: info.events, callback: null }),
  subscribe: (subscriber, callback) => {
    subscriber.callback = callback;
    commonEventManager.subscribers.push(subscriber);
  },
  unsubscribe: (subscriber, callback) => {
    commonEventManager.subscribers = commonEventManager.subscribers.filter((s) => s !== subscriber);
    if (typeof callback === 'function') callback(undefined);
  },
  deliver: (event) => {
    for (const s of commonEventManager.subscribers.slice()) {
      if (s.events.includes(event) && s.callback !== null) s.callback(undefined, { event });
    }
  }
};
module.exports = { deviceInfo, zlib, systemDateTime, batteryInfo, power, commonEventManager };
