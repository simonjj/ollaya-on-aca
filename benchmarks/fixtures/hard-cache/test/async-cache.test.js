import assert from "node:assert/strict";
import test from "node:test";
import { AsyncCache } from "../src/async-cache.js";

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((onResolve, onReject) => {
    resolve = onResolve;
    reject = onReject;
  });
  return { promise, resolve, reject };
};

test("deduplicates concurrent loads for one key", async () => {
  const cache = new AsyncCache();
  const gate = deferred();
  let calls = 0;
  const loader = async () => {
    calls += 1;
    return gate.promise;
  };

  const first = cache.get("a", loader);
  const second = cache.get("a", loader);
  gate.resolve(42);

  assert.deepEqual(await Promise.all([first, second]), [42, 42]);
  assert.equal(calls, 1);
});

test("does not cache loader failures", async () => {
  const cache = new AsyncCache();
  let calls = 0;
  await assert.rejects(
    cache.get("a", async () => {
      calls += 1;
      throw new Error("temporary");
    }),
    /temporary/
  );

  assert.equal(await cache.get("a", async () => ++calls), 2);
  assert.equal(calls, 2);
});

test("clear prevents an old in-flight value from becoming the cached value", async () => {
  const cache = new AsyncCache();
  const oldGate = deferred();
  const oldRequest = cache.get("a", () => oldGate.promise);

  cache.clear("a");
  assert.equal(await cache.get("a", async () => "new"), "new");

  oldGate.resolve("old");
  assert.equal(await oldRequest, "old");
  assert.equal(await cache.get("a", async () => "unexpected"), "new");
});
