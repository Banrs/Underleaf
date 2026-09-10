// Extract the largest PNG image from assets/TeXLocal.icns into
// assets/TeXLocal.png, for feeding `tauri icon` (which wants a square PNG
// master). An .icns file is a chunk list: 8-byte header ("icns" + total
// length), then 4-byte type + 4-byte length + payload per icon.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'assets', 'TeXLocal.icns');
const DEST = path.join(ROOT, 'assets', 'TeXLocal.png');

// PNG-bearing icns types, by pixel size.
const SIZES = {
  icp4: 16, icp5: 32, icp6: 64, ic07: 128, ic08: 256, ic09: 512, ic10: 1024,
  ic11: 32, ic12: 64, ic13: 256, ic14: 512, // @2x retina variants
};
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

const buf = fs.readFileSync(SRC);
if (buf.toString('ascii', 0, 4) !== 'icns') throw new Error('not an icns file');

let best = null;
for (let off = 8; off + 8 <= buf.length;) {
  const type = buf.toString('ascii', off, off + 4);
  const len = buf.readUInt32BE(off + 4);
  if (len < 8 || off + len > buf.length) break;
  const data = buf.subarray(off + 8, off + len);
  const size = SIZES[type];
  if (size && data.subarray(0, 4).equals(PNG_MAGIC) && (!best || size > best.size)) {
    best = { type, size, data };
  }
  off += len;
}

if (!best) throw new Error('no PNG icon found in icns');
fs.writeFileSync(DEST, best.data);
console.log(`extracted ${best.type} (${best.size}px, ${best.data.length} bytes) -> ${path.relative(ROOT, DEST)}`);
