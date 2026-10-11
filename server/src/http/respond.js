// 响应包络：{ code, message, data, trace_id }，code=0 成功（OpenAPI v3.1.0 通用约定）
export class HttpError extends Error {
  constructor(code, message, httpStatus = 400, data = null) {
    super(message);
    this.code = code;
    this.httpStatus = httpStatus;
    this.data = data;
  }
}

function sendJson(ctx, httpStatus, payload) {
  // 记录本次响应供通用幂等层缓存（仅 200 会被写入 idempotency_keys，见 app.js）
  ctx._sent = { httpStatus, payload };
  const body = JSON.stringify({ trace_id: ctx.traceId, ...payload });
  ctx.res.writeHead(httpStatus, { 'Content-Type': 'application/json; charset=utf-8' });
  ctx.res.end(body);
}

export const ok = (ctx, data = null, message = 'ok') =>
  sendJson(ctx, 200, { code: 0, message, data });

export const fail = (ctx, code, message, httpStatus = 400, data = null) =>
  sendJson(ctx, httpStatus, { code, message, data });

// 错误码段（OpenAPI）：40001 参数 / 40101 未登录 / 40301 隐私 / 42901 频控 / 41001 不存在 / 45001 内容安全 / 50000 系统
export const E = {
  param: (msg = '参数错误', data = null) => new HttpError(40001, msg, 400, data),
  unauth: (msg = '未登录或登录已过期') => new HttpError(40101, msg, 401),
  privacy: (msg = '对方设置了隐私权限', data = null) => new HttpError(40301, msg, 403, data),
  notFound: (msg = '资源不存在') => new HttpError(41001, msg, 404),
  rate: (msg = '操作过于频繁，请完成验证', data = { captcha_required: true }) => new HttpError(42901, msg, 429, data),
  content: (msg) => new HttpError(45001, msg, 450),
  system: (msg = '系统错误') => new HttpError(50000, msg, 500),
};
