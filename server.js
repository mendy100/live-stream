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
const BROADCAST_KEY = process.env.BROADCAST_KEY || 'go-live';

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
  console.log(`  Broadcast page:   http://localhost:${PORT}/broadcast.html`);
  console.log(`  Broadcast key:    ${BROADCAST_KEY}\n`);
});
