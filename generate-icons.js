// Simple script to generate PWA icons as colored squares with text
// Run once: node generate-icons.js

const fs = require('fs');

function createPNG(size) {
  // Minimal valid PNG: solid dark background
  // Using a 1x1 pixel scaled approach won't work for real icons,
  // so we'll create a simple SVG and note that proper icons should be added later

  // For now, create a minimal valid 1x1 PNG as placeholder
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR chunk
  const ihdr = Buffer.alloc(25);
  ihdr.writeUInt32BE(13, 0); // length
  ihdr.write('IHDR', 4);
  ihdr.writeUInt32BE(1, 8);  // width
  ihdr.writeUInt32BE(1, 12); // height
  ihdr.writeUInt8(8, 16);    // bit depth
  ihdr.writeUInt8(2, 17);    // color type (RGB)
  ihdr.writeUInt8(0, 18);    // compression
  ihdr.writeUInt8(0, 19);    // filter
  ihdr.writeUInt8(0, 20);    // interlace

  const { createHash } = require('crypto');
  // CRC of IHDR
  const crc1 = crc32(ihdr.subarray(4, 21));
  ihdr.writeUInt32BE(crc1, 21);

  // IDAT chunk - one red pixel
  const raw = Buffer.from([0, 229, 62, 62]); // filter byte + RGB
  const zlib = require('zlib');
  const compressed = zlib.deflateSync(raw);

  const idat = Buffer.alloc(compressed.length + 12);
  idat.writeUInt32BE(compressed.length, 0);
  idat.write('IDAT', 4);
  compressed.copy(idat, 8);
  const crc2 = crc32(Buffer.concat([Buffer.from('IDAT'), compressed]));
  idat.writeUInt32BE(crc2, 8 + compressed.length);

  // IEND chunk
  const iend = Buffer.from([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);

  return Buffer.concat([signature, ihdr, idat, iend]);
}

// CRC32 for PNG
function crc32(buf) {
  let crc = 0xFFFFFFFF;
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    table[i] = c;
  }
  for (let i = 0; i < buf.length; i++) crc = table[(crc ^ buf[i]) & 0xFF] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

const png = createPNG();
fs.writeFileSync('public/icon-192.png', png);
fs.writeFileSync('public/icon-512.png', png);
console.log('Icons created (placeholder)');
