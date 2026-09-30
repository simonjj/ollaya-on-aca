import { readFileSync } from "node:fs";

export function loadTaxonomy(path) {
  const taxonomy = JSON.parse(readFileSync(path, "utf8"));
  validateTaxonomy(taxonomy);
  return taxonomy;
}

export function validateTaxonomy(taxonomy) {
  for (const [name, count] of [
    ["scenario", 18],
    ["intent", 60]
  ]) {
    const question = taxonomy?.[name];
    if (question?.type !== "choice" || typeof question.instructions !== "string") {
      throw new Error(`Taxonomy question ${name} must be a choice with instructions.`);
    }
    const labels = Object.keys(question.criteria ?? {});
    if (labels.length !== count) {
      throw new Error(`Taxonomy question ${name} must contain ${count} labels, found ${labels.length}.`);
    }
    if (Object.values(question.criteria).some((description) => !String(description).trim())) {
      throw new Error(`Taxonomy question ${name} contains an empty label description.`);
    }
  }
}

function normalizeProbabilities(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return Object.fromEntries(
    Object.entries(value)
      .filter(([, probability]) => Number.isFinite(Number(probability)))
      .map(([label, probability]) => [label, Number(probability)])
  );
}

function normalizeChoice(answer, allowedLabels, name) {
  const label = answer?.choice;
  if (!allowedLabels.includes(label)) {
    throw new Error(`Ollaya returned an invalid ${name} label: ${String(label)}`);
  }
  const probabilities = normalizeProbabilities(answer.probabilities);
  return {
    label,
    confidence: Number(answer.confidence ?? probabilities[label] ?? 0),
    probability: Number(probabilities[label] ?? 0),
    probabilities
  };
}

export function normalizeOllayaResponse(payload, taxonomy, durationMs) {
  return {
    provider: "winnow",
    model: payload?.model ?? null,
    scenario: normalizeChoice(
      payload?.answers?.scenario,
      Object.keys(taxonomy.scenario.criteria),
      "scenario"
    ),
    intent: normalizeChoice(
      payload?.answers?.intent,
      Object.keys(taxonomy.intent.criteria),
      "intent"
    ),
    durationMs,
    modelDurationMs: Number(payload?.total_duration ?? 0) / 1_000_000,
    usage: {
      inputTokens: Number(payload?.usage?.input_tokens ?? 0),
      outputTokens: 0,
      reasoningTokens: 0,
      cachedInputTokens: 0
    }
  };
}

export async function classifyWithWinnow({
  text,
  ollayaUrl,
  model,
  taxonomy,
  timeoutMs,
  fetchImpl = fetch
}) {
  const startedAt = performance.now();
  const response = await fetchImpl(`${ollayaUrl.replace(/\/$/, "")}/api/decide`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model,
      state: text,
      keep_alive: "-1"
    }),
    signal: AbortSignal.timeout(timeoutMs)
  });

  if (!response.ok) {
    throw new Error(`Ollaya returned ${response.status}: ${await response.text()}`);
  }

  return normalizeOllayaResponse(
    await response.json(),
    taxonomy,
    Math.round((performance.now() - startedAt) * 1000) / 1000
  );
}

export async function getOllayaModelStatus({
  ollayaUrl,
  model,
  timeoutMs,
  fetchImpl = fetch
}) {
  const response = await fetchImpl(`${ollayaUrl.replace(/\/$/, "")}/api/ps`, {
    signal: AbortSignal.timeout(timeoutMs)
  });
  if (!response.ok) {
    throw new Error(`Ollaya model status returned ${response.status}: ${await response.text()}`);
  }
  const payload = await response.json();
  const canonicalModel = model.includes(":") ? model : `${model}:latest`;
  const loaded = payload?.models?.find(
    (candidate) => candidate?.name === canonicalModel || candidate?.model === canonicalModel
  );
  if (!loaded) {
    throw new Error(`Ollaya model ${canonicalModel} is not loaded.`);
  }
  return {
    model: loaded.name ?? loaded.model,
    device: loaded.device ?? null,
    sizeBytes: Number(loaded.size ?? 0),
    sizeVramBytes: Number(loaded.size_vram ?? 0),
    contextLength: Number(loaded.context_length ?? 0)
  };
}

