const crypto = require('node:crypto');
const util = {
  generateRandomUUID: () => crypto.randomUUID(),
  TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } }
};
class ProcessManager {
  // Never exit the test runner; count the requests so tests can assert them.
  exit() { processShim.exitRequests += 1; }
  kill() {}
}
const processShim = { ProcessManager, exitRequests: 0, pid: process.pid };
module.exports = { util, process: processShim };
