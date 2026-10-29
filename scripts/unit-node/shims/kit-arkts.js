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
// uptimeSeconds / startRealtimeMs: what the process clock answers; tests set them.
const processShim = {
  ProcessManager, exitRequests: 0, pid: process.pid,
  uptimeSeconds: 0, startRealtimeMs: 0,
  uptime() { return processShim.uptimeSeconds; },
  getStartRealtime() { return processShim.startRealtimeMs; }
};
// Runs the task in-thread; counts executions so tests can tell the path.
const taskpool = {
  executed: 0,
  execute(fn, ...args) { taskpool.executed += 1; return Promise.resolve().then(() => fn(...args)); }
};
module.exports = { util, process: processShim, taskpool };
