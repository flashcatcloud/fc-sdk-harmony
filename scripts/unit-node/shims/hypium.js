// hypium-compatible harness: same describe/it/expect surface, sequential
// async execution, per-test error capture.
const queue = [];
const stack = [];

function describe(name, fn) {
  stack.push(name);
  try {
    fn();
  } finally {
    stack.pop();
  }
}

function it(name, _flags, fn) {
  queue.push({ name: [...stack, name].join(' > '), fn });
}

function format(value) {
  try {
    return typeof value === 'string' ? JSON.stringify(value) : String(value);
  } catch (_e) {
    return '<unprintable>';
  }
}

function expect(actual) {
  return {
    assertEqual(expected) {
      if (!Object.is(actual, expected)) {
        throw new Error(`assertEqual: expected ${format(expected)}, got ${format(actual)}`);
      }
    },
    assertTrue() {
      if (actual !== true) throw new Error(`assertTrue: got ${format(actual)}`);
    },
    assertFalse() {
      if (actual !== false) throw new Error(`assertFalse: got ${format(actual)}`);
    },
    assertLarger(expected) {
      if (!(actual > expected)) throw new Error(`assertLarger: ${format(actual)} <= ${format(expected)}`);
    },
    assertNull() {
      if (actual !== null) throw new Error(`assertNull: got ${format(actual)}`);
    },
    assertUndefined() {
      if (actual !== undefined) throw new Error(`assertUndefined: got ${format(actual)}`);
    }
  };
}

async function __run() {
  let passed = 0;
  let failed = 0;
  for (const test of queue) {
    try {
      await test.fn();
      passed += 1;
    } catch (e) {
      failed += 1;
      console.error(`FAIL ${test.name}\n  ${e && e.message ? e.message : e}`);
    }
  }
  return { passed, failed };
}

const TestType = { FUNCTION: 1 };
const Size = { SMALLTEST: 1 };
const Level = { LEVEL0: 1 };

module.exports = { describe, it, expect, TestType, Size, Level, __run };
