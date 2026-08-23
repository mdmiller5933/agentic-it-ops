// Minimal CDP client over WebSocket (Node >=21 global WebSocket). No deps.
// Usage as library: import { CDP } from "./cdp.mjs"
export class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.id = 0;
    this.pending = new Map();
    this.events = [];
  }
  static async targets(port = 9223) {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`);
    return res.json();
  }
  static async newTab(port = 9223, url = "about:blank") {
    const res = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
    return res.json();
  }
  async connect() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = (e) => reject(new Error("ws error"));
    });
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method) {
        this.events.push(msg);
        if (this.events.length > 5000) this.events.shift();
      }
    };
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, 30000);
    });
  }
  async eval(expression, { awaitPromise = true } = {}) {
    const r = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: true,
    });
    if (r.exceptionDetails) throw new Error("JS exception: " + JSON.stringify(r.exceptionDetails).slice(0, 800));
    return r.result?.value;
  }
  async navigate(url) {
    await this.send("Page.enable");
    await this.send("Page.navigate", { url });
  }
  async waitForLoad(timeoutMs = 25000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const state = await this.eval("document.readyState").catch(() => null);
      if (state === "complete") return true;
      await new Promise((r) => setTimeout(r, 500));
    }
    return false;
  }
  async url() {
    return this.eval("location.href").catch(() => null);
  }
  close() {
    try { this.ws.close(); } catch {}
  }
}
