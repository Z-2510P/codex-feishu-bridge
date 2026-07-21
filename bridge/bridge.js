'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { fileURLToPath } = require('node:url');
const Lark = require('@larksuiteoapi/node-sdk');

const USER_HOME = os.homedir() || process.env.USERPROFILE || process.env.HOME || process.cwd();
const DEFAULT_DATA_PARENT = process.platform === 'win32'
  ? (process.env.LOCALAPPDATA || process.cwd())
  : path.join(USER_HOME, 'Library', 'Application Support');
const DEFAULT_DATA_ROOT = path.join(DEFAULT_DATA_PARENT, 'CodexFeishuBridge');
const DATA_ROOT = path.resolve(process.env.CODEX_FEISHU_BRIDGE_DATA_ROOT || DEFAULT_DATA_ROOT);
const SESSIONS_DIR = path.resolve(process.env.CODEX_FEISHU_SESSIONS_DIR || path.join(DATA_ROOT, 'sessions'));
const CODEX_HOME = path.resolve(process.env.CODEX_HOME || path.join(USER_HOME, '.codex'));
const CODEX_SESSIONS_ROOT = path.resolve(process.env.CODEX_SESSIONS_ROOT || path.join(CODEX_HOME, 'sessions'));
const CODEX_VISUALIZATIONS_ROOT = path.resolve(path.join(CODEX_HOME, 'visualizations'));
const CODEX_EXE = process.env.CODEX_EXE || 'codex';
const MAX_PROMPT_CHARS = 12000;
const MAX_RESPONSE_CHARS = 8000;
const MAX_IMAGES_PER_TURN = 4;
const PENDING_IMAGE_WAIT_MS = 60 * 1000;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const INBOUND_IMAGE_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_WORKSPACES = new Map();
const REMOTE_SESSION_WINDOWS = new Map();

const PATHS = Object.freeze({
  root: DATA_ROOT,
  state: path.join(DATA_ROOT, 'state.json'),
  inbox: path.join(DATA_ROOT, 'inbox'),
  working: path.join(DATA_ROOT, 'working'),
  processed: path.join(DATA_ROOT, 'processed'),
  deadLetter: path.join(DATA_ROOT, 'dead-letter'),
  outbox: path.join(DATA_ROOT, 'outbox'),
  sent: path.join(DATA_ROOT, 'sent'),
  temp: path.join(DATA_ROOT, 'temp'),
  inboundMedia: path.join(DATA_ROOT, 'media', 'inbound'),
  outboundMedia: path.join(DATA_ROOT, 'media', 'outbound'),
  logs: path.join(DATA_ROOT, 'logs'),
  log: path.join(DATA_ROOT, 'logs', 'bridge.log'),
  pid: path.join(DATA_ROOT, 'bridge.pid'),
  runtime: path.join(DATA_ROOT, 'runtime.json'),
  completionWatch: path.join(DATA_ROOT, 'completion-watch.json'),
});

