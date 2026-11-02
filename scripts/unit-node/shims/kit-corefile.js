// fileIo backed by node:fs so persistence logic (claims, rolls, atomic
// writes, quotas) runs against a REAL filesystem in unit tests.
const nodeFs = require('node:fs');
const nodePath = require('node:path');

const OpenMode = {
  READ_ONLY: 0o0,
  WRITE_ONLY: 0o1,
  READ_WRITE: 0o2,
  CREATE: 0o100,
  TRUNC: 0o1000,
  APPEND: 0o2000,
  SYNC: 0o4000000
};

function flagsFor(mode) {
  const m = mode ?? OpenMode.READ_ONLY;
  let flags = '';
  const append = (m & OpenMode.APPEND) !== 0;
  const trunc = (m & OpenMode.TRUNC) !== 0;
  const create = (m & OpenMode.CREATE) !== 0;
  const writable = (m & (OpenMode.WRITE_ONLY | OpenMode.READ_WRITE)) !== 0;
  if (append) flags = create ? 'a' : 'a';
  else if (trunc || (writable && create)) flags = 'w';
  else if (writable) flags = 'r+';
  else flags = 'r';
  return flags;
}

// Call counters, so tests can pin how much file-system work a path does.
const calls = { accessSync: 0, listFileSync: 0, statSync: 0 };

// Kernel pseudo files (/proc/...): content on read, but a size of 0 — and the
// device's readTextSync reads only as many bytes as the size says. Tests put
// path -> content here.
const pseudoFiles = new Map();
const pseudoFds = new Map();
let nextPseudoFd = -100;

const fileIo = {
  OpenMode,
  calls,
  pseudoFiles,
  accessSync: (p) => { calls.accessSync += 1; return nodeFs.existsSync(p); },
  mkdirSync: (p, recursive) => nodeFs.mkdirSync(p, { recursive: recursive === true }),
  openSync: (p, mode) => {
    if (pseudoFiles.has(p)) {
      const fd = nextPseudoFd--;
      pseudoFds.set(fd, pseudoFiles.get(p));
      return { fd };
    }
    return { fd: nodeFs.openSync(p, flagsFor(mode)) };
  },
  readSync: (fd, buf) => {
    if (pseudoFds.has(fd)) {
      const bytes = Buffer.from(pseudoFds.get(fd), 'utf8');
      const n = Math.min(bytes.length, buf.byteLength);
      bytes.copy(Buffer.from(buf), 0, 0, n);
      return n;
    }
    return nodeFs.readSync(fd, new Uint8Array(buf));
  },
  writeSync: (fd, content) => nodeFs.writeSync(fd, content),
  fsyncSync: (fd) => nodeFs.fsyncSync(fd),
  closeSync: (file) => {
    const fd = typeof file === 'object' ? file.fd : file;
    if (pseudoFds.delete(fd)) {
      return;
    }
    nodeFs.closeSync(fd);
  },
  renameSync: (from, to) => nodeFs.renameSync(from, to),
  unlinkSync: (p) => nodeFs.unlinkSync(p),
  listFileSync: (dir) => { calls.listFileSync += 1; return nodeFs.readdirSync(dir); },
  readTextSync: (p) => (pseudoFiles.has(p) ? '' : nodeFs.readFileSync(p, 'utf8')),
  statSync: (p) => {
    calls.statSync += 1;
    if (pseudoFiles.has(p)) {
      return { size: 0, mtimeMs: 0, isDirectory: () => false };
    }
    const s = nodeFs.statSync(p);
    return { size: s.size, mtimeMs: s.mtimeMs, isDirectory: () => s.isDirectory() };
  },
  rmdirSync: (p) => nodeFs.rmSync(p, { recursive: true, force: true })
};

module.exports = { fileIo };
