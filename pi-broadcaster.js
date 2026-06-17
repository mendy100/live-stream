#!/usr/bin/env node
// Raspberry Pi headless broadcaster
// Captures audio from USB device (e.g. Focusrite Scarlett 2i2) and streams to server
//
// Usage: STREAM_URL=https://your-server.com CHANNEL_ID=abc123 BROADCAST_KEY=xyz node pi-broadcaster.js
// Optional: DEVICE=hw:1,0  (ALSA device, default auto-detect USB)
//           SAMPLE_RATE=48000  (capture rate, default 48000)

const { spawn } = require('child_process');
const { io } = require('socket.io-client');

const STREAM_URL = process.env.STREAM_URL || 'https://live-stream-it4q.onrender.com';
const CHANNEL_ID = process.env.CHANNEL_ID;
const BROADCAST_KEY = process.env.BROADCAST_KEY;
const DEVICE = process.env.DEVICE || '';
const CAPTURE_RATE = parseInt(process.env.SAMPLE_RATE) || 48000;
const TARGET_RATE = 16000;

if (!CHANNEL_ID || !BROADCAST_KEY) {
  console.error('Missing CHANNEL_ID or BROADCAST_KEY');
  console.error('Usage: CHANNEL_ID=abc123 BROADCAST_KEY=xyz node pi-broadcaster.js');
  process.exit(1);
}

function findUSBDevice() {
  if (DEVICE) return DEVICE;
  try {
    const { execSync } = require('child_process');
    const cards = execSync('cat /proc/asound/cards', { encoding: 'utf8' });
    const lines = cards.split('\n');
    for (const line of lines) {
      if (line.includes('USB') || line.includes('Scarlett') || line.includes('Focusrite')) {
        const match = line.match(/^\s*(\d+)/);
        if (match) return `hw:${match[1]},0`;
      }
    }
  } catch (e) {}
  return 'hw:1,0';
}

function stereoToMono(pcm16Buffer) {
  const frames = Math.floor(pcm16Buffer.length / 4); // 2 bytes * 2 channels per frame
  const out = Buffer.alloc(frames * 2);
  for (let i = 0; i < frames; i++) {
    const left = pcm16Buffer.readInt16LE(i * 4);
    const right = pcm16Buffer.readInt16LE(i * 4 + 2);
    const mono = Math.round((left + right) / 2);
    out.writeInt16LE(Math.max(-32768, Math.min(32767, mono)), i * 2);
  }
  return out;
}

function downsample(pcm16Buffer, fromRate, toRate) {
  const ratio = Math.round(fromRate / toRate);
  if (ratio <= 1) return pcm16Buffer;
  const samples = pcm16Buffer.length / 2;
  const outSamples = Math.floor(samples / ratio);
  const out = Buffer.alloc(outSamples * 2);
  for (let i = 0; i < outSamples; i++) {
    out.writeInt16LE(pcm16Buffer.readInt16LE(i * ratio * 2), i * 2);
  }
  return out;
}

