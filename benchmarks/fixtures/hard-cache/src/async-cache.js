export class AsyncCache {
  #values = new Map();
  #inflight = new Map();

  async get(key, loader) {
    if (this.#values.has(key)) {
      return this.#values.get(key);
    }

    const pending = Promise.resolve().then(loader);
    this.#inflight.set(key, pending);
    const value = await pending;
    this.#values.set(key, value);
    this.#inflight.delete(key);
    return value;
  }

  clear(key) {
    this.#values.delete(key);
    this.#inflight.delete(key);
  }
}
