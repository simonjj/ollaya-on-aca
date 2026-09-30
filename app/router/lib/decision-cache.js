import { createHash } from "node:crypto";

export class DecisionCache {
  #entries = new Map();

  constructor({ ttlMs = 60 * 60 * 1000, maxEntries = 1000, now = Date.now } = {}) {
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.now = now;
  }

  #key(text) {
    return createHash("sha256").update(text.trim()).digest("hex");
  }

  get(text) {
    if (!text.trim()) {
      return null;
    }

    const key = this.#key(text);
    const entry = this.#entries.get(key);
    if (!entry) {
      return null;
    }
    if (entry.expiresAt <= this.now()) {
      this.#entries.delete(key);
      return null;
    }

    this.#entries.delete(key);
    this.#entries.set(key, entry);
    return {
      ...structuredClone(entry.decision),
      cacheHit: true,
      ollayaDurationMs: 0,
      ollayaInputTokens: 0
    };
  }

  set(text, decision) {
    if (!text.trim()) {
      return;
    }

    const key = this.#key(text);
    this.#entries.delete(key);
    this.#entries.set(key, {
      expiresAt: this.now() + this.ttlMs,
      decision: structuredClone(decision)
    });

    while (this.#entries.size > this.maxEntries) {
      this.#entries.delete(this.#entries.keys().next().value);
    }
  }

  clear() {
    this.#entries.clear();
  }
}
