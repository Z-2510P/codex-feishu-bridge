'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const os = require('node:os');
const path = require('node:path');
const { PassThrough, Readable } = require('node:stream');
const test = require('node:test');

const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-feishu-bridge-test-'));
process.env.CODEX_FEISHU_BRIDGE_DATA_ROOT = testRoot;
process.env.CODEX_FEISHU_SESSIONS_DIR = path.join(testRoot, 'sessions');

const bridge = require('../bridge.js');

function writeSession(code, sessionId, project, lastSeenUtc, title = '未命名对话') {
  fs.mkdirSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(process.env.CODEX_FEISHU_SESSIONS_DIR, `${code}.json`),
    JSON.stringify({ schema: 2, code, sessionId, title, project, lastSeenUtc }),
    'utf8',
  );
}

function resetRuntimeFiles() {
  for (const directory of [
    bridge.PATHS.inbox,
    bridge.PATHS.working,
    bridge.PATHS.processed,
    bridge.PATHS.deadLetter,
    bridge.PATHS.outbox,
    bridge.PATHS.sent,
    bridge.PATHS.inboundMedia,
    bridge.PATHS.outboundMedia,
  ]) {
    fs.mkdirSync(directory, { recursive: true });
    for (const name of fs.readdirSync(directory)) fs.rmSync(path.join(directory, name), { recursive: true, force: true });
  }
}

class FakeChannel {
  constructor() {
    this.sent = [];
  }

  async send(to, input, options) {
    this.sent.push({ to, input, options });
    return { messageId: `fake-${this.sent.length}` };
  }
}

test.after(() => {
  fs.rmSync(testRoot, { recursive: true, force: true });
});

test('command parsing supports pairing, routing, and plain prompts', () => {
  assert.deepEqual(bridge.parseCommand('/pair ABCD-2345'), { type: 'pair', code: 'ABCD-2345' });
  assert.deepEqual(bridge.parseCommand('/use a72f19c304'), { type: 'use', code: 'A72F19C304' });
  assert.deepEqual(bridge.parseCommand('#A72F19C304 continue the task'), {
    type: 'prompt',
    code: 'A72F19C304',
    prompt: 'continue the task',
  });
  assert.deepEqual(bridge.parseCommand('continue'), { type: 'prompt', code: null, prompt: 'continue' });
});

test('prompt and response limits are deterministic', () => {
  assert.equal(bridge.sanitizePrompt(`a\u0000b`), 'ab');
  assert.equal(bridge.sanitizePrompt('x'.repeat(13000)).length, 12000);
  assert.match(bridge.clipResponse('x'.repeat(9000)), /手机端截断/);
});

test('pairing hashes compare without storing the pairing code', () => {
  const hash = bridge.pairingHash('ABCD2345');
  assert.equal(hash, bridge.sha256('ABCD2345'));
  assert.equal(bridge.timingSafeTextEqual(hash, bridge.pairingHash('abcd2345')), true);
  assert.equal(bridge.timingSafeTextEqual(hash, bridge.pairingHash('wrong')), false);
});

test('Codex arguments enforce workspace sandboxing without bypass flags', () => {
  const args = bridge.buildCodexArgs('session-id', 'result.txt', ['C:\\temp\\input.png']);
  assert.deepEqual(args.slice(0, 2), ['exec', 'resume']);
  assert.ok(args.includes('sandbox_mode="workspace-write"'));
  assert.ok(args.includes('approval_policy="never"'));
  assert.ok(args.includes('session-id'));
  assert.deepEqual(args.slice(args.indexOf('--image'), args.indexOf('--image') + 2), ['--image', 'C:\\temp\\input.png']);
  assert.ok(args.includes('-'));
  assert.equal(args.includes('--dangerously-bypass-approvals-and-sandbox'), false);
  assert.equal(args.includes('--dangerously-bypass-hook-trust'), false);
});

