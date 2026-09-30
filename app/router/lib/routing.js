const ROUTE_ORDER = ["trivial", "normal", "hard"];

function textFromContent(content) {
  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  return content
    .map((part) => {
      if (typeof part === "string") {
        return part;
      }
      if (!part || typeof part !== "object") {
        return "";
      }
      if (typeof part.text === "string") {
        return part.text;
      }
      if (typeof part.input_text === "string") {
        return part.input_text;
      }
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

export function extractLatestUserText(body) {
  if (typeof body?.input === "string") {
    return body.input;
  }

  if (Array.isArray(body?.input)) {
    for (let index = body.input.length - 1; index >= 0; index -= 1) {
      const item = body.input[index];
      if (!item || typeof item !== "object" || item.role !== "user") {
        continue;
      }
      const text = textFromContent(item.content);
      if (text) {
        return text;
      }
    }

    const fallback = textFromContent(body.input.at(-1)?.content);
    if (fallback) {
      return fallback;
    }
  }

  if (Array.isArray(body?.messages)) {
    for (let index = body.messages.length - 1; index >= 0; index -= 1) {
      const message = body.messages[index];
      if (message?.role === "user") {
        const text = textFromContent(message.content);
        if (text) {
          return text;
        }
      }
    }
  }

  return "";
}

function promote(route, minimum) {
  return ROUTE_ORDER.indexOf(route) < ROUTE_ORDER.indexOf(minimum) ? minimum : route;
}

export function applySafetyPolicy(
  ollayaResponse,
  {
    minimumProbability = 0.36,
    minimumMargin = 0,
    deepReasoningNormal = 0.45,
    deepReasoningHard = 0.72,
    complexityNormal = 1.25,
    complexityHard = 1.55,
    concurrencyHard = 0.7
  } = {}
) {
  const routeAnswer = ollayaResponse?.answers?.route;
  const probabilities = routeAnswer?.probabilities ?? {};
  let route = ROUTE_ORDER.includes(routeAnswer?.choice) ? routeAnswer.choice : "normal";

  const ranked = Object.values(probabilities)
    .filter((value) => Number.isFinite(value))
    .sort((left, right) => right - left);
  const topProbability = Number(probabilities[route] ?? ranked[0] ?? 0);
  const margin = ranked.length > 1 ? ranked[0] - ranked[1] : topProbability;
  const deepReasoning = Number(ollayaResponse?.answers?.deep_reasoning?.noul ?? 0);
  const complexity = Number(ollayaResponse?.answers?.complexity?.score ?? 0);
  const concurrencyState = Number(ollayaResponse?.answers?.concurrency_state?.noul ?? 0);

  const reasons = [`ollaya:${route}`];
  if (topProbability < minimumProbability || margin < minimumMargin) {
    route = promote(route, "normal");
    reasons.push("uncertain");
  }
  if (
    deepReasoning >= deepReasoningHard ||
    complexity >= complexityHard ||
    concurrencyState >= concurrencyHard
  ) {
    route = "hard";
    reasons.push("deep");
  } else {
    if (deepReasoning >= deepReasoningNormal) {
      route = promote(route, "normal");
      reasons.push("reasoning");
    }
    if (complexity >= complexityNormal) {
      route = promote(route, "normal");
      reasons.push("complexity");
    }
  }

  return {
    route,
    reasons,
    topProbability,
    margin,
    confidence: Number(routeAnswer?.confidence ?? 0),
    probabilities,
    deepReasoning,
    complexity,
    concurrencyState,
    ollayaModel: ollayaResponse?.model ?? null,
    ollayaDurationMs: Number(ollayaResponse?.total_duration ?? 0) / 1_000_000,
    ollayaInputTokens: Number(ollayaResponse?.usage?.input_tokens ?? 0)
  };
}

export async function decideRoute({
  text,
  ollayaUrl,
  model = "coding-router",
  timeoutMs = 5000,
  fetchImpl = fetch,
  policy
}) {
  if (!text.trim()) {
    return {
      route: "normal",
      reasons: ["empty-input"],
      topProbability: 0,
      margin: 0,
      confidence: 0,
      probabilities: {},
      deepReasoning: 0,
      complexity: 1,
      concurrencyState: 0,
      ollayaModel: null,
      ollayaDurationMs: 0,
      ollayaInputTokens: 0
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetchImpl(`${ollayaUrl.replace(/\/$/, "")}/api/decide`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model,
        state: text,
        keep_alive: "-1"
      }),
      signal: controller.signal
    });

    if (!response.ok) {
      throw new Error(`Ollaya returned ${response.status}: ${await response.text()}`);
    }

    return applySafetyPolicy(await response.json(), policy);
  } finally {
    clearTimeout(timeout);
  }
}

export function backendForRoute(route, env) {
  if (route === "trivial") {
    return {
      route,
      endpoint: env.AZURE_LUNA_ENDPOINT,
      model: env.AZURE_LUNA_DEPLOYMENT,
      reasoningEffort: "none"
    };
  }

  if (route === "normal") {
    return {
      route,
      endpoint: env.AZURE_TERRA_ENDPOINT,
      model: env.AZURE_TERRA_DEPLOYMENT,
      reasoningEffort: "medium"
    };
  }

  return {
    route,
    endpoint: env.AZURE_SOL_ENDPOINT,
    model: env.AZURE_SOL_DEPLOYMENT,
    reasoningEffort: "high"
  };
}

export function rewriteResponsesRequest(body, backend) {
  const reasoning =
    body.reasoning && typeof body.reasoning === "object" && !Array.isArray(body.reasoning)
      ? { ...body.reasoning }
      : {};

  reasoning.effort = backend.reasoningEffort;

  const rewritten = {
    ...body,
    model: backend.model,
    reasoning
  };

  delete rewritten.reasoning_effort;
  return rewritten;
}
