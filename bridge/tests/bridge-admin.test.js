'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const admin = require('../bridge-admin.js');

test('macOS pairing helper stores only a hash and expiry', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-feishu-admin-'));
  try {
    const code = admin.newPairingCode();
    assert.match(code, /^[A-HJ-NP-Z2-9]{8}$/);
    const state = admin.normalizeState({});
    state.pairing = {
      hash: crypto.createHash('sha256').update(code, 'utf8').digest('hex'),
      expiresAtUtc: new Date(Date.now() + 60_000).toISOString(),
    };
    admin.atomicWriteJson(path.join(root, 'state.json'), state);
    const raw = fs.readFileSync(path.join(root, 'state.json'), 'utf8');
    assert.doesNotMatch(raw, new RegExp(code));
    assert.match(JSON.parse(raw).pairing.hash, /^[a-f0-9]{64}$/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('cross-platform status helper tolerates a fresh data directory', () => {
  const state = admin.normalizeState(null);
  assert.deepEqual(state.allowedOpenIds, []);
  assert.deepEqual(state.defaultChatByUser, {});
  assert.deepEqual(state.activeSessionByUser, {});
  assert.equal(state.pairing, null);
});