test('session routing selects explicit, active, or single sessions', () => {
  fs.rmSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true, force: true });
  writeSession('A72F19C304', 'session-a', 'alpha', '2026-07-20T01:00:00Z');
  const sessions = bridge.loadSessions();
  const state = bridge.defaultState();
  assert.equal(bridge.resolvePromptTarget('user', null, state, sessions).session.code, 'A72F19C304');
  writeSession('B82F19C305', 'session-b', 'beta', '2026-07-20T02:00:00Z');
  const twoSessions = bridge.loadSessions();
  assert.equal(bridge.resolvePromptTarget('user', null, state, twoSessions).session, null);
  state.activeSessionByUser.user = 'A72F19C304';
  assert.equal(bridge.resolvePromptTarget('user', null, state, twoSessions).session.sessionId, 'session-a');
  assert.equal(bridge.resolvePromptTarget('user', 'B82F19C305', state, twoSessions).session.sessionId, 'session-b');
});

test('app-server thread metadata maps without copying conversation previews', () => {
  const record = bridge.threadToSessionRecord({
    id: 'thread-secret-id',
    cwd: 'C:\\private\\alpha-project',
    name: 'Build the alpha dashboard',
    preview: 'full user conversation preview must not be stored',
    recencyAt: 1784491200,
  });
  assert.equal(record.project, 'alpha-project');
  assert.equal(record.title, 'Build the alpha dashboard');
  assert.equal(record.sessionId, 'thread-secret-id');
  assert.equal(Object.prototype.hasOwnProperty.call(record, 'preview'), false);
  assert.equal(record.code.length, 10);
});

test('conversation titles are single-line, escaped, and bounded', () => {
  assert.equal(bridge.safeThreadTitle('  hello\n<world>&  '), 'hello _world__');
  assert.equal(bridge.safeThreadTitle(''), '未命名对话');
  assert.equal(bridge.safeThreadTitle('x'.repeat(100)).length, 80);
});

test('image validation accepts supported signatures and rejects arbitrary bytes', () => {
  assert.equal(bridge.detectImageExtension(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), '.png');
  assert.equal(bridge.detectImageExtension(Buffer.from([0xff, 0xd8, 0xff, 0x00])), '.jpg');
  assert.equal(bridge.detectImageExtension(Buffer.from('not an image')), null);
  const resources = Array.from({ length: 6 }, (_, index) => ({ type: 'image', fileKey: `key-${index}` }));
  assert.equal(bridge.normalizeInboundImages(resources).length, 4);
});

test('outbound images must be explicit, valid, and inside the session workspace', () => {
  const workspace = path.join(testRoot, 'workspace-images');
  fs.mkdirSync(workspace, { recursive: true });
  const valid = path.join(workspace, 'generated.png');
  const outside = path.join(testRoot, 'outside.png');
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);
  fs.writeFileSync(valid, png);
  fs.writeFileSync(outside, png);
  const result = bridge.prepareCodexResult(
    `done ![generated](<${valid}>) ![outside](<${outside}>)`,
    workspace,
  );
  assert.deepEqual(result.imagePaths, [path.resolve(valid)]);
  assert.match(result.text, /图片已发送/);
  assert.match(result.text, /图片未发送/);
  const trustedGeneratedRoot = path.join(testRoot, 'trusted-visualizations');
  fs.mkdirSync(trustedGeneratedRoot, { recursive: true });
  const generated = path.join(trustedGeneratedRoot, 'generated-by-codex.png');
  fs.writeFileSync(generated, png);
  const generatedResult = bridge.prepareCodexResult(
    `![generated](<${generated}>)`,
    workspace,
    [trustedGeneratedRoot],
  );
  assert.deepEqual(generatedResult.imagePaths, [path.resolve(generated)]);
  const bareResult = bridge.prepareCodexResult(`saved at ${valid}`, workspace);
  assert.deepEqual(bareResult.imagePaths, [path.resolve(valid)]);
  assert.equal(bareResult.text.includes(valid), false);
});

test('inbound images are stored under randomized local names after signature validation', async () => {
  resetRuntimeFiles();
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]);
  const paths = await bridge.storeInboundImages(
    { messageId: 'message-image-store', images: [{ type: 'image', fileKey: 'key-secret' }] },
    async () => png,
  );
  assert.equal(paths.length, 1);
  assert.equal(path.dirname(paths[0]), bridge.PATHS.inboundMedia);
  assert.equal(path.extname(paths[0]), '.png');
  assert.equal(path.basename(paths[0]).includes('key-secret'), false);
  assert.deepEqual(fs.readFileSync(paths[0]), png);
  await assert.rejects(
    bridge.storeInboundImages(
      { messageId: 'message-image-large', images: [{ type: 'image', fileKey: 'large' }] },
      async () => Buffer.alloc(10 * 1024 * 1024 + 1, 0x89),
    ),
    /image_size_invalid/,
  );
});

