#!/usr/bin/env node
/**
 * Mock FlashCat intake for emulator E2E: accepts POST /api/v2/*, decompresses
 * deflate/gzip bodies, appends each NDJSON line to the capture file, and
 * replies 202 — the emulator reaches it at http://10.0.2.2:<port>.
 *
 * Also serves /e2e/* as a stand-in origin server for network instrumentation
 * scenarios, recording each request's headers to <captureFile>.requests so the
 * assertions can compare the traceparent that actually left the device against
 * the resource event the SDK reported for it.
 *
 * Usage: node mock-intake.mjs <port> <captureFile>
 */
import http from 'node:http';
import fs from 'node:fs';
import zlib from 'node:zlib';

const port = Number(process.argv[2] ?? '19533');
const captureFile = process.argv[3] ?? '/tmp/flashcat-e2e-capture.ndjson';
const requestsFile = `${captureFile}.requests`;

/**
 * Shared uplink budget, in bytes per second. Unset (the default) means no
 * throttling at all, so the existing smoke runs are untouched.
 *
 * Set it to model a narrow uplink: every request body on this server — SDK
 * uploads and the stand-in origin's traffic alike — draws from ONE FIFO token
 * bucket. That is the property under test. A per-connection limiter would let
 * each flow have its own pipe, which is precisely the contention we are trying
 * to reproduce, so the bucket must be shared and it must be first-come.
 *
 * The FIFO ordering is what produces the effect an app actually feels: a small
 * request that arrives behind a large upload waits for the upload's bytes to
 * drain before its own are served, the same way a packet queues behind a
 * saturated radio buffer.
 */
const uplinkBps = Number(process.env.UPLINK_BPS ?? '0');
const uplinkBytesPerSec = uplinkBps > 0 ? uplinkBps / 8 : 0;

/**
 * Wall-clock instant the shared uplink finishes everything already queued on it.
 *
 * This models a link, not a quota. A token bucket sized to one second of bytes
 * was the first attempt and it measured nothing: the bucket starts full, so a
 * 16 KB request drew 16 KB instantly and never waited. Real links have no such
 * burst credit — they serialize bytes at the line rate, and a request that
 * arrives while another is still transmitting waits for it to finish.
 *
 * That queueing IS the effect under test, so it has to be the thing modelled:
 * every body on this server, SDK upload and app request alike, is transmitted
 * first-come on one link.
 */
let linkFreeAtMs = Date.now();

/** Resolves once `bytes` have been transmitted on the shared link. */
function transmit(bytes) {
  if (uplinkBytesPerSec <= 0) return Promise.resolve();
  const now = Date.now();
  const startMs = Math.max(now, linkFreeAtMs);
  linkFreeAtMs = startMs + (bytes / uplinkBytesPerSec) * 1000;
  return new Promise((resolve) => setTimeout(resolve, Math.ceil(linkFreeAtMs - now)));
}

/**
 * Reads a request body at no more than the shared uplink rate. The socket is
 * paused while waiting, so backpressure reaches the client the way a real
 * bottleneck would rather than the body landing instantly in a kernel buffer.
 */
async function readThrottled(req) {
  const chunks = [];
  for await (const chunk of req) {
    if (uplinkBytesPerSec > 0) {
      req.pause();
      await transmit(chunk.length);
      req.resume();
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** Stand-in origin server: never treated as intake traffic. */
function serveOrigin(req, res, bodyBytes) {
  fs.appendFileSync(requestsFile, `${JSON.stringify({
    url: req.url, method: req.method, headers: req.headers, bodyBytes
  })}\n`);
  const status = req.url.startsWith('/e2e/status/')
    ? Number(req.url.slice('/e2e/status/'.length)) || 200
    : 200;
  console.log(`origin ${req.method} ${req.url} -> ${status}`);
  res.writeHead(status, { 'content-type': 'application/json' })
    .end(JSON.stringify({ echo: true, path: req.url }));
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/e2e/')) {
    // Same bucket as the intake: the stand-in origin is the app's own request,
    // and the whole point is that it competes with SDK uploads for one uplink.
    readThrottled(req)
      .then((body) => serveOrigin(req, res, body.length))
      .catch(() => res.writeHead(500).end('{}'));
    return;
  }
  readThrottled(req).then((raw) => {
    let body = raw;
    const encoding = (req.headers['content-encoding'] ?? '').toLowerCase();
    try {
      if (encoding === 'deflate') body = zlib.inflateSync(body);
      else if (encoding === 'gzip') body = zlib.gunzipSync(body);
    } catch (e) {
      console.error(`decompress failed (${encoding}): ${e.message}`);
      res.writeHead(400).end('{}');
      return;
    }
    const lines = body.toString('utf8').split('\n').filter((l) => l.length > 0);
    fs.appendFileSync(captureFile, lines.join('\n') + (lines.length ? '\n' : ''));
    console.log(`${req.method} ${req.url} encoding=${encoding || 'none'} events=${lines.length} bytes=${raw.length}`);
    res.writeHead(202, { 'content-type': 'application/json' }).end('{}');
  }).catch(() => res.writeHead(500).end('{}'));
});

server.listen(port, '0.0.0.0', () => {
  console.log(`mock intake listening on :${port} -> ${captureFile}`);
});
