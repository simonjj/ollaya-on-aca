import assert from "node:assert/strict";
import test from "node:test";
import { DecisionCache } from "../lib/decision-cache.js";

test("DecisionCache reuses a decision without recounting Ollaya work", () => {
  let now = 1000;
  const cache = new DecisionCache({ ttlMs: 100, now: () => now });
  cache.set("fix the test", {
    route: "normal",
    ollayaDurationMs: 24,
    ollayaInputTokens: 300
  });

  assert.deepEqual(cache.get("fix the test"), {
    route: "normal",
    cacheHit: true,
    ollayaDurationMs: 0,
    ollayaInputTokens: 0
  });

  now = 1200;
  assert.equal(cache.get("fix the test"), null);
});
