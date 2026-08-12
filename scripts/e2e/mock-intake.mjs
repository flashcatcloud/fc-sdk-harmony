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

/** Stand-in origin server: never treated as intake traffic. */
function serveOrigin(req, res) {
  fs.appendFileSync(requestsFile, `${JSON.stringify({
    url: req.url, method: req.method, headers: req.headers
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
    req.resume();
    req.on('end', () => serveOrigin(req, res));
    return;
  }
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    let body = Buffer.concat(chunks);
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
    console.log(`${req.method} ${req.url} encoding=${encoding || 'none'} events=${lines.length}`);
    res.writeHead(202, { 'content-type': 'application/json' }).end('{}');
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`mock intake listening on :${port} -> ${captureFile}`);
});
