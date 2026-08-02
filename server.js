const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');

const app = express();
const server = createServer(app);
const io = new Server(server, { maxHttpBufferSize: 1e6 });

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- Data persistence ---
const DATA_FILE = path.join(__dirname, 'data', 'channels.json');

function ensureDataDir() {
  const dir = path.dirname(DATA_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function loadChannels() {
  ensureDataDir();
  if (!fs.existsSync(DATA_FILE)) return {};
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch (e) { return {}; }
}

function saveChannels(channels) {
  ensureDataDir();
  fs.writeFileSync(DATA_FILE, JSON.stringify(channels, null, 2));
}

function generateId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let id = '';
  for (let i = 0; i < 6; i++) id += chars[Math.floor(Math.random() * chars.length)];
  return id;
}

function generateKey() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let key = '';
  for (let i = 0; i < 12; i++) key += chars[Math.floor(Math.random() * chars.length)];
  return key;
}

// --- Runtime state per channel ---
const channelState = {}; // { [id]: { isLive, listenerCount, streamListeners: [], piStatus: {} } }

function getState(id) {
  if (!channelState[id]) {
    channelState[id] = { isLive: false, listenerCount: 0, streamListeners: [], piStatus: null };
  }
  return channelState[id];
}

// --- WAV header ---
function wavHeader() {
  const buf = Buffer.alloc(44);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(0xFFFFFFFF, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(16000, 24);
  buf.writeUInt32LE(32000, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(0xFFFFFFFF, 40);
  return buf;
}

// --- API: Create channel ---
app.post('/api/channels', (req, res) => {
  const channels = loadChannels();
  const { name } = req.body;

  let id;
  do { id = generateId(); } while (channels[id]);

  const broadcastKey = generateKey();

  channels[id] = {
    id,
    name: (name || 'My Stream').slice(0, 50),
    broadcastKey,
    createdAt: new Date().toISOString(),
    tier: 'free', // future: 'paid'
  };

  saveChannels(channels);
  res.json(channels[id]);
});

// --- API: Get channel info (public, no key) ---
app.get('/api/channels/:id', (req, res) => {
  const channels = loadChannels();
  const ch = channels[req.params.id];
  if (!ch) return res.status(404).json({ error: 'Channel not found' });
  const state = getState(ch.id);
  res.json({
    id: ch.id,
    name: ch.name,
    isLive: state.isLive,
    listeners: state.listenerCount,
  });
});

// --- Pages ---
app.get('/s/:id', (req, res) => {
  const channels = loadChannels();
  if (!channels[req.params.id]) return res.status(404).send('Channel not found');
  res.sendFile(path.join(__dirname, 'public', 'listen.html'));
});

app.get('/s/:id/broadcast', (req, res) => {
  const channels = loadChannels();
  if (!channels[req.params.id]) return res.status(404).send('Channel not found');
  res.sendFile(path.join(__dirname, 'public', 'broadcast.html'));
});

app.get('/s/:id/control', (req, res) => {
  const channels = loadChannels();
  if (!channels[req.params.id]) return res.status(404).send('Channel not found');
  res.sendFile(path.join(__dirname, 'public', 'control.html'));
});

app.get('/s/:id/screen', (req, res) => {
  const channels = loadChannels();
  if (!channels[req.params.id]) return res.status(404).send('Channel not found');
  res.sendFile(path.join(__dirname, 'public', 'screen.html'));
});

// --- Audio stream endpoint ---
app.get('/s/:id/stream', (req, res) => {
  const channels = loadChannels();
  if (!channels[req.params.id]) return res.status(404).send('Channel not found');

  const state = getState(req.params.id);

  res.writeHead(200, {
    'Content-Type': 'audio/wav',
    'Transfer-Encoding': 'chunked',
    'Cache-Control': 'no-cache, no-store',
    'Connection': 'keep-alive',
  });

  res.write(wavHeader());
  state.streamListeners.push(res);

  req.on('close', () => {
    state.streamListeners = state.streamListeners.filter(r => r !== res);
  });
});

// --- Socket.IO ---
io.on('connection', (socket) => {
  const channelId = socket.handshake.query.channel;
  const isBroadcaster = socket.handshake.query.broadcaster === '1';

  if (!channelId) return socket.disconnect();

  const channels = loadChannels();
  if (!channels[channelId]) return socket.disconnect();

  const state = getState(channelId);
  const room = `ch:${channelId}`;
  socket.join(room);

  if (!isBroadcaster) {
    state.listenerCount++;
    io.to(room).emit('listeners', state.listenerCount);
  }

  socket.emit('status', { live: state.isLive });

  socket.on('start-broadcast', (key) => {
    if (key !== channels[channelId].broadcastKey) {
      socket.emit('auth-error');
      return;
    }
    socket.isBroadcaster = true;
    socket.channelId = channelId;
    socket.broadcasterType = socket.handshake.query.type || 'web';
    state.isLive = true;
    io.to(room).emit('status', { live: true, piConnected: !!state.piStatus });
  });

  socket.on('audio', (data) => {
    if (!socket.isBroadcaster) return;
    const st = getState(socket.channelId);
    const buf = Buffer.from(data);
    st.streamListeners.forEach(res => {
      try { res.write(buf); } catch (e) {}
    });
    socket.to(room).emit('audio', data);
  });

  socket.on('pi-status', (info) => {
    if (!socket.isBroadcaster || socket.broadcasterType !== 'pi') return;
    state.piStatus = { ...info, lastSeen: Date.now() };
    io.to(room).emit('pi-status', state.piStatus);
  });

  socket.on('stop-broadcast', () => {
    if (!socket.isBroadcaster) return;
    state.isLive = false;
    io.to(room).emit('status', { live: false });
  });

  socket.on('disconnect', () => {
    if (socket.isBroadcaster) {
      if (socket.broadcasterType === 'pi') {
        state.piStatus = null;
        io.to(room).emit('pi-status', null);
      }
      const hasOtherBroadcasters = [...io.sockets.sockets.values()].some(
        s => s !== socket && s.isBroadcaster && s.channelId === channelId
      );
      if (!hasOtherBroadcasters) {
        state.isLive = false;
        io.to(room).emit('status', { live: false });
      }
    }
    if (!isBroadcaster) {
      state.listenerCount = Math.max(0, state.listenerCount - 1);
      io.to(room).emit('listeners', state.listenerCount);
    }
  });
});

// Seed default channel so it survives Render redeploys
function seedChannels() {
  const channels = loadChannels();
  if (!channels['q4625p']) {
    channels['q4625p'] = {
      id: 'q4625p',
      name: 'My Stream',
      broadcastKey: 'LgPDW26rae8w',
      createdAt: '2026-06-17T00:00:00.000Z',
      tier: 'free',
    };
    saveChannels(channels);
  }
}
seedChannels();

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`\n  Live Stream Platform running on http://localhost:${PORT}\n`);
});
