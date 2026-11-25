// 本地 mock Cloudreve v4 服务端，用于端到端验证 Delphi 示例。
//
// 覆盖示例用到的接口：
//   POST   /api/v4/session/token                 登录换 access_token
//   PUT    /api/v4/file/upload                   创建上传会话
//   POST   /api/v4/file/upload/:sessionId/:index 上传分片
//   DELETE /api/v4/file/upload                   取消会话
//   GET    /api/v4/file/info?uri=...             查询文件大小
//   POST   /api/v4/file/url                      取下载地址
//   GET    /api/v4/file?uri=...                  列目录
//   POST   /api/v4/file/create                   建目录
//   GET    /dl/:sessionId                        下载（回读校验用）
//
// 故意注入的故障（验证重试）：
//   * 第 2 片的前 2 次请求返回 503
//   * 第 4 片的前 1 次返回 500
//
// 用法：node mock-server.js [port]
// 校验失败会打印 [FAIL] 并以非 0 退出。

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.argv[2] || '18080', 10);
const CHUNK_SIZE = 5 * 1024 * 1024; // 5 MiB，模拟服务端下发片长
const TOKEN = 'mock-access-token-1234567890';

const sessions = new Map(); // sessionId -> { chunks: Map<index, Buffer>, size, uri, name }
const folders = new Set(['cloudreve://admin']);
const files = new Map(); // uri -> { size, sha256, data }
const attempts = new Map(); // "sessionId:index" -> 尝试次数

const log = (...a) => console.log('[mock]', ...a);

function json(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
  });
  res.end(body);
}

const ok = (res, data) => json(res, 200, { code: 0, data, msg: '' });
const fail = (res, code, msg) => json(res, 200, { code, data: null, msg });

function readBody(req) {
  return new Promise((resolve, reject) => {
    const parts = [];
    req.on('data', (c) => parts.push(c));
    req.on('end', () => resolve(Buffer.concat(parts)));
    req.on('error', reject);
  });
}

