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

const fileIo = {
  OpenMode,
  accessSync: (p) => nodeFs.existsSync(p),
  mkdirSync: (p, recursive) => nodeFs.mkdirSync(p, { recursive: recursive === true }),
  openSync: (p, mode) => ({ fd: nodeFs.openSync(p, flagsFor(mode)) }),
  writeSync: (fd, content) => nodeFs.writeSync(fd, content),
  fsyncSync: (fd) => nodeFs.fsyncSync(fd),
  closeSync: (file) => nodeFs.closeSync(typeof file === 'object' ? file.fd : file),
  renameSync: (from, to) => nodeFs.renameSync(from, to),
  unlinkSync: (p) => nodeFs.unlinkSync(p),
  listFileSync: (dir) => nodeFs.readdirSync(dir),
  readTextSync: (p) => nodeFs.readFileSync(p, 'utf8'),
  statSync: (p) => {
    const s = nodeFs.statSync(p);
    return { size: s.size, mtimeMs: s.mtimeMs, isDirectory: () => s.isDirectory() };
  },
  rmdirSync: (p) => nodeFs.rmSync(p, { recursive: true, force: true })
};

module.exports = { fileIo };