test('user images are fetched through the message-resource API', async () => {
  const calls = [];
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const channel = {
    rawClient: {
      im: { v1: { messageResource: { get: async (payload) => {
        calls.push(payload);
        return { getReadableStream: () => Readable.from([png]) };
      } } } },
    },
  };
  const downloaded = await bridge.fetchMessageImage(channel, 'message-id', 'image-key');
  assert.deepEqual(downloaded, png);
  assert.deepEqual(calls[0], {
    params: { type: 'image' },
    path: { message_id: 'message-id', file_key: 'image-key' },
  });
});

test('session list shows title, project, code, and update time', () => {
  const text = bridge.formatSessionList([{
    code: 'A72F19C304',
    sessionId: 'session-a',
    title: 'Fix login flow',
    project: 'alpha',
    lastSeenUtc: '2026-07-20T01:00:00Z',
  }]);
  assert.match(text, /Fix login flow/);
  assert.match(text, /A72F19C304 \| alpha/);
});

test('global completion watcher baselines history and emits only newly completed turns', async () => {
  const rolloutRoot = path.join(testRoot, 'watch-rollouts');
  const statePath = path.join(testRoot, 'watch-state.json');
  fs.mkdirSync(rolloutRoot, { recursive: true });
  const sessionId = '11111111-2222-3333-4444-555555555555';
  const rollout = path.join(rolloutRoot, `rollout-test-${sessionId}.jsonl`);
  const historical = JSON.stringify({
    type: 'event_msg',
    payload: { type: 'task_complete', turn_id: 'old-turn', last_agent_message: 'private old response' },
  });
  fs.writeFileSync(rollout, `${historical}\n`, 'utf8');
  const events = [];
  const watcher = new bridge.CompletionWatcher(async (event) => events.push(event), {
    sessionsRoot: rolloutRoot,
    statePath,
    intervalMs: 100000,
  });
  await watcher.initialize();
  assert.equal(events.length, 0);
  const completed = JSON.stringify({
    timestamp: '2026-07-21T02:00:03Z',
    type: 'event_msg',
    payload: {
      type: 'task_complete',
      turn_id: 'new-turn',
      started_at: '2026-07-21T02:00:00Z',
      completed_at: '2026-07-21T02:00:03Z',
      last_agent_message: 'private final response must not enter watcher state',
    },
  });
  fs.appendFileSync(rollout, `${completed}\n`, 'utf8');
  await watcher.scan();
  assert.deepEqual(events, [{
    sessionId,
    turnId: 'new-turn',
    startedAt: '2026-07-21T02:00:00Z',
    completedAt: '2026-07-21T02:00:03Z',
    finalResponse: 'private final response must not enter watcher state',
  }]);
  assert.equal(fs.readFileSync(statePath, 'utf8').includes('private final response'), false);
  const resumedEvents = [];
  const resumed = new bridge.CompletionWatcher(async (event) => resumedEvents.push(event), {
    sessionsRoot: rolloutRoot,
    statePath,
  });
  await resumed.initialize();
  assert.equal(resumedEvents.length, 0);
});

test('global completion notification includes the final assistant response', () => {
  const message = bridge.formatCompletionMessage({
    code: 'A72F19C304',
    title: 'Build notifier',
    project: 'alpha',
  }, '2026-07-21T02:00:03Z', 'The requested work is complete.');
  assert.match(message, /标题：Build notifier/);
  assert.match(message, /对话：A72F19C304/);
  assert.match(message, /回复：\nThe requested work is complete\./);
});

test('global notification chat is independent of the active routed conversation', () => {
  const state = bridge.defaultState();
  state.allowedOpenIds = ['paired-user'];
  state.defaultChatByUser['paired-user'] = 'fixed-feishu-chat';
  state.activeSessionByUser['paired-user'] = 'AAAAAA1111';
  assert.equal(bridge.getPairedChatId(state), 'fixed-feishu-chat');
  state.activeSessionByUser['paired-user'] = 'BBBBBB2222';
  assert.equal(bridge.getPairedChatId(state), 'fixed-feishu-chat');
});

