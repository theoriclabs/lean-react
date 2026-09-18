#!/usr/bin/env node
// Process-boundary fixture only, never shipped in the deployment snapshot.
import { createServer } from 'node:http';
createServer((req, res) => {
  if (req.url === '/api/recipes/delete') { process.exit(7); }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(req.url === '/api/manifest' ? '{"operations":[]}' : '{"ready":true}');
}).listen(Number(process.env.LEANAPP_BACKEND_PORT), '127.0.0.1');
