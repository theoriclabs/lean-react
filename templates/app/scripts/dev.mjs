// Loopback development: http://127.0.0.1:4270, database in .lake/{{name}}.sqlite.
process.env.LEANAPP_DEVELOPMENT = '1';
await import('../gateway/serve.mjs');
