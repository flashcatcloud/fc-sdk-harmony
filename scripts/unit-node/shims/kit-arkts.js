const crypto = require('node:crypto');
const util = {
  generateRandomUUID: () => crypto.randomUUID(),
  TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } }
};
class ProcessManager {
  exit() { /* never exit the test runner */ }
  kill() {}
}
const processShim = { ProcessManager };
module.exports = { util, process: processShim };
