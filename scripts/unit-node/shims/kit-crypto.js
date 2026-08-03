const crypto = require('node:crypto');
const cryptoFramework = {
  createRandom: () => ({
    generateRandomSync: (len) => ({ data: new Uint8Array(crypto.randomBytes(len)) })
  })
};
module.exports = { cryptoFramework };
