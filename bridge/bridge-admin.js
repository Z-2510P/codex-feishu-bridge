'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function atomicWriteJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(temporary, filePath);
  try { fs.chmodSync(filePath, 0o600); } catch { }
}

function normalizeState(value) {
  const state = value && typeof value === 'object' ? value : {};
  if (!Array.isArray(state.allowedOpenIds)) state.allowedOpenIds = [];
  if (!state.defaultChatByUser || typeof state.defaultChatByUser !== 'object') state.defaultChatByUser = {};
  if (!state.activeSessionByUser || typeof state.activeSessionByUser !== 'object') state.activeSessionByUser = {};
  if (!state.listSnapshotByUser || typeof state.listSnapshotByUser !== 'object') state.listSnapshotByUser = {};
  if (!Object.prototype.hasOwnProperty.call(state, 'pairing')) state.pairing = null;
  state.schema = Number(state.schema || 1);
  return state;
}

function newPairingCode() {
  const bytes = crypto.randomBytes(8);
  return Array.from(bytes, (value) => alphabet[value % alphabet.length]).join('');
}

function pair(dataRoot) {
  const statePath = path.join(dataRoot, 'state.json');
  const state = normalizeState(readJson(statePath, {}));
  const code = newPairingCode();
  state.pairing = {
    hash: crypto.createHash('sha256').update(code, 'utf8').digest('hex'),
    expiresAtUtc: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
  };
  atomicWriteJson(statePath, state);
  process.stdout.write(`${code}\n`);
}

function status(dataRoot) {
  const state = normalizeState(readJson(path.join(dataRoot, 'state.json'), {}));
  const count = (directory, suffix = '') => {
    try {
      return fs.readdirSync(directory).filter((name) => !suffix || name.endsWith(suffix)).length;
    } catch {
      return 0;
    }
  };
  const result = {
    pairedUsers: state.allowedOpenIds.length,
    pairingExpiresUtc: state.pairing && state.pairing.expiresAtUtc ? state.pairing.expiresAtUtc : null,
    sessions: count(path.join(dataRoot, 'sessions'), '.json'),
    inbox: count(path.join(dataRoot, 'inbox'), '.json'),
    outbox: count(path.join(dataRoot, 'outbox'), '.json'),
    deadLetter: count(path.join(dataRoot, 'dead-letter'), '.json'),
    runtime: readJson(path.join(dataRoot, 'runtime.json'), null),
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

function main(argv) {
  const action = String(argv[2] || '').toLowerCase();
  const dataRoot = path.resolve(argv[3] || process.env.CODEX_FEISHU_BRIDGE_DATA_ROOT || '.');
  if (action === 'pair') return pair(dataRoot);
  if (action === 'status') return status(dataRoot);
  throw new Error('Usage: node bridge-admin.js <pair|status> <data-root>');
}

if (require.main === module) {
  try {
    main(process.argv);
  } catch (error) {
    process.stderr.write(`${error.message || error}\n`);
    process.exitCode = 1;
  }
}

module.exports = { atomicWriteJson, newPairingCode, normalizeState, pair, status };
