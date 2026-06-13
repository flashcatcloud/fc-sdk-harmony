// Extract the GNU build-id from an ELF shared object, mirroring fc-rum's
// logic/sourcemap/elf_buildid.go so the client-computed build_id matches the
// identifier the backend stores and looks up at symbolication time.

const NT_GNU_BUILD_ID = 3;

function align4(n: number): number {
  return (n + 3) & ~3;
}

/**
 * Reads the raw descriptor bytes of the `.note.gnu.build-id` note from an ELF
 * `.so` and returns them as a lowercase hex string (the "codeID"). Returns null
 * when the section/note is absent (e.g. the `.so` was built without
 * `-Wl,--build-id`, or was stripped of notes).
 */
export function extractElfBuildId(data: Buffer): string | null {
  // ELF magic
  if (data.length < 20 || data[0] !== 0x7f || data[1] !== 0x45 || data[2] !== 0x4c || data[3] !== 0x46) {
    return null;
  }
  const is64 = data[4] === 2; // EI_CLASS: 1=32-bit, 2=64-bit
  const little = data[5] === 1; // EI_DATA: 1=little-endian

  const u16 = (off: number): number => (little ? data.readUInt16LE(off) : data.readUInt16BE(off));
  const u32 = (off: number): number => (little ? data.readUInt32LE(off) : data.readUInt32BE(off));
  const uPtr = (off: number): number =>
    is64
      ? Number(little ? data.readBigUInt64LE(off) : data.readBigUInt64BE(off))
      : u32(off);

  // Section header table offset / entry size / count, and the section-name string table index.
  const eShoff = is64 ? uPtr(0x28) : u32(0x20);
  const eShentsize = is64 ? u16(0x3a) : u16(0x2e);
  const eShnum = is64 ? u16(0x3c) : u16(0x30);
  const eShstrndx = is64 ? u16(0x3e) : u16(0x32);
  if (eShoff === 0 || eShnum === 0) {
    return null;
  }

  // sh_name (u32 @0), sh_type (@4), sh_offset (64: @0x18 / 32: @0x10), sh_size (64: @0x20 / 32: @0x14)
  const shName = (i: number): number => u32(eShoff + i * eShentsize + 0);
  const shOffset = (i: number): number =>
    is64 ? uPtr(eShoff + i * eShentsize + 0x18) : u32(eShoff + i * eShentsize + 0x10);
  const shSize = (i: number): number =>
    is64 ? uPtr(eShoff + i * eShentsize + 0x20) : u32(eShoff + i * eShentsize + 0x14);

  const strTabOff = shOffset(eShstrndx);
  const sectionName = (i: number): string => {
    const nameOff = strTabOff + shName(i);
    let end = nameOff;
    while (end < data.length && data[end] !== 0) {
      end++;
    }
    return data.toString('ascii', nameOff, end);
  };

  for (let i = 0; i < eShnum; i++) {
    if (sectionName(i) !== '.note.gnu.build-id') {
      continue;
    }
    let p = shOffset(i);
    const end = p + shSize(i);
    while (p + 12 <= end) {
      const namesz = u32(p);
      const descsz = u32(p + 4);
      const ntype = u32(p + 8);
      let q = p + 12;
      const name = data.toString('ascii', q, q + namesz).replace(/\0+$/, '');
      q += align4(namesz);
      const desc = data.subarray(q, q + descsz);
      q += align4(descsz);
      if (ntype === NT_GNU_BUILD_ID && name === 'GNU') {
        return Buffer.from(desc).toString('hex');
      }
      p = q;
    }
    return null;
  }
  return null;
}