test('Feishu-initiated Codex turns suppress their duplicate global completion', () => {
  const now = Date.now();
  bridge.markRemoteSessionStarted('remote-session', now - 1000);
  bridge.markRemoteSessionClosed('remote-session', now);
  assert.equal(bridge.shouldSuppressWatchedCompletion(
    'remote-session',
    new Date(now - 900).toISOString(),
    new Date(now - 100).toISOString(),
  ), true);
  assert.equal(bridge.shouldSuppressWatchedCompletion(
    'remote-session',
    new Date(now - 900).toISOString(),
    new Date(now - 100).toISOString(),
  ), false);
});

test('app-server listing performs initialize then a metadata-only thread list', async () => {
  const requests = [];
  const fakeSpawn = () => {
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.stdin = new PassThrough();
    child.kill = () => {};
    let buffer = '';
    child.stdin.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        const request = JSON.parse(line);
        requests.push(request);
        if (request.method === 'initialize') {
          child.stdout.write(`${JSON.stringify({ id: 1, result: { userAgent: 'test' } })}\n`);
        }
        if (request.method === 'thread/list') {
          child.stdout.write(`${JSON.stringify({ id: 2, result: { data: [{ id: 'thread-1', cwd: 'C:\\repo\\one' }] } })}\n`);
        }
      }
    });
    return child;
  };
  const threads = await bridge.listCodexThreads({ spawnImpl: fakeSpawn, timeoutMs: 1000 });
  assert.equal(threads.length, 1);
  assert.equal(requests[0].method, 'initialize');
  assert.equal(requests[1].method, 'initialized');
  assert.equal(requests[2].method, 'thread/list');
  assert.equal(requests[2].params.limit, 100);
  assert.deepEqual(requests[2].params.sourceKinds, []);
});

test('pairing authorizes only the account presenting the local code', async () => {
  resetRuntimeFiles();
  const state = bridge.defaultState();
  state.pairing = {
    hash: bridge.pairingHash('PAIR2345'),
    expiresAtUtc: new Date(Date.now() + 60000).toISOString(),
  };
  bridge.saveState(state);
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, { runCodex: async () => 'unused' });
  runtime.enqueueMessage({
    messageId: 'message-pair',
    chatId: 'chat-1',
    chatType: 'p2p',
    senderId: 'open-user-1',
    content: '/pair PAIR2345',
    rawContentType: 'text',
  });
  await runtime.tick();
  const paired = bridge.loadState();
  assert.deepEqual(paired.allowedOpenIds, ['open-user-1']);
  assert.equal(paired.defaultChatByUser['open-user-1'], 'chat-1');
  assert.equal(paired.pairing, null);
  assert.match(channel.sent[0].input.text, /配对成功/);
});

test('unauthorized prompts never invoke Codex', async () => {
  resetRuntimeFiles();
  bridge.saveState(bridge.defaultState());
  let runs = 0;
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    runCodex: async () => {
      runs += 1;
      return 'should not run';
    },
  });
  runtime.enqueueMessage({
    messageId: 'message-unauthorized',
    chatId: 'chat-2',
    chatType: 'p2p',
    senderId: 'not-allowed',
    content: 'modify files',
    rawContentType: 'text',
  });
  await runtime.tick();
  assert.equal(runs, 0);
  assert.match(channel.sent[0].input.text, /尚未授权/);
});

test('unauthorized images are rejected without downloading the resource', async () => {
  resetRuntimeFiles();
  bridge.saveState(bridge.defaultState());
  let downloads = 0;
  let runs = 0;
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    fetchImage: async () => { downloads += 1; return Buffer.alloc(0); },
    runCodex: async () => { runs += 1; return 'unused'; },
  });
  runtime.enqueueMessage({
    messageId: 'message-unauthorized-image',
    chatId: 'chat-image',
    chatType: 'p2p',
    senderId: 'not-allowed',
    content: '![image](secret-key)',
    rawContentType: 'image',
    resources: [{ type: 'image', fileKey: 'secret-key' }],
  });
  await runtime.tick();
  assert.equal(downloads, 0);
  assert.equal(runs, 0);
});

