const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');
const path = require('path');

const app = express();
const server = createServer(app);
const io = new Server(server, { maxHttpBufferSize: 1e6 });

app.use(express.static(path.join(__dirname, 'public')));

let isLive = false;
let listenerCount = 0;
let streamListeners = [];
const BROADCAST_KEY = process.env.BROADCAST_KEY || 'go-live';

// WAV header for 16kHz, 16-bit, mono, streaming (max size)
function wavHeader() {
  const buf = Buffer.alloc(44);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(0xFFFFFFFF, 4);       // file size (unknown/streaming)
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);              // fmt chunk size
  buf.writeUInt16LE(1, 20);              // PCM format
  buf.writeUInt16LE(1, 22);              // mono
  buf.writeUInt32LE(16000, 24);          // sample rate
  buf.writeUInt32LE(32000, 28);          // byte rate (16000 * 2)
  buf.writeUInt16LE(2, 32);              // block align
  buf.writeUInt16LE(16, 34);            // bits per sample
  buf.write('data', 36);
  buf.writeUInt32LE(0xFFFFFFFF, 40);     // data size (unknown/streaming)
  return buf;
}

// HTTP audio stream endpoint — IVR systems and <audio> elements hit this
app.get('/stream', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'audio/wav',
    'Transfer-Encoding': 'chunked',
    'Cache-Control': 'no-cache, no-store',
    'Connection': 'keep-alive',
  });

  res.write(wavHeader());
  streamListeners.push(res);

  req.on('close', () => {
    streamListeners = streamListeners.filter(r => r !== res);
  });
});

io.on('connection', (socket) => {
  if (!socket.handshake.query.broadcaster) {
    listenerCount++;
    io.emit('listeners', listenerCount);
  }

  socket.emit('status', { live: isLive });

  socket.on('start-broadcast', (key) => {
    if (key !== BROADCAST_KEY) {
      socket.emit('auth-error');
      return;
    }
    socket.isBroadcaster = true;
    isLive = true;
    io.emit('status', { live: true });
  });

  socket.on('audio', (data) => {
    if (!socket.isBroadcaster) return;
    // Relay raw PCM bytes to all HTTP stream listeners
    const buf = Buffer.from(data);
    streamListeners.forEach(res => {
      try { res.write(buf); } catch (e) {}
    });
    // Also relay to Socket.IO listeners (broadcast page monitoring)
    socket.broadcast.emit('audio', data);
  });

  socket.on('stop-broadcast', () => {
    if (!socket.isBroadcaster) return;
    isLive = false;
    io.emit('status', { live: false });
  });

  socket.on('disconnect', () => {
    if (socket.isBroadcaster) {
      isLive = false;
      io.emit('status', { live: false });
    }
    if (!socket.handshake.query.broadcaster) {
      listenerCount = Math.max(0, listenerCount - 1);
      io.emit('listeners', listenerCount);
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`\n  Stream server running!\n`);
  console.log(`  Listener page:    http://localhost:${PORT}`);
  console.log(`  Direct stream:    http://localhost:${PORT}/stream`);
  console.log(`  Broadcast page:   http://localhost:${PORT}/broadcast.html`);
  console.log(`  Broadcast key:    ${BROADCAST_KEY}\n`);
});