function newSessionId() {
  return crypto.randomBytes(8).toString('hex');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname.replace(/\/+$/, '') || '/';

  try {
    // ---------- 登录 ----------
    if (p === '/api/v4/session/token' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      log(`login email=${body.email}`);
      if (body.email !== 'admin@example.com' || body.password !== 'secret') {
        return fail(res, 40001, 'wrong password');
      }
      // 真实 Cloudreve v4：data = { user, token: { access_token, refresh_token, ... } }
      return ok(res, {
        user: { id: 1, email: body.email, nickname: 'admin' },
        token: {
          access_token: TOKEN,
          refresh_token: 'refresh-mock',
          access_expires: new Date(Date.now() + 3600000).toISOString(),
          refresh_expires: new Date(Date.now() + 864000000).toISOString(),
        },
      });
    }

    // ---------- 鉴权 ----------
    if (p.startsWith('/api/v4/') && p !== '/api/v4/session/token') {
      const auth = req.headers['authorization'] || '';
      if (auth !== `Bearer ${TOKEN}`) return fail(res, 40003, 'unauthorized');
    }

    // ---------- 列目录 ----------
    if (p === '/api/v4/file' && req.method === 'GET') {
      const uri = decodeURIComponent(url.searchParams.get('uri') || '');
      return ok(res, { parent: uri, folders: [], files: [] });
    }

    // ---------- 建目录 ----------
    if (p === '/api/v4/file/create' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      const dir = body.uri || '';
      folders.add(dir);
      log(`mkdir ${dir}`);
      return ok(res, { uri: dir });
    }

    // ---------- 创建上传会话 ----------
    if (p === '/api/v4/file/upload' && req.method === 'PUT') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      const id = newSessionId();
      sessions.set(id, {
        chunks: new Map(),
        size: body.size,
        uri: body.uri,
        name: body.name || path.basename(body.uri || ''),
        policyType: 'local',
        policyId: 'mockpolicy',
      });
      log(`session ${id} created size=${body.size} chunk=${CHUNK_SIZE}`);
      return ok(res, {
        session_id: id,
        chunk_size: CHUNK_SIZE,
        expires_at: Date.now() + 86400000,
        upload_credential: '',
      });
    }

    // ---------- 上传分片 ----------
    const m = p.match(/^\/api\/v4\/file\/upload\/([0-9a-f]+)\/(\d+)$/);
    if (m && req.method === 'POST') {
      const [, sid, idxStr] = m;
      const index = parseInt(idxStr, 10);
      const sess = sessions.get(sid);
      if (!sess) return fail(res, 40005, 'session not found');

      // 注入故障：验证客户端重试
      const key = `${sid}:${index}`;
      const n = (attempts.get(key) || 0) + 1;
      attempts.set(key, n);
      if (index === 2 && n <= 2) {
        log(`inject 503 for chunk 2 (attempt ${n})`);
        res.writeHead(503, { 'Content-Length': 0 });
        return res.end();
      }
      if (index === 4 && n <= 1) {
        log(`inject 500 for chunk 4 (attempt ${n})`);
        res.writeHead(500, { 'Content-Length': 0 });
        return res.end();
      }

      const data = await readBody(req);
      const expected =
        index < Math.floor(sess.size / CHUNK_SIZE)
          ? CHUNK_SIZE
          : sess.size - index * CHUNK_SIZE;
      if (data.length !== expected) {
        log(`[FAIL] chunk ${index} length ${data.length} != ${expected}`);
        return fail(res, 40013, `chunk length mismatch: ${data.length} != ${expected}`);
      }

      sess.chunks.set(index, data);
      log(`chunk ${index} ok (${data.length} bytes, attempt ${n})`);

      const total = Math.ceil(sess.size / CHUNK_SIZE);
      if (sess.chunks.size === total) {
        // 合并
        const merged = Buffer.alloc(sess.size);
        for (const [i, buf] of [...sess.chunks.entries()].sort((a, b) => a[0] - b[0])) {
          buf.copy(merged, i * CHUNK_SIZE);
        }
        const sha = crypto.createHash('sha256').update(merged).digest('hex');
        files.set(sess.uri, { size: merged.length, sha256: sha, data: merged });
        sessions.delete(sid);
        log(`merged ${sess.uri} size=${merged.length} sha256=${sha}`);
        return ok(res, { session_id: sid, uri: sess.uri, size: merged.length });
      }
      return ok(res, { session_id: sid, index, received: data.length });
    }

    // ---------- 取消会话 ----------
    if (p === '/api/v4/file/upload' && req.method === 'DELETE') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      sessions.delete(body.id || body.session_id || '');
      log(`session cancelled ${body.id || body.session_id}`);
      return ok(res, null);
    }

    // ---------- 文件信息 ----------
    if (p === '/api/v4/file/info' && req.method === 'GET') {
      const uri = url.searchParams.get('uri') || '';
      const f = files.get(uri);
      if (!f) return fail(res, 40401, 'not found');
      return ok(res, { uri, size: f.size, type: 'file' });
    }

    // ---------- 下载地址 ----------
    if (p === '/api/v4/file/url' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)).toString('utf8') || '{}');
      const uri = body.uri || (body.uris && body.uris[0]);
      if (!files.has(uri)) return fail(res, 40401, 'not found');
      const sid = newSessionId();
      dlMap.set(sid, uri);
      return ok(res, { urls: [{ url: `http://127.0.0.1:${PORT}/dl/${sid}` }] });
    }

    // ---------- 下载 ----------
    const dm = p.match(/^\/dl\/([0-9a-f]+)$/);
    if (dm && req.method === 'GET') {
      const uri = dlMap.get(dm[1]);
      const f = files.get(uri);
      if (!f) {
        res.writeHead(404, { 'Content-Length': 0 });
        return res.end();
      }
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': f.data.length,
      });
      return res.end(f.data);
    }

    log(`[WARN] no route: ${req.method} ${p}`);
    res.writeHead(404, { 'Content-Length': 0 });
    res.end();
  } catch (e) {
    log(`[FAIL] ${e.stack || e}`);
    res.writeHead(500, { 'Content-Length': 0 });
    res.end();
  }
});

const dlMap = new Map();

server.listen(PORT, '127.0.0.1', () => {
  log(`listening http://127.0.0.1:${PORT}  chunk=${CHUNK_SIZE}`);
});

process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