test('authorized Feishu images are downloaded and attached to the resumed Codex turn', async () => {
  resetRuntimeFiles();
  fs.rmSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true, force: true });
  writeSession('A72F19C304', 'session-a', 'alpha', new Date().toISOString(), 'Image task');
  const state = bridge.defaultState();
  state.allowedOpenIds = ['allowed-image-user'];
  state.activeSessionByUser['allowed-image-user'] = 'A72F19C304';
  state.defaultChatByUser['allowed-image-user'] = 'chat-image';
  bridge.saveState(state);
  const calls = [];
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]);
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    fetchImage: async () => png,
    resolveWorkspace: async () => testRoot,
    runCodex: async (session, prompt, options) => {
      calls.push({ session, prompt, options });
      return { text: 'image analyzed', imagePaths: [] };
    },
  });
  runtime.enqueueMessage({
    messageId: 'message-authorized-image',
    chatId: 'chat-image',
    chatType: 'p2p',
    senderId: 'allowed-image-user',
    content: '![image](image-key)',
    rawContentType: 'image',
    resources: [{ type: 'image', fileKey: 'image-key' }],
  });
  assert.equal(channel.sent[0].input.text, '图片已收到。请在 60 秒内发送说明；未发送说明时将自动分析。');
  runtime.enqueueMessage({
    messageId: 'message-authorized-image-instruction',
    chatId: 'chat-image',
    chatType: 'p2p',
    senderId: 'allowed-image-user',
    content: 'describe the screenshot',
    rawContentType: 'text',
  });
  await runtime.tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.imagePaths.length, 1);
  assert.equal(fs.existsSync(calls[0].options.imagePaths[0]), true);
  assert.equal(calls[0].prompt, 'describe the screenshot');
  assert.equal(channel.sent.at(-1).input.text, 'image analyzed');
});

test('image-only messages wait, then run automatically after the deadline', async () => {
  resetRuntimeFiles();
  fs.rmSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true, force: true });
  writeSession('A72F19C304', 'session-a', 'alpha', new Date().toISOString(), 'Image timeout');
  const state = bridge.defaultState();
  state.allowedOpenIds = ['timeout-user'];
  state.activeSessionByUser['timeout-user'] = 'A72F19C304';
  bridge.saveState(state);
  const calls = [];
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]);
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    fetchImage: async () => png,
    resolveWorkspace: async () => testRoot,
    runCodex: async (_session, prompt, options) => {
      calls.push({ prompt, options });
      return 'automatic image analysis';
    },
  });
  runtime.enqueueMessage({
    messageId: 'message-timeout-image',
    chatId: 'chat-timeout',
    chatType: 'p2p',
    senderId: 'timeout-user',
    content: '![image](timeout-key)',
    rawContentType: 'image',
    resources: [{ type: 'image', fileKey: 'timeout-key' }],
  });
  await runtime.tick();
  assert.equal(calls.length, 0);
  const pendingPath = path.join(bridge.PATHS.inbox, fs.readdirSync(bridge.PATHS.inbox)[0]);
  const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
  pending.notBeforeUtc = new Date(Date.now() - 1000).toISOString();
  fs.writeFileSync(pendingPath, JSON.stringify(pending), 'utf8');
  await runtime.tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].prompt, '请分析我从飞书发送的图片。');
  assert.equal(calls[0].options.imagePaths.length, 1);
  assert.equal(channel.sent.at(-1).input.text, 'automatic image analysis');
});
test('authorized prompts resume the selected session and return only the final response', async () => {
  resetRuntimeFiles();
  fs.rmSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true, force: true });
  writeSession('A72F19C304', 'session-a', 'alpha', new Date().toISOString());
  const state = bridge.defaultState();
  state.allowedOpenIds = ['allowed-user'];
  state.activeSessionByUser['allowed-user'] = 'A72F19C304';
  state.defaultChatByUser['allowed-user'] = 'chat-3';
  bridge.saveState(state);
  const calls = [];
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    resolveWorkspace: async () => testRoot,
    runCodex: async (session, prompt) => {
      calls.push({ session, prompt });
      return 'final Codex response';
    },
  });
  runtime.enqueueMessage({
    messageId: 'message-authorized',
    chatId: 'chat-3',
    chatType: 'p2p',
    senderId: 'allowed-user',
    content: 'continue safely',
    rawContentType: 'text',
  });
  await runtime.tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].session.sessionId, 'session-a');
  assert.match(calls[0].prompt, /^continue safely/);
  assert.equal(channel.sent.length, 1);
  assert.equal(channel.sent[0].input.text, 'final Codex response');
});