function formatTaxonomy(question) {
  return Object.entries(question.criteria)
    .map(([label, description]) => `- ${label}: ${description}`)
    .join("\n");
}

export function azureInstructions(taxonomy) {
  return [
    "Classify the user utterance using the Amazon MASSIVE taxonomy.",
    "Return exactly one scenario and one intent from the allowed labels.",
    "Do not rewrite, answer, or explain the utterance.",
    "",
    "Scenario labels:",
    formatTaxonomy(taxonomy.scenario),
    "",
    "Intent labels:",
    formatTaxonomy(taxonomy.intent)
  ].join("\n");
}

export function createAzureRequest({ text, deployment, reasoningEffort, taxonomy }) {
  return {
    model: deployment,
    instructions: azureInstructions(taxonomy),
    input: text,
    reasoning: {
      effort: reasoningEffort
    },
    text: {
      format: {
        type: "json_schema",
        name: "massive_classification",
        strict: true,
        schema: {
          type: "object",
          properties: {
            scenario: {
              type: "string",
              enum: Object.keys(taxonomy.scenario.criteria)
            },
            intent: {
              type: "string",
              enum: Object.keys(taxonomy.intent.criteria)
            }
          },
          required: ["scenario", "intent"],
          additionalProperties: false
        }
      }
    },
    max_output_tokens: 128,
    store: false
  };
}

export function responseOutputText(payload) {
  if (typeof payload?.output_text === "string" && payload.output_text) {
    return payload.output_text;
  }
  for (const item of payload?.output ?? []) {
    for (const content of item?.content ?? []) {
      if (content?.type === "output_text" && typeof content.text === "string") {
        return content.text;
      }
    }
  }
  throw new Error("Azure OpenAI response did not contain output text.");
}

export function normalizeAzureResponse(payload, taxonomy, durationMs, deployment) {
  const parsed = JSON.parse(responseOutputText(payload));
  const scenarios = Object.keys(taxonomy.scenario.criteria);
  const intents = Object.keys(taxonomy.intent.criteria);
  if (!scenarios.includes(parsed.scenario)) {
    throw new Error(`Azure OpenAI returned an invalid scenario label: ${String(parsed.scenario)}`);
  }
  if (!intents.includes(parsed.intent)) {
    throw new Error(`Azure OpenAI returned an invalid intent label: ${String(parsed.intent)}`);
  }
  return {
    provider: "azure",
    model: deployment,
    scenario: { label: parsed.scenario },
    intent: { label: parsed.intent },
    durationMs,
    modelDurationMs: null,
    usage: {
      inputTokens: Number(payload?.usage?.input_tokens ?? 0),
      outputTokens: Number(payload?.usage?.output_tokens ?? 0),
      reasoningTokens: Number(payload?.usage?.output_tokens_details?.reasoning_tokens ?? 0),
      cachedInputTokens: Number(payload?.usage?.input_tokens_details?.cached_tokens ?? 0)
    },
    requestId: payload?.id ?? null
  };
}

export async function classifyWithAzure({
  text,
  endpoint,
  deployment,
  reasoningEffort,
  taxonomy,
  accessToken,
  timeoutMs,
  fetchImpl = fetch
}) {
  const startedAt = performance.now();
  const response = await fetchImpl(`${endpoint.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(createAzureRequest({ text, deployment, reasoningEffort, taxonomy })),
    signal: AbortSignal.timeout(timeoutMs)
  });

  if (!response.ok) {
    throw new Error(`Azure OpenAI returned ${response.status}: ${await response.text()}`);
  }

  return normalizeAzureResponse(
    await response.json(),
    taxonomy,
    Math.round((performance.now() - startedAt) * 1000) / 1000,
    deployment
  );
}