function start() {
  const device = findUSBDevice();
  console.log(`[pi-broadcaster] Device: ${device}`);
  console.log(`[pi-broadcaster] Server: ${STREAM_URL}`);
  console.log(`[pi-broadcaster] Channel: ${CHANNEL_ID}`);
  console.log(`[pi-broadcaster] Capture: ${CAPTURE_RATE}Hz → ${TARGET_RATE}Hz`);

  const socket = io(STREAM_URL, {
    query: { broadcaster: '1', channel: CHANNEL_ID, type: 'pi' },
    transports: ['websocket'],
    reconnection: true,
    reconnectionDelay: 2000,
  });

  let authenticated = false;
  let arecord = null;

  socket.on('connect', () => {
    console.log('[pi-broadcaster] Connected to server');
    socket.emit('start-broadcast', BROADCAST_KEY);
  });

  socket.on('status', (data) => {
    if (data.live) {
      console.log('[pi-broadcaster] Broadcast authenticated - LIVE');
      authenticated = true;
      startCapture();
      startStatusReporting();
    }
  });

  socket.on('auth-error', () => {
    console.error('[pi-broadcaster] Invalid broadcast key!');
    process.exit(1);
  });

  socket.on('listeners', (n) => {
    console.log(`[pi-broadcaster] Listeners: ${n}`);
  });

  socket.on('disconnect', (reason) => {
    console.log(`[pi-broadcaster] Disconnected: ${reason}`);
    authenticated = false;
    stopCapture();
    stopStatusReporting();
  });

  socket.on('reconnect', () => {
    console.log('[pi-broadcaster] Reconnected');
    socket.emit('start-broadcast', BROADCAST_KEY);
  });

  function getNetworkInfo() {
    const { execSync } = require('child_process');
    const info = { type: 'unknown', ip: '', ssid: '', signal: '' };
    try {
      const route = execSync("ip route get 1.1.1.1 2>/dev/null | head -1", { encoding: 'utf8' });
      const ifMatch = route.match(/dev\s+(\S+)/);
      const iface = ifMatch ? ifMatch[1] : '';
      info.ip = (route.match(/src\s+(\S+)/) || [])[1] || '';
      if (iface.startsWith('wlan')) {
        info.type = 'wifi';
        try {
          const iwconfig = execSync(`iwconfig ${iface} 2>/dev/null`, { encoding: 'utf8' });
          info.ssid = (iwconfig.match(/ESSID:"([^"]*)"/) || [])[1] || '';
          info.signal = (iwconfig.match(/Signal level=(-?\d+)/) || [])[1] || '';
        } catch (e) {}
      } else if (iface.startsWith('eth')) {
        info.type = 'ethernet';
      }
    } catch (e) {}
    return info;
  }

  let statusInterval = null;
  function startStatusReporting() {
    const sendStatus = () => {
      const net = getNetworkInfo();
      const uptime = require('os').uptime();
      socket.emit('pi-status', { network: net, uptime, device });
    };
    sendStatus();
    statusInterval = setInterval(sendStatus, 5000);
  }

  function stopStatusReporting() {
    if (statusInterval) { clearInterval(statusInterval); statusInterval = null; }
  }

  function startCapture() {
    if (arecord) return;

    // arecord: capture 16-bit signed LE mono at CAPTURE_RATE
    const args = [
      '-D', device,
      '-f', 'S16_LE',
      '-c', '2',
      '-r', String(CAPTURE_RATE),
      '-t', 'raw',
      '--buffer-size', '1024',
    ];

    console.log(`[pi-broadcaster] Starting arecord: arecord ${args.join(' ')}`);
    arecord = spawn('arecord', args);

    arecord.stdout.on('data', (chunk) => {
      if (!authenticated) return;
      const mono = stereoToMono(chunk);
      const downsampled = downsample(mono, CAPTURE_RATE, TARGET_RATE);
      socket.emit('audio', downsampled);
    });

    arecord.stderr.on('data', (data) => {
      const msg = data.toString().trim();
      if (msg && !msg.includes('overrun')) {
        console.log(`[arecord] ${msg}`);
      }
    });

    arecord.on('close', (code) => {
      console.log(`[pi-broadcaster] arecord exited (code ${code})`);
      arecord = null;
      if (authenticated) {
        console.log('[pi-broadcaster] Restarting capture in 2s...');
        setTimeout(startCapture, 2000);
      }
    });
  }

  function stopCapture() {
    if (arecord) {
      arecord.kill('SIGTERM');
      arecord = null;
    }
  }

  process.on('SIGINT', () => {
    console.log('\n[pi-broadcaster] Shutting down...');
    socket.emit('stop-broadcast');
    stopCapture();
    socket.close();
    process.exit(0);
  });

  process.on('SIGTERM', () => {
    socket.emit('stop-broadcast');
    stopCapture();
    socket.close();
    process.exit(0);
  });
}

start();
