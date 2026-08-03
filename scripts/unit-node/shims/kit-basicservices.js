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
module.exports = { deviceInfo, zlib };
