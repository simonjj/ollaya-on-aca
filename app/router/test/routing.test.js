import assert from "node:assert/strict";
import test from "node:test";
import {
  applySafetyPolicy,
  backendForRoute,
  extractLatestUserText,
  rewriteResponsesRequest
} from "../lib/routing.js";

test("extractLatestUserText reads the last Responses API user turn", () => {
  const body = {
    input: [
      { role: "user", content: [{ type: "input_text", text: "first" }] },
      { role: "assistant", content: [{ type: "output_text", text: "answer" }] },
      {
        role: "user",
        content: [
          { type: "input_text", text: "fix the failing test" },
          { type: "input_image", image_url: "data:image/png;base64,..." }
        ]
      }
    ]
  };

  assert.equal(extractLatestUserText(body), "fix the failing test");
});

test("applySafetyPolicy promotes uncertain trivial decisions", () => {
  const decision = applySafetyPolicy({
    model: "laya:en",
    answers: {
      route: {
        choice: "trivial",
        confidence: 0.05,
        probabilities: { trivial: 0.34, normal: 0.33, hard: 0.33 }
      },
      deep_reasoning: { noul: 0.1 },
      complexity: { score: 0.2 },
      concurrency_state: { noul: 0.1 }
    },
    usage: { input_tokens: 20 },
    total_duration: 12_000_000
  });

  assert.equal(decision.route, "normal");
  assert.ok(decision.reasons.includes("uncertain"));
});

test("applySafetyPolicy sends deep requests to hard", () => {
  const decision = applySafetyPolicy({
    answers: {
      route: {
        choice: "normal",
        confidence: 0.8,
        probabilities: { trivial: 0.05, normal: 0.85, hard: 0.1 }
      },
      deep_reasoning: { noul: 0.82 },
      complexity: { score: 1.2 },
      concurrency_state: { noul: 0.2 }
    }
  });

  assert.equal(decision.route, "hard");
});

test("applySafetyPolicy sends concurrency-sensitive requests to hard", () => {
  const decision = applySafetyPolicy({
    answers: {
      route: {
        choice: "normal",
        confidence: 0.5,
        probabilities: { trivial: 0.1, normal: 0.65, hard: 0.25 }
      },
      deep_reasoning: { noul: 0.2 },
      complexity: { score: 1.2 },
      concurrency_state: { noul: 0.82 }
    }
  });

  assert.equal(decision.route, "hard");
});

test("rewriteResponsesRequest selects the deployment and reasoning effort", () => {
  const backend = backendForRoute("hard", {
    AZURE_LUNA_ENDPOINT: "https://luna/openai/v1",
    AZURE_LUNA_DEPLOYMENT: "luna",
    AZURE_TERRA_ENDPOINT: "https://terra/openai/v1",
    AZURE_TERRA_DEPLOYMENT: "terra",
    AZURE_SOL_ENDPOINT: "https://sol/openai/v1",
    AZURE_SOL_DEPLOYMENT: "sol"
  });
  const rewritten = rewriteResponsesRequest(
    {
      model: "ollaya-auto",
      input: "debug this",
      reasoning: { summary: "auto" },
      reasoning_effort: "low"
    },
    backend
  );

  assert.equal(rewritten.model, "sol");
  assert.deepEqual(rewritten.reasoning, { summary: "auto", effort: "high" });
  assert.equal("reasoning_effort" in rewritten, false);
});