function ensureDirectories() {
  for (const dir of [
    PATHS.root,
    SESSIONS_DIR,
    PATHS.inbox,
    PATHS.working,
    PATHS.processed,
    PATHS.deadLetter,
    PATHS.outbox,
    PATHS.sent,
    PATHS.temp,
    PATHS.inboundMedia,
    PATHS.outboundMedia,
    PATHS.logs,
  ]) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function sha256(text) {
  return crypto.createHash('sha256').update(String(text), 'utf8').digest('hex');
}

function safeDetail(value) {
  return String(value || '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .slice(0, 240);
}

function safeErrorCodes(error) {
  const values = [];
  let current = error;
  for (let depth = 0; current && depth < 4; depth += 1) {
    for (const value of [
      current.code,
      current.name,
      current.response && current.response.data && current.response.data.code,
      current.response && current.response.data && current.response.data.msg,
    ]) {
      if (value !== undefined && value !== null && String(value).length <= 180) values.push(safeDetail(value));
    }
    current = current.cause;
  }
  return [...new Set(values)].join('>') || 'unknown';
}

function normalizeInboundImages(resources) {
  const images = [];
  const seen = new Set();
  for (const resource of Array.isArray(resources) ? resources : []) {
    if (!resource || resource.type !== 'image') continue;
    const fileKey = String(resource.fileKey || '').trim();
    if (!fileKey || fileKey.length > 512 || seen.has(fileKey)) continue;
    seen.add(fileKey);
    const messageId = String(resource.messageId || '').trim();
    images.push(messageId ? { type: 'image', fileKey, messageId } : { type: 'image', fileKey });
    if (images.length >= MAX_IMAGES_PER_TURN) break;
  }
  return images;
}

function stripInboundImageMarkers(content) {
  return String(content || '')
    .replace(/!\[image\]\([^\r\n)]*\)/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function detectImageExtension(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input || []);
  if (buffer.length >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return '.png';
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return '.jpg';
  if (buffer.length >= 6 && ['GIF87a', 'GIF89a'].includes(buffer.subarray(0, 6).toString('ascii'))) return '.gif';
  if (
    buffer.length >= 12
    && buffer.subarray(0, 4).toString('ascii') === 'RIFF'
    && buffer.subarray(8, 12).toString('ascii') === 'WEBP'
  ) return '.webp';
  return null;
}

async function streamToLimitedBuffer(stream, maxBytes = MAX_IMAGE_BYTES) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    const buffer = Buffer.from(chunk);
    size += buffer.length;
    if (size > maxBytes) {
      if (typeof stream.destroy === 'function') stream.destroy();
      throw new Error('image_too_large');
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks, size);
}

async function fetchMessageImage(channel, messageId, fileKey) {
  const response = await channel.rawClient.im.v1.messageResource.get({
    params: { type: 'image' },
    path: { message_id: messageId, file_key: fileKey },
  });
  return streamToLimitedBuffer(response.getReadableStream());
}

function cleanupMediaDirectory(directory, now = Date.now()) {
  for (const name of fs.readdirSync(directory)) {
    const filePath = path.join(directory, name);
    try {
      const stat = fs.statSync(filePath);
      if (!stat.isFile() || now - stat.mtimeMs > INBOUND_IMAGE_RETENTION_MS) fs.rmSync(filePath, { force: true });
    } catch {
      // Retention cleanup must not interrupt message handling.
    }
  }
}

function cleanupInboundMedia(now = Date.now()) {
  ensureDirectories();
  cleanupMediaDirectory(PATHS.inboundMedia, now);
}

function cleanupOutboundMedia(now = Date.now()) {
  ensureDirectories();
  cleanupMediaDirectory(PATHS.outboundMedia, now);
}

async function storeInboundImages(job, fetchImage) {
  ensureDirectories();
  cleanupInboundMedia();
  cleanupOutboundMedia();
  const stored = [];
  for (const image of normalizeInboundImages(job.images)) {
    const sourceMessageId = image.messageId || job.messageId;
    const downloaded = await fetchImage(sourceMessageId, image.fileKey);
    const buffer = Buffer.isBuffer(downloaded) ? downloaded : Buffer.from(downloaded || []);
    if (!buffer.length || buffer.length > MAX_IMAGE_BYTES) throw new Error('image_size_invalid');
    const extension = detectImageExtension(buffer);
    if (!extension) throw new Error('image_format_unsupported');
    const fileName = `${sha256(`${sourceMessageId}\u0000${image.fileKey}`).slice(0, 32)}${extension}`;
    const filePath = path.join(PATHS.inboundMedia, fileName);
    if (!fs.existsSync(filePath)) fs.writeFileSync(filePath, buffer, { flag: 'wx' });
    stored.push(filePath);
  }
  return stored;
}

function stageOutboundImages(imagePaths, eventKey) {
  ensureDirectories();
  cleanupOutboundMedia();
  const staged = [];
  for (const [index, source] of imagePaths.slice(0, MAX_IMAGES_PER_TURN).entries()) {
    const buffer = fs.readFileSync(source);
    const extension = detectImageExtension(buffer.subarray(0, 12));
    if (!extension || !buffer.length || buffer.length > MAX_IMAGE_BYTES) continue;
    const destination = path.join(PATHS.outboundMedia, `${eventKey}-${index}${extension}`);
    if (!fs.existsSync(destination)) {
      const temporary = path.join(PATHS.outboundMedia, `.${eventKey}-${index}-${crypto.randomUUID()}.tmp`);
      fs.writeFileSync(temporary, buffer, { flag: 'wx' });
      try {
        fs.renameSync(temporary, destination);
      } finally {
        fs.rmSync(temporary, { force: true });
      }
    }
    staged.push(destination);
  }
  return staged;
}

function buildBridgePrompt(prompt, imageCount = 0) {
  return sanitizePrompt(prompt) || (imageCount ? '请分析我从飞书发送的图片。' : '请继续。');
}

function isPathInside(root, candidate) {
  if (!root || !candidate) return false;
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function isPathInsideAny(roots, candidate) {
  return roots.filter(Boolean).some((root) => isPathInside(root, candidate));
}

function normalizeLocalImageTarget(target) {
  let value = String(target || '').trim();
  if (!value) return null;
  try {
    if (/^file:\/\//i.test(value)) value = fileURLToPath(value);
    else if (/^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[a-z]:[\\/]/i.test(value)) return null;
    else value = decodeURIComponent(value);
  } catch {
    return null;
  }
  return path.isAbsolute(value) ? path.resolve(value) : null;
}

function prepareCodexResult(response, workspaceRoot, additionalAllowedRoots = []) {
  const raw = String(response || '');
  const allowedRoots = [workspaceRoot, ...additionalAllowedRoots];
  const imagePaths = [];
  const seen = new Set();
  const registerCandidate = (candidate) => {
    if (!candidate) return 'not-local';
    let accepted = false;
    try {
      if (!isPathInsideAny(allowedRoots, candidate)) throw new Error('image_outside_workspace');
      const stat = fs.statSync(candidate);
      const header = Buffer.alloc(12);
      const handle = fs.openSync(candidate, 'r');
      let bytesRead = 0;
      try {
        bytesRead = fs.readSync(handle, header, 0, header.length, 0);
      } finally {
        fs.closeSync(handle);
      }
      accepted = stat.isFile()
        && stat.size > 0
        && stat.size <= MAX_IMAGE_BYTES
        && Boolean(detectImageExtension(header.subarray(0, bytesRead)));
    } catch {
      accepted = false;
    }
    if (!accepted) return 'rejected';
    if (seen.has(candidate)) return 'accepted';
    if (imagePaths.length >= MAX_IMAGES_PER_TURN) return 'limit';
    seen.add(candidate);
    imagePaths.push(candidate);
    return 'accepted';
  };
  const replacementFor = (status, original) => {
    if (status === 'accepted') return '[图片已发送]';
    if (status === 'limit') return '[图片未发送：每轮最多 4 张]';
    if (status === 'rejected') return '[图片未发送：仅允许当前项目或 Codex 生成目录内不超过 10 MB 的 PNG/JPEG/GIF/WebP 图片]';
    return original;
  };
  const pattern = /!\[[^\]\r\n]*\]\(\s*(?:<([^>\r\n]+)>|([^\r\n)]+))\s*\)/g;
  let cursor = 0;
  let cleaned = '';
  let match;
  while ((match = pattern.exec(raw)) !== null) {
    cleaned += raw.slice(cursor, match.index);
    cursor = pattern.lastIndex;
    const candidate = normalizeLocalImageTarget(match[1] || match[2]);
    if (!candidate) {
      cleaned += match[0];
      continue;
    }
    cleaned += replacementFor(registerCandidate(candidate), match[0]);
  }
  cleaned += raw.slice(cursor);
  const barePathPatterns = process.platform === 'win32'
    ? [/[A-Za-z]:[\\/][^<>\r\n"|?*]*?\.(?:png|jpe?g|gif|webp)/gi]
    : [/(^|[\s(])((?:\/(?:Users|Volumes|private|tmp|var)\/)[^<>\r\n"]*?\.(?:png|jpe?g|gif|webp))/gim];
  for (const barePathPattern of barePathPatterns) {
    cleaned = cleaned.replace(barePathPattern, (...args) => {
      const value = process.platform === 'win32' ? args[0] : args[2];
      const prefix = process.platform === 'win32' ? '' : args[1];
      const candidate = normalizeLocalImageTarget(value);
      return `${prefix}${replacementFor(registerCandidate(candidate), value)}`;
    });
  }
  return {
    text: clipResponse(cleaned.trim() || (imagePaths.length ? 'Codex 已生成图片。' : 'Codex 已完成，但没有返回文本结果。')),
    imagePaths,
  };
}

function rotateLog() {
  try {
    if (!fs.existsSync(PATHS.log) || fs.statSync(PATHS.log).size < 1024 * 1024) return;
    for (let index = 4; index >= 1; index -= 1) {
      const source = `${PATHS.log}.${index}`;
      const target = `${PATHS.log}.${index + 1}`;
      if (fs.existsSync(source)) fs.renameSync(source, target);
    }
    fs.renameSync(PATHS.log, `${PATHS.log}.1`);
  } catch {
    // Logging must not terminate the bridge.
  }
}

function logEvent(level, event, detail = '') {
  try {
    ensureDirectories();
    rotateLog();
    fs.appendFileSync(
      PATHS.log,
      `${JSON.stringify({ at: new Date().toISOString(), level, event, detail: safeDetail(detail) })}\n`,
      'utf8',
    );
  } catch {
    // Logging must not terminate the bridge.
  }
}

function atomicWriteJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  fs.writeFileSync(temporary, JSON.stringify(value), { encoding: 'utf8', flag: 'wx' });
  try {
    fs.renameSync(temporary, filePath);
  } finally {
    if (fs.existsSync(temporary)) fs.rmSync(temporary, { force: true });
  }
}

function writeNewJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  try {
    fs.writeFileSync(filePath, JSON.stringify(value), { encoding: 'utf8', flag: 'wx' });
    return true;
  } catch (error) {
    if (error && error.code === 'EEXIST') return false;
    throw error;
  }
}

function readJson(filePath, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function listRolloutFiles(root = CODEX_SESSIONS_ROOT) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  const pending = [root];
  while (pending.length) {
    const directory = pending.pop();
    let entries = [];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(entryPath);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(entryPath);
    }
  }
  return files.sort();
}

function sessionIdFromRolloutPath(filePath) {
  const match = path.basename(filePath).match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  return match ? match[1] : null;
}

function extractJsonStringField(line, field) {
  const escapedField = String(field).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = String(line).match(new RegExp(`"${escapedField}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"`));
  if (!match) return '';
  try {
    return JSON.parse(`"${match[1]}"`);
  } catch {
    return '';
  }
}

function extractJsonTimestampField(line, field) {
  const stringValue = extractJsonStringField(line, field);
  if (stringValue) return stringValue;
  const escapedField = String(field).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = String(line).match(new RegExp(`"${escapedField}"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)`));
  if (!match) return '';
  const value = Number(match[1]);
  if (!Number.isFinite(value)) return '';
  return new Date(value < 1e12 ? value * 1000 : value).toISOString();
}

function markRemoteSessionStarted(sessionId, startedAt = Date.now()) {
  REMOTE_SESSION_WINDOWS.set(String(sessionId), { startedAt, completedBefore: null });
}

function markRemoteSessionClosed(sessionId, closedAt = Date.now()) {
  const key = String(sessionId);
  const existing = REMOTE_SESSION_WINDOWS.get(key);
  if (existing) existing.completedBefore = closedAt + 30 * 1000;
}

function shouldSuppressWatchedCompletion(sessionId, startedAt, completedAt) {
  const key = String(sessionId);
  const window = REMOTE_SESSION_WINDOWS.get(key);
  if (!window) return false;
  const eventStarted = Date.parse(startedAt || completedAt || '');
  const eventCompleted = Date.parse(completedAt || startedAt || '');
  const upperBound = window.completedBefore || Date.now() + 30 * 1000;
  const matches = Number.isFinite(eventStarted)
    && Number.isFinite(eventCompleted)
    && eventStarted >= window.startedAt - 10 * 1000
    && eventCompleted <= upperBound;
  if (matches || Date.now() > window.startedAt + 60 * 60 * 1000) REMOTE_SESSION_WINDOWS.delete(key);
  return matches;
}

class CompletionWatcher {
  constructor(onCompletion, options = {}) {
    this.onCompletion = onCompletion;
    this.sessionsRoot = path.resolve(options.sessionsRoot || CODEX_SESSIONS_ROOT);
    this.statePath = path.resolve(options.statePath || PATHS.completionWatch);
    this.intervalMs = options.intervalMs || 3000;
    this.offsets = {};
    this.timer = null;
    this.busy = false;
  }

  save() {
    atomicWriteJson(this.statePath, { schema: 1, offsets: this.offsets, updatedAtUtc: new Date().toISOString() });
  }

  async initialize() {
    const saved = readJson(this.statePath);
    if (!saved || saved.schema !== 1 || !saved.offsets || typeof saved.offsets !== 'object') {
      this.offsets = {};
      for (const filePath of listRolloutFiles(this.sessionsRoot)) {
        const relative = path.relative(this.sessionsRoot, filePath);
        try {
          this.offsets[relative] = fs.statSync(filePath).size;
        } catch {
          // Ignore files that disappear during the initial snapshot.
        }
      }
      this.save();
      return;
    }
    this.offsets = { ...saved.offsets };
    await this.scan();
  }

  async scan() {
    if (this.busy) return;
    this.busy = true;
    try {
      const files = listRolloutFiles(this.sessionsRoot);
      const visible = new Set();
      for (const filePath of files) {
        const relative = path.relative(this.sessionsRoot, filePath);
        visible.add(relative);
        const stat = fs.statSync(filePath);
        let offset = Number(this.offsets[relative] || 0);
        if (offset < 0 || offset > stat.size) offset = 0;
        if (offset === stat.size) continue;
        const length = stat.size - offset;
        const buffer = Buffer.alloc(length);
        const handle = fs.openSync(filePath, 'r');
        let bytesRead = 0;
        try {
          bytesRead = fs.readSync(handle, buffer, 0, length, offset);
        } finally {
          fs.closeSync(handle);
        }
        const data = buffer.subarray(0, bytesRead);
        const lastNewline = data.lastIndexOf(0x0a);
        if (lastNewline < 0) continue;
        const completeBytes = data.subarray(0, lastNewline + 1);
        const sessionId = sessionIdFromRolloutPath(filePath);
        if (sessionId) {
          for (const line of completeBytes.toString('utf8').split('\n')) {
            if (!/"type"\s*:\s*"task_complete"/.test(line)) continue;
            const turnId = extractJsonStringField(line, 'turn_id');
            if (!turnId) continue;
            await this.onCompletion({
              sessionId,
              turnId,
              startedAt: extractJsonTimestampField(line, 'started_at'),
              completedAt: extractJsonTimestampField(line, 'completed_at'),
              finalResponse: clipResponse(extractJsonStringField(line, 'last_agent_message')),
            });
          }
        }
        this.offsets[relative] = offset + completeBytes.length;
      }
      for (const relative of Object.keys(this.offsets)) {
        if (!visible.has(relative)) delete this.offsets[relative];
      }
      this.save();
    } finally {
      this.busy = false;
    }
  }

  start() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.scan().catch((error) => logEvent('error', 'completion_watch_failed', error.name));
    }, this.intervalMs);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}

function defaultState() {
  return {
    schema: 1,
    allowedOpenIds: [],
    defaultChatByUser: {},
    activeSessionByUser: {},
    pairing: null,
  };
}

function normalizeState(value) {
  const state = value && typeof value === 'object' ? value : defaultState();
  if (!Array.isArray(state.allowedOpenIds)) state.allowedOpenIds = [];
  if (!state.defaultChatByUser || typeof state.defaultChatByUser !== 'object') state.defaultChatByUser = {};
  if (!state.activeSessionByUser || typeof state.activeSessionByUser !== 'object') state.activeSessionByUser = {};
  if (!Object.prototype.hasOwnProperty.call(state, 'pairing')) state.pairing = null;
  state.schema = 1;
  return state;
}

function loadState() {
  return normalizeState(readJson(PATHS.state, defaultState()));
}

function saveState(state) {
  atomicWriteJson(PATHS.state, normalizeState(state));
}

function getPairedChatId(state = loadState()) {
  for (const openId of state.allowedOpenIds) {
    const chatId = String(state.defaultChatByUser[openId] || '').trim();
    if (chatId) return chatId;
  }
  return null;
}

function formatCompletionMessage(session, occurredAt, finalResponse = '') {
  const time = new Date(occurredAt);
  const displayTime = Number.isNaN(time.getTime())
    ? new Date().toLocaleString('zh-CN', { hour12: false })
    : time.toLocaleString('zh-CN', { hour12: false });
  const lines = [
    '[Codex] 本轮已结束',
    `标题：${safeThreadTitle(session.title)}`,
    `项目：${safeDetail(session.project || 'unknown')}`,
    `对话：${session.code}`,
    `时间：${displayTime}`,
  ];
  if (String(finalResponse || '').trim()) {
    lines.push('', '回复：', clipResponse(finalResponse));
  }
  return lines.join('\n');
}

async function enqueueWatchedCompletion(event) {
  if (shouldSuppressWatchedCompletion(event.sessionId, event.startedAt, event.completedAt)) {
    logEvent('info', 'remote_completion_suppressed', sha256(event.sessionId).slice(0, 12));
    return false;
  }
  const eventKey = sha256(`${event.sessionId}\n${event.turnId}`);
  const outboxPath = path.join(PATHS.outbox, `${eventKey}.json`);
  const sentPath = path.join(PATHS.sent, `${eventKey}.done`);
  const deadPath = path.join(PATHS.deadLetter, `${eventKey}.json`);
  if (fs.existsSync(outboxPath) || fs.existsSync(sentPath) || fs.existsSync(deadPath)) return false;
  try {
    await syncSessionsFromAppServer();
  } catch (error) {
    logEvent('warning', 'completion_metadata_sync_failed', error.message || error.name);
  }
  const code = sha256(event.sessionId).slice(0, 10).toUpperCase();
  const session = loadSessions().find((item) => item.sessionId === event.sessionId) || {
    code,
    title: '未命名对话',
    project: 'unknown',
  };
  const chatId = getPairedChatId();
  if (!chatId) {
    logEvent('warning', 'completion_has_no_paired_chat', code);
    return false;
  }
  const occurredAt = event.completedAt || new Date().toISOString();
  const prepared = prepareCodexResult(
    event.finalResponse,
    SESSION_WORKSPACES.get(event.sessionId),
    [CODEX_VISUALIZATIONS_ROOT],
  );
  const stagedImages = stageOutboundImages(prepared.imagePaths, eventKey);
  const job = {
    schema: 1,
    kind: 'completion',
    eventKey,
    targetChatId: chatId,
    conversationCode: code,
    message: formatCompletionMessage(session, occurredAt, prepared.text),
    imagePaths: stagedImages,
    textSent: false,
    nextImageIndex: 0,
    createdAtUtc: new Date().toISOString(),
  };
  const created = writeNewJson(outboxPath, job);
  if (created) logEvent('info', 'global_completion_queued', eventKey.slice(0, 12));
  return created;
}

function pairingHash(code) {
  return sha256(String(code || '').trim().toUpperCase());
}

function timingSafeTextEqual(left, right) {
  const leftBuffer = Buffer.from(String(left), 'utf8');
  const rightBuffer = Buffer.from(String(right), 'utf8');
  if (leftBuffer.length !== rightBuffer.length) return false;
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function parseCommand(input) {
  const text = String(input || '').replace(/\u0000/g, '').trim();
  let match;
  if (!text) return { type: 'empty' };
  if ((match = text.match(/^\/pair\s+([A-Za-z0-9-]{4,32})$/i))) {
    return { type: 'pair', code: match[1].toUpperCase() };
  }
  if (/^\/help$/i.test(text)) return { type: 'help' };
  if (/^\/list$/i.test(text)) return { type: 'list' };
  if (/^\/status$/i.test(text)) return { type: 'status' };
  if ((match = text.match(/^\/use\s+([A-Fa-f0-9]{6,16})$/))) {
    return { type: 'use', code: match[1].toUpperCase() };
  }
  if ((match = text.match(/^#([A-Fa-f0-9]{6,16})\s+([\s\S]+)$/))) {
    return { type: 'prompt', code: match[1].toUpperCase(), prompt: sanitizePrompt(match[2]) };
  }
  return { type: 'prompt', code: null, prompt: sanitizePrompt(text) };
}

function sanitizePrompt(input) {
  const value = String(input || '').replace(/\u0000/g, '').trim();
  return value.length > MAX_PROMPT_CHARS ? value.slice(0, MAX_PROMPT_CHARS) : value;
}

function clipResponse(input) {
  const value = String(input || '').trim();
  if (value.length <= MAX_RESPONSE_CHARS) return value;
  return `${value.slice(0, MAX_RESPONSE_CHARS)}\n\n[回复过长，已在手机端截断]`;
}

function loadSessions() {
  ensureDirectories();
  const sessions = [];
  for (const name of fs.readdirSync(SESSIONS_DIR)) {
    if (!/^[A-F0-9]{10}\.json$/i.test(name)) continue;
    const record = readJson(path.join(SESSIONS_DIR, name));
    if (!record || !record.sessionId || !record.code) continue;
    sessions.push({
      code: String(record.code).toUpperCase(),
      sessionId: String(record.sessionId),
      title: safeThreadTitle(record.title),
      project: safeDetail(record.project || 'unknown'),
      lastSeenUtc: String(record.lastSeenUtc || ''),
    });
  }
  sessions.sort((left, right) => right.lastSeenUtc.localeCompare(left.lastSeenUtc));
  return sessions;
}

function safeProjectLeaf(cwd) {
  const value = String(cwd || '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim();
  if (!value) return 'unknown';
  const trimmed = value.replace(/[\\/]+$/, '');
  const segments = trimmed.split(/[\\/]/).filter(Boolean);
  const leaf = segments.at(-1) || trimmed || 'unknown';
  return leaf.replace(/[<>&]/g, '_').slice(0, 120) || 'unknown';
}

function safeThreadTitle(value) {
  const title = String(value || '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/[<>&]/g, '_')
    .trim();
  return title.slice(0, 80) || '未命名对话';
}

function threadToSessionRecord(thread) {
  const sessionId = String(thread && thread.id ? thread.id : '');
  if (!sessionId) return null;
  const numericTime = Number(thread.recencyAt || thread.updatedAt || thread.createdAt || 0);
  const lastSeenUtc = numericTime > 0 ? new Date(numericTime * 1000).toISOString() : new Date().toISOString();
  return {
    schema: 2,
    code: sha256(sessionId).slice(0, 10).toUpperCase(),
    sessionId,
    title: safeThreadTitle(thread.name),
    project: safeProjectLeaf(thread.cwd),
    lastSeenUtc,
  };
}

function listCodexThreads(options = {}) {
  const spawnImpl = options.spawnImpl || spawn;
  const timeoutMs = options.timeoutMs || 20000;
  return new Promise((resolve, reject) => {
    const child = spawnImpl(CODEX_EXE, ['app-server', '--stdio'], {
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'ignore'],
      env: process.env,
    });
    const lines = readline.createInterface({ input: child.stdout });
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      lines.close();
      child.kill();
      if (error) reject(error);
      else resolve(value);
    };
    const send = (value) => child.stdin.write(`${JSON.stringify(value)}\n`);
    const timer = setTimeout(() => finish(new Error('app_server_list_timeout')), timeoutMs);

    child.once('error', (error) => finish(new Error(`app_server_spawn_${error.code || error.name}`)));
    child.once('close', (code) => {
      if (!settled) finish(new Error(`app_server_exit_${code}`));
    });
    lines.on('line', (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (message.id === 1) {
        if (message.error) {
          finish(new Error('app_server_initialize_failed'));
          return;
        }
        send({ method: 'initialized', params: {} });
        send({
          method: 'thread/list',
          id: 2,
          params: {
            limit: 100,
            sortKey: 'recency_at',
            sortDirection: 'desc',
            sourceKinds: [],
            modelProviders: [],
            archived: false,
          },
        });
      } else if (message.id === 2) {
        if (message.error) {
          finish(new Error('app_server_thread_list_failed'));
          return;
        }
        finish(null, Array.isArray(message.result && message.result.data) ? message.result.data : []);
      }
    });
    send({
      method: 'initialize',
      id: 1,
      params: {
        clientInfo: { name: 'codex_feishu_bridge', title: 'Codex Feishu Bridge', version: '1.1.1' },
      },
    });
  });
}

async function syncSessionsFromAppServer(options = {}) {
  ensureDirectories();
  const threads = await listCodexThreads(options);
  let written = 0;
  for (const thread of threads) {
    const record = threadToSessionRecord(thread);
    if (!record) continue;
    if (thread.cwd && path.isAbsolute(String(thread.cwd))) {
      SESSION_WORKSPACES.set(record.sessionId, path.resolve(String(thread.cwd)));
    }
    atomicWriteJson(path.join(SESSIONS_DIR, `${record.code}.json`), record);
    written += 1;
  }
  logEvent('info', 'sessions_synced', String(written));
  return written;
}

async function resolveSessionWorkspace(session, options = {}) {
  const cached = SESSION_WORKSPACES.get(session.sessionId);
  if (cached) return cached;
  const threads = await listCodexThreads(options);
  for (const thread of threads) {
    if (!thread || !thread.id || !thread.cwd || !path.isAbsolute(String(thread.cwd))) continue;
    SESSION_WORKSPACES.set(String(thread.id), path.resolve(String(thread.cwd)));
  }
  return SESSION_WORKSPACES.get(session.sessionId) || null;
}

function findSession(code, sessions = loadSessions()) {
  const normalized = String(code || '').toUpperCase();
  return sessions.find((session) => session.code === normalized) || null;
}

function resolvePromptTarget(senderId, requestedCode, state, sessions = loadSessions()) {
  if (requestedCode) {
    const direct = findSession(requestedCode, sessions);
    return direct ? { session: direct, autoSelected: false } : { session: null, autoSelected: false };
  }
  const activeCode = state.activeSessionByUser[senderId];
  if (activeCode) {
    const active = findSession(activeCode, sessions);
    if (active) return { session: active, autoSelected: false };
  }
  if (sessions.length === 1) return { session: sessions[0], autoSelected: true };
  return { session: null, autoSelected: false };
}

function buildCodexArgs(sessionId, outputFile, imagePaths = []) {
  return [
    'exec',
    'resume',
    '-c',
    'sandbox_mode="workspace-write"',
    '-c',
    'approval_policy="never"',
    '--skip-git-repo-check',
    '--output-last-message',
    outputFile,
    ...imagePaths.flatMap((imagePath) => ['--image', imagePath]),
    sessionId,
    '-',
  ];
}

function runCodexSession(session, prompt, options = {}) {
  const spawnImpl = options.spawnImpl || spawn;
  const timeoutMs = options.timeoutMs || 45 * 60 * 1000;
  ensureDirectories();
  const outputFile = path.join(PATHS.temp, `codex-${process.pid}-${crypto.randomUUID()}.txt`);
  const args = buildCodexArgs(session.sessionId, outputFile, options.imagePaths || []);
  markRemoteSessionStarted(session.sessionId);

  return new Promise((resolve, reject) => {
    const child = spawnImpl(CODEX_EXE, args, {
      windowsHide: true,
      stdio: ['pipe', 'ignore', 'pipe'],
      env: { ...process.env, CODEX_FEISHU_REMOTE_RUN: '1' },
    });
    let stderrBytes = 0;
    child.stderr.on('data', (chunk) => {
      stderrBytes += chunk.length;
    });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('codex_timeout'));
    }, timeoutMs);

    child.once('error', (error) => {
      clearTimeout(timer);
      markRemoteSessionClosed(session.sessionId);
      reject(new Error(`codex_spawn_${error.code || error.name}`));
    });
    child.once('close', (code) => {
      clearTimeout(timer);
      markRemoteSessionClosed(session.sessionId);
      try {
        if (code !== 0) {
          reject(new Error(`codex_exit_${code}_stderr_${stderrBytes}`));
          return;
        }
        const response = fs.existsSync(outputFile) ? fs.readFileSync(outputFile, 'utf8') : '';
        resolve(prepareCodexResult(response, options.workspaceRoot));
      } finally {
        fs.rmSync(outputFile, { force: true });
      }
    });
    child.stdin.end(sanitizePrompt(prompt), 'utf8');
  });
}

function formatSessionList(sessions) {
  if (!sessions.length) return '还没有可用的 Codex 对话。先在电脑端完成一次对话轮次，再试一次。';
  const visible = sessions.slice(0, 20);
  const lines = [`可用的 Codex 对话（最近 ${visible.length}/${sessions.length}）：`, ''];
  for (const [index, session] of visible.entries()) {
    const time = session.lastSeenUtc ? new Date(session.lastSeenUtc).toLocaleString('zh-CN', { hour12: false }) : '-';
    lines.push(`${index + 1}. ${safeThreadTitle(session.title)}`);
    lines.push(`   ${session.code} | ${session.project} | ${time}`);
  }
  lines.push('', '使用 /use 对话码 切换，例如：/use A72F19C304');
  return lines.join('\n');
}

const HELP_TEXT = [
  'Codex 飞书桥接命令：',
  '/list - 查看本机已映射的 Codex 对话',
  '/use 对话码 - 选择后续消息要发送到的对话',
  '#对话码 消息 - 临时向指定对话发送消息',
  '/status - 查看当前选择和队列状态',
  '/help - 显示帮助',
  '',
  '普通文字会发送到当前选中的 Codex 对话。',
  '所有电脑端对话完成后都会全局通知，与 /use 无关。',
  '可以直接发送图片；Codex 明确引用的项目内图片也会发回飞书。',
].join('\n');

class BridgeRuntime {
  constructor(channel, options = {}) {
    this.channel = channel;
    this.runCodex = options.runCodex || runCodexSession;
    this.syncSessions = options.syncSessions || syncSessionsFromAppServer;
    this.resolveWorkspace = options.resolveWorkspace || resolveSessionWorkspace;
    this.fetchImage = options.fetchImage || ((messageId, fileKey) => fetchMessageImage(channel, messageId, fileKey));
    this.timer = null;
    this.busy = false;
  }

  enqueueMessage(message) {
    try {
      if (!message || message.chatType !== 'p2p') return false;
      const messageId = String(message.messageId || '');
      const senderId = String(message.senderId || '');
      const chatId = String(message.chatId || '');
      if (!messageId || !senderId || !chatId) return false;
      let images = normalizeInboundImages(message.resources)
        .map((image) => ({ ...image, messageId }));
      const acceptsText = ['text', 'post'].includes(String(message.rawContentType || ''));
      const text = acceptsText ? sanitizePrompt(stripInboundImageMarkers(message.content)) : '';
      if (!text && !images.length) return false;
      const key = sha256(messageId);
      for (const dir of [PATHS.inbox, PATHS.working, PATHS.processed, PATHS.deadLetter]) {
        if (fs.existsSync(path.join(dir, `${key}.json`)) || fs.existsSync(path.join(dir, `${key}.done`))) return false;
      }

      const command = text ? parseCommand(text) : { type: 'empty' };
      const canConsumePending = !text || command.type === 'prompt';
      if (canConsumePending) {
        for (const name of fs.readdirSync(PATHS.inbox).filter((item) => item.endsWith('.json'))) {
          const pendingPath = path.join(PATHS.inbox, name);
          const pending = readJson(pendingPath);
          if (!pending || pending.pendingImageOnly !== true) continue;
          if (pending.senderId !== senderId || pending.chatId !== chatId) continue;
          images = normalizeInboundImages([...(pending.images || []), ...images]);
          fs.rmSync(pendingPath, { force: true });
          fs.writeFileSync(path.join(PATHS.processed, `${pending.key}.done`), new Date().toISOString(), 'utf8');
        }
      }

      const pendingImageOnly = !text && images.length > 0;
      const job = {
        schema: 3,
        key,
        messageId,
        senderId,
        chatId,
        text,
        images,
        receivedAtUtc: new Date().toISOString(),
        pendingImageOnly,
        notBeforeUtc: pendingImageOnly ? new Date(Date.now() + PENDING_IMAGE_WAIT_MS).toISOString() : null,
      };
      const created = writeNewJson(path.join(PATHS.inbox, `${key}.json`), job);
      if (created) {
        logEvent('info', pendingImageOnly ? 'inbound_image_pending' : 'inbound_queued', key.slice(0, 12));
        if (pendingImageOnly) {
          this.sendText(chatId, '图片已收到。请在 60 秒内发送说明；未发送说明时将自动分析。', messageId)
            .catch((error) => logEvent('warning', 'pending_image_ack_failed', error.code || error.name));
        }
      }
      return created;
    } catch (error) {
      logEvent('error', 'inbound_queue_failed', error.code || error.name);
      return false;
    }
  }

  async sendText(chatId, text, replyTo = null) {
    const options = replyTo ? { replyTo } : undefined;
    return this.channel.send(chatId, { text: String(text) }, options);
  }

  async replaceProgressText(progressMessage, chatId, text, replyTo = null) {
    if (progressMessage && progressMessage.messageId && typeof this.channel.editMessage === 'function') {
      try {
        await this.channel.editMessage(progressMessage.messageId, String(text));
        return;
      } catch (error) {
        logEvent('warning', 'progress_edit_failed', error.code || error.name);
      }
    }
    await this.sendText(chatId, text, replyTo);
  }

  async sendImage(chatId, imagePath, replyTo = null) {
    const options = replyTo ? { replyTo } : undefined;
    return this.channel.send(chatId, { image: { source: imagePath } }, options);
  }

  isAuthorized(senderId, state) {
    return state.allowedOpenIds.includes(senderId);
  }

  async processPair(job, command, state) {
    if (this.isAuthorized(job.senderId, state)) {
      state.defaultChatByUser[job.senderId] = job.chatId;
      saveState(state);
      await this.sendText(job.chatId, '这个飞书账号已经完成配对。', job.messageId);
      return;
    }
    if (!state.pairing || !state.pairing.hash || !state.pairing.expiresAtUtc) {
      await this.sendText(job.chatId, '当前没有有效的配对码。请先在电脑上运行 Bridge 的 Pair 操作。', job.messageId);
      return;
    }
    if (Date.parse(state.pairing.expiresAtUtc) < Date.now()) {
      await this.sendText(job.chatId, '配对码已过期，请在电脑上重新生成。', job.messageId);
      return;
    }
    if (!timingSafeTextEqual(pairingHash(command.code), state.pairing.hash)) {
      await this.sendText(job.chatId, '配对码不正确。', job.messageId);
      return;
    }
    state.allowedOpenIds.push(job.senderId);
    state.allowedOpenIds = [...new Set(state.allowedOpenIds)];
    state.defaultChatByUser[job.senderId] = job.chatId;
    state.pairing = null;
    saveState(state);
    await this.sendText(job.chatId, `配对成功。\n\n${HELP_TEXT}`, job.messageId);
    logEvent('info', 'paired', sha256(job.senderId).slice(0, 12));
  }

  async processAuthorized(job, command, state) {
    state.defaultChatByUser[job.senderId] = job.chatId;
    if (command.type === 'help') {
      saveState(state);
      await this.sendText(job.chatId, HELP_TEXT, job.messageId);
      return;
    }

    if (command.type === 'list') {
      try {
        await this.syncSessions();
      } catch (error) {
        logEvent('warning', 'session_sync_failed', error.message || error.name);
      }
      const sessions = loadSessions();
      saveState(state);
      await this.sendText(job.chatId, formatSessionList(sessions), job.messageId);
      return;
    }
    const sessions = loadSessions();
    if (command.type === 'status') {
      const active = state.activeSessionByUser[job.senderId] || '-';
      const pending = fs.readdirSync(PATHS.inbox).filter((name) => name.endsWith('.json')).length;
      saveState(state);
      await this.sendText(
        job.chatId,
        `桥接服务在线\n全局完成通知：已启用\n当前对话：${active}\n可用对话：${sessions.length}\n等待处理：${pending}`,
        job.messageId,
      );
      return;
    }
    if (command.type === 'use') {
      const session = findSession(command.code, sessions);
      if (!session) {
        await this.sendText(job.chatId, `没有找到对话 ${command.code}。使用 /list 查看。`, job.messageId);
        return;
      }
      state.activeSessionByUser[job.senderId] = session.code;
      saveState(state);
      await this.sendText(job.chatId, `已切换到 ${session.code} (${session.project})。`, job.messageId);
      return;
    }
    const inboundImageCount = normalizeInboundImages(job.images).length;
    if (command.type !== 'prompt' || (!command.prompt && !inboundImageCount)) {
      saveState(state);
      await this.sendText(job.chatId, HELP_TEXT, job.messageId);
      return;
    }

    const target = resolvePromptTarget(job.senderId, command.code, state, sessions);
    if (!target.session) {
      await this.sendText(job.chatId, '还没有选中 Codex 对话。请先使用 /list 和 /use 对话码。', job.messageId);
      return;
    }
    state.activeSessionByUser[job.senderId] = target.session.code;
    saveState(state);

    let workspaceRoot = null;
    try {
      workspaceRoot = await this.resolveWorkspace(target.session);
    } catch (error) {
      logEvent('warning', 'workspace_resolve_failed', error.message || error.name);
    }
    let inboundPaths = [];
    try {
      if (inboundImageCount) inboundPaths = await storeInboundImages(job, this.fetchImage);
    } catch (error) {
      await this.sendText(job.chatId, '图片下载或校验失败。请确认飞书应用已开通 im:message:readonly；仅支持不超过 10 MB 的 PNG、JPEG、GIF 或 WebP 图片。', job.messageId);
      logEvent('error', 'inbound_image_failed', error.message || error.name);
      return;
    }
    let response;
    try {
      response = await this.runCodex(
        target.session,
        buildBridgePrompt(command.prompt, inboundPaths.length),
        { imagePaths: inboundPaths, workspaceRoot },
      );
    } catch (error) {
      await this.sendText(job.chatId, 'Codex 执行失败或当前对话正忙。为避免重复修改，任务没有自动重试，请查看电脑端日志。', job.messageId);
      logEvent('error', 'codex_failed', error.message || error.name);
      return;
    }
    const result = typeof response === 'string'
      ? { text: clipResponse(response), imagePaths: [] }
      : { text: clipResponse(response && response.text), imagePaths: Array.isArray(response && response.imagePaths) ? response.imagePaths : [] };
    if (result.text) await this.sendText(job.chatId, result.text, job.messageId);
    let imageFailures = 0;
    for (const imagePath of result.imagePaths.slice(0, MAX_IMAGES_PER_TURN)) {
      try {
        await this.sendImage(job.chatId, imagePath, job.messageId);
      } catch (error) {
        imageFailures += 1;
        logEvent('error', 'outbound_image_failed', error.code || error.name);
      }
    }
    if (imageFailures) await this.sendText(job.chatId, `有 ${imageFailures} 张图片上传飞书失败。请确认应用已开通 im:resource:upload，并查看电脑端日志。`, job.messageId);
    logEvent('info', 'codex_completed', target.session.code);
  }

  async processInboxFile(filePath) {
    const name = path.basename(filePath);
    const workingPath = path.join(PATHS.working, name);
    fs.renameSync(filePath, workingPath);
    const job = readJson(workingPath);
    if (!job) throw new Error('invalid_inbox_job');
    let command = parseCommand(job.text);
    if (command.type === 'empty' && normalizeInboundImages(job.images).length) {
      command = { type: 'prompt', code: null, prompt: '' };
    }
    const state = loadState();
    if (command.type === 'pair') {
      await this.processPair(job, command, state);
    } else if (!this.isAuthorized(job.senderId, state)) {
      await this.sendText(job.chatId, '此飞书账号尚未授权。请在电脑上生成配对码，然后发送 /pair 配对码。', job.messageId);
    } else {
      await this.processAuthorized(job, command, state);
    }
    fs.writeFileSync(path.join(PATHS.processed, `${job.key}.done`), new Date().toISOString(), 'utf8');
    fs.rmSync(workingPath, { force: true });
  }

  async processOutboxFile(filePath) {
    const job = readJson(filePath);
    if (!job || job.kind !== 'completion' || !job.targetChatId || !job.message) {
      fs.renameSync(filePath, path.join(PATHS.deadLetter, path.basename(filePath)));
      return false;
    }
    if (job.nextAttemptAtUtc && Date.parse(job.nextAttemptAtUtc) > Date.now()) return false;
    const imagePaths = (Array.isArray(job.imagePaths) ? job.imagePaths : [])
      .map((item) => path.resolve(String(item)))
      .filter((item) => isPathInside(PATHS.outboundMedia, item) && fs.existsSync(item))
      .slice(0, MAX_IMAGES_PER_TURN);
    if (job.textSent !== true) {
      await this.sendText(job.targetChatId, job.message);
      job.textSent = true;
      job.nextImageIndex = Number(job.nextImageIndex || 0);
      atomicWriteJson(filePath, job);
    }
    for (let index = Number(job.nextImageIndex || 0); index < imagePaths.length; index += 1) {
      await this.sendImage(job.targetChatId, imagePaths[index]);
      job.nextImageIndex = index + 1;
      atomicWriteJson(filePath, job);
    }
    fs.writeFileSync(path.join(PATHS.sent, `${job.eventKey}.done`), new Date().toISOString(), 'utf8');
    fs.rmSync(filePath, { force: true });
    for (const imagePath of imagePaths) fs.rmSync(imagePath, { force: true });
    logEvent('info', 'completion_sent', String(job.eventKey).slice(0, 12));
    return true;
  }

  scheduleOutboxRetry(filePath, error) {
    const job = readJson(filePath);
    if (!job) return;
    const delays = [1, 5, 30, 120, 300];
    const attempt = Number(job.attempt || 0) + 1;
    if (attempt > delays.length) {
      fs.renameSync(filePath, path.join(PATHS.deadLetter, path.basename(filePath)));
      logEvent('error', 'outbox_dead_lettered', error.code || error.name);
      return;
    }
    job.attempt = attempt;
    job.nextAttemptAtUtc = new Date(Date.now() + delays[attempt - 1] * 1000).toISOString();
    atomicWriteJson(filePath, job);
    logEvent('warning', 'outbox_retry_scheduled', `attempt=${attempt};error=${safeErrorCodes(error)}`);
  }

  recoverUncertainJobs() {
    ensureDirectories();
    for (const name of fs.readdirSync(PATHS.working).filter((item) => item.endsWith('.json'))) {
      const source = path.join(PATHS.working, name);
      const target = path.join(PATHS.deadLetter, `uncertain-${name}`);
      fs.renameSync(source, target);
      logEvent('warning', 'uncertain_job_dead_lettered', name.slice(0, 12));
    }
  }

  async tick() {
    if (this.busy) return;
    this.busy = true;
    try {
      const outbox = fs.readdirSync(PATHS.outbox).filter((name) => name.endsWith('.json')).sort();
      if (outbox.length) {
        try {
          await this.processOutboxFile(path.join(PATHS.outbox, outbox[0]));
        } catch (error) {
          this.scheduleOutboxRetry(path.join(PATHS.outbox, outbox[0]), error);
        }
      }
      const inbox = fs.readdirSync(PATHS.inbox)
        .filter((name) => name.endsWith('.json'))
        .map((name) => ({ name, job: readJson(path.join(PATHS.inbox, name)) }))
        .filter(({ job }) => job && (!job.notBeforeUtc || Date.parse(job.notBeforeUtc) <= Date.now()))
        .sort((left, right) => left.name.localeCompare(right.name));
      if (inbox.length) {
        const filePath = path.join(PATHS.inbox, inbox[0].name);
        try {
          await this.processInboxFile(filePath);
        } catch (error) {
          const workingPath = path.join(PATHS.working, path.basename(filePath));
          const source = fs.existsSync(workingPath) ? workingPath : filePath;
          if (fs.existsSync(source)) fs.renameSync(source, path.join(PATHS.deadLetter, path.basename(source)));
          logEvent('error', 'inbox_processing_failed', error.message || error.name);
        }
      }
    } finally {
      this.busy = false;
    }
  }

  start() {
    ensureDirectories();
    this.recoverUncertainJobs();
    this.timer = setInterval(() => {
      this.tick().catch((error) => logEvent('error', 'worker_tick_failed', error.name));
    }, 500);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}

async function main() {
  const appId = process.env.FEISHU_APP_ID;
  const appSecret = process.env.FEISHU_APP_SECRET;
  if (!appId || !appSecret) throw new Error('FEISHU_APP_ID and FEISHU_APP_SECRET are required');
  ensureDirectories();
  cleanupInboundMedia();
  fs.writeFileSync(PATHS.pid, String(process.pid), 'utf8');
  try {
    await syncSessionsFromAppServer();
  } catch (error) {
    logEvent('warning', 'session_sync_failed', error.message || error.name);
  }

  const channel = Lark.createLarkChannel({
    appId,
    appSecret,
    transport: 'websocket',
    source: 'codex-feishu-bridge',
    loggerLevel: Lark.LoggerLevel.warn,
    policy: {
      dmMode: 'open',
      groupAllowlist: [],
      requireMention: true,
      respondToMentionAll: false,
    },
    safety: {
      dedup: { ttl: 10 * 60 * 1000, maxEntries: 5000 },
      chatQueue: { enabled: true },
      staleMessageWindowMs: 24 * 60 * 60 * 1000,
    },
    outbound: {
      textChunkLimit: 3500,
      retry: { maxAttempts: 3, baseDelayMs: 1000 },
    },
    handshakeTimeoutMs: 20000,
  });

  const runtime = new BridgeRuntime(channel);
  const completionWatcher = new CompletionWatcher(enqueueWatchedCompletion);
  await completionWatcher.initialize();
  channel.on('message', (message) => {
    runtime.enqueueMessage(message);
  });
  channel.on('reject', (event) => {
    logEvent('warning', 'message_rejected', event.reason);
  });
  channel.on('error', (error) => {
    logEvent('error', 'lark_channel_error', error.code || error.name);
  });
  channel.on('reconnecting', () => logEvent('warning', 'lark_reconnecting'));
  channel.on('reconnected', () => logEvent('info', 'lark_reconnected'));

  await channel.connect();
  runtime.start();
  completionWatcher.start();
  atomicWriteJson(PATHS.runtime, { pid: process.pid, connectedAtUtc: new Date().toISOString(), status: 'connected' });
  logEvent('info', 'bridge_connected');

  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    runtime.stop();
    completionWatcher.stop();
    try {
      await channel.disconnect();
    } catch {
      // Best effort shutdown.
    }
    fs.rmSync(PATHS.pid, { force: true });
    atomicWriteJson(PATHS.runtime, { pid: process.pid, stoppedAtUtc: new Date().toISOString(), status: 'stopped' });
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

module.exports = {
  PATHS,
  BridgeRuntime,
  CompletionWatcher,
  atomicWriteJson,
  buildCodexArgs,
  buildBridgePrompt,
  clipResponse,
  cleanupInboundMedia,
  cleanupOutboundMedia,
  defaultState,
  detectImageExtension,
  enqueueWatchedCompletion,
  extractJsonStringField,
  extractJsonTimestampField,
  fetchMessageImage,
  findSession,
  formatSessionList,
  formatCompletionMessage,
  getPairedChatId,
  loadSessions,
  loadState,
  listCodexThreads,
  listRolloutFiles,
  markRemoteSessionClosed,
  markRemoteSessionStarted,
  normalizeState,
  normalizeInboundImages,
  pairingHash,
  parseCommand,
  prepareCodexResult,
  resolvePromptTarget,
  resolveSessionWorkspace,
  safeProjectLeaf,
  safeThreadTitle,
  sanitizePrompt,
  saveState,
  sha256,
  shouldSuppressWatchedCompletion,
  sessionIdFromRolloutPath,
  storeInboundImages,
  stageOutboundImages,
  stripInboundImageMarkers,
  syncSessionsFromAppServer,
  threadToSessionRecord,
  timingSafeTextEqual,
};

if (require.main === module) {
  if (process.argv.includes('--sync-only')) {
    syncSessionsFromAppServer()
      .then((count) => process.stdout.write(`${count}\n`))
      .catch((error) => {
        logEvent('error', 'session_sync_failed', error.message || error.name);
        process.exitCode = 1;
      });
  } else {
    main().catch((error) => {
      logEvent('error', 'bridge_fatal', error.message || error.name);
      fs.rmSync(PATHS.pid, { force: true });
      process.exitCode = 1;
    });
  }
}
