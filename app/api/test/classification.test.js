import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import {
  createAzureRequest,
  getOllayaModelStatus,
  loadTaxonomy,
  normalizeAzureResponse,
  normalizeOllayaResponse
} from "../lib/classification.js";

const taxonomy = loadTaxonomy(join(import.meta.dirname, "..", "..", "taxonomy.json"));

test("taxonomy contains the MASSIVE scenario and intent counts", () => {
  assert.equal(Object.keys(taxonomy.scenario.criteria).length, 18);
  assert.equal(Object.keys(taxonomy.intent.criteria).length, 60);
});

test("normalizes an Ollaya decision", () => {
  const result = normalizeOllayaResponse(
    {
      model: "massive-classifier",
      total_duration: 125000000,
      usage: { input_tokens: 42 },
      answers: {
        scenario: {
          choice: "alarm",
          confidence: 0.9,
          probabilities: { alarm: 0.9, datetime: 0.1 }
        },
        intent: {
          choice: "alarm_set",
          confidence: 0.8,
          probabilities: { alarm_set: 0.8, alarm_query: 0.2 }
        }
      }
    },
    taxonomy,
    150
  );
  assert.equal(result.scenario.label, "alarm");
  assert.equal(result.intent.label, "alarm_set");
  assert.equal(result.modelDurationMs, 125);
  assert.equal(result.usage.inputTokens, 42);
});

test("creates a strict Azure structured-output request", () => {
  const request = createAzureRequest({
    text: "play the news",
    deployment: "gpt-5.4-nano",
    reasoningEffort: "none",
    taxonomy
  });
  assert.equal(request.text.format.strict, true);
  assert.equal(request.text.format.schema.properties.intent.enum.length, 60);
  assert.equal(request.reasoning.effort, "none");
});

test("normalizes an Azure Responses API result", () => {
  const result = normalizeAzureResponse(
    {
      id: "response-1",
      output: [
        {
          content: [
            {
              type: "output_text",
              text: "{\"scenario\":\"news\",\"intent\":\"news_query\"}"
            }
          ]
        }
      ],
      usage: {
        input_tokens: 500,
        output_tokens: 20,
        input_tokens_details: { cached_tokens: 100 },
        output_tokens_details: { reasoning_tokens: 5 }
      }
    },
    taxonomy,
    250,
    "gpt-5.4-nano"
  );
  assert.equal(result.scenario.label, "news");
  assert.equal(result.intent.label, "news_query");
  assert.equal(result.usage.cachedInputTokens, 100);
});

test("reads the loaded Ollaya device and VRAM usage", async () => {
  const result = await getOllayaModelStatus({
    ollayaUrl: "http://ollaya",
    model: "massive-classifier",
    timeoutMs: 1000,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          models: [
            {
              name: "massive-classifier:latest",
              device: "cuda:0",
              size: 9000000000,
              size_vram: 8500000000,
              context_length: 4096
            }
          ]
        })
      )
  });
  assert.equal(result.device, "cuda:0");
  assert.equal(result.sizeVramBytes, 8500000000);
});