test('Codex image results are uploaded through the same Feishu bot', async () => {
  resetRuntimeFiles();
  fs.rmSync(process.env.CODEX_FEISHU_SESSIONS_DIR, { recursive: true, force: true });
  writeSession('A72F19C304', 'session-a', 'alpha', new Date().toISOString(), 'Generate image');
  const state = bridge.defaultState();
  state.allowedOpenIds = ['allowed-user'];
  state.activeSessionByUser['allowed-user'] = 'A72F19C304';
  bridge.saveState(state);
  const outputImage = path.join(testRoot, 'outbound.png');
  fs.writeFileSync(outputImage, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]));
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, {
    resolveWorkspace: async () => testRoot,
    runCodex: async () => ({ text: 'generated', imagePaths: [outputImage] }),
  });
  runtime.enqueueMessage({
    messageId: 'message-generate-image',
    chatId: 'chat-3',
    chatType: 'p2p',
    senderId: 'allowed-user',
    content: 'generate an image',
    rawContentType: 'text',
  });
  await runtime.tick();
  const imageSend = channel.sent.find((item) => item.input.image);
  assert.equal(imageSend.input.image.source, outputImage);
  assert.equal(imageSend.to, 'chat-3');
});

test('completion outbox uses the same application bot channel', async () => {
  resetRuntimeFiles();
  fs.writeFileSync(
    path.join(bridge.PATHS.outbox, 'completion.json'),
    JSON.stringify({
      schema: 1,
      kind: 'completion',
      eventKey: 'abc123',
      targetChatId: 'chat-completion',
      conversationCode: 'A72F19C304',
      message: '[Codex] done',
    }),
    'utf8',
  );
  const channel = new FakeChannel();
  const runtime = new bridge.BridgeRuntime(channel, { runCodex: async () => 'unused' });
  await runtime.tick();
  assert.equal(channel.sent[0].to, 'chat-completion');
  assert.equal(channel.sent[0].input.text, '[Codex] done');
  assert.equal(fs.readdirSync(bridge.PATHS.outbox).length, 0);
});

test('global completion outbox uploads staged images without repeating sent text on retry', async () => {
  resetRuntimeFiles();
  fs.mkdirSync(bridge.PATHS.outboundMedia, { recursive: true });
  const imagePath = path.join(bridge.PATHS.outboundMedia, 'completion-image.png');
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]));
  const jobPath = path.join(bridge.PATHS.outbox, 'completion-with-image.json');
  fs.writeFileSync(jobPath, JSON.stringify({
    schema: 1,
    kind: 'completion',
    eventKey: 'completion-with-image',
    targetChatId: 'chat-completion',
    conversationCode: 'A72F19C304',
    message: '[Codex] done with image',
    imagePaths: [imagePath],
    textSent: false,
    nextImageIndex: 0,
  }), 'utf8');
  class FlakyImageChannel extends FakeChannel {
    constructor() {
      super();
      this.failedOnce = false;
    }

    async send(to, input, options) {
      if (input.image && !this.failedOnce) {
        this.failedOnce = true;
        throw new Error('temporary image failure');
      }
      return super.send(to, input, options);
    }
  }
  const channel = new FlakyImageChannel();
  const runtime = new bridge.BridgeRuntime(channel, { runCodex: async () => 'unused' });
  await assert.rejects(runtime.processOutboxFile(jobPath), /temporary image failure/);
  assert.equal(JSON.parse(fs.readFileSync(jobPath, 'utf8')).textSent, true);
  await runtime.processOutboxFile(jobPath);
  assert.equal(channel.sent.filter((item) => item.input.text).length, 1);
  assert.equal(channel.sent.filter((item) => item.input.image).length, 1);
  assert.equal(fs.existsSync(imagePath), false);
  assert.equal(fs.existsSync(jobPath), false);
});
