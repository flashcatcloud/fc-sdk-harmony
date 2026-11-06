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
module.exports = { deviceInfo, zlib, systemDateTime };
