import { E } from './respond.js';

export class Router {
  constructor() {
    this.routes = [];
  }

  add(method, pattern, opts, handler) {
    if (typeof opts === 'function') {
      handler = opts;
      opts = {};
    }
    const keys = [];
    const regex = new RegExp(
      '^' + pattern.replace(/:[^/]+/g, (m) => {
        keys.push(m.slice(1));
        return '([^/]+)';
      }) + '$'
    );
    this.routes.push({ method, pattern, regex, keys, opts: opts || {}, handler });
  }

  get(p, o, h) { this.add('GET', p, o, h); }
  post(p, o, h) { this.add('POST', p, o, h); }
  put(p, o, h) { this.add('PUT', p, o, h); }
  delete(p, o, h) { this.add('DELETE', p, o, h); }

  match(method, pathname) {
    for (const r of this.routes) {
      if (r.method !== method) continue;
      const m = r.regex.exec(pathname);
      if (!m) continue;
      const params = {};
      // 畸形 percent-encoding（如 %ZZ / 截断的 %E4%B8）decodeURIComponent 抛 URIError → 40001
      try {
        r.keys.forEach((k, i) => { params[k] = decodeURIComponent(m[i + 1]); });
      } catch {
        throw E.param('路径参数编码不合法');
      }
      return { route: r, params };
    }
    return null;
  }
}
