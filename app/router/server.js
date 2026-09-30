import { timingSafeEqual, randomUUID } from "node:crypto";
import http from "node:http";
import { DefaultAzureCredential } from "@azure/identity";
import { DecisionCache } from "./lib/decision-cache.js";
import {
  backendForRoute,
  decideRoute,
  extractLatestUserText,
  rewriteResponsesRequest
} from "./lib/routing.js";
import {
  addMetric,
  createSseUsageCollector,
  getMetrics,
  resetMetrics,
  usageFromPayload
} from "./lib/metrics.js";

const env = {
  PORT: Number(process.env.PORT ?? 8080),
  ROUTER_API_KEY: process.env.ROUTER_API_KEY ?? "",
  OLLAYA_URL: process.env.OLLAYA_URL ?? "http://127.0.0.1:11435",
  OLLAYA_MODEL: process.env.OLLAYA_MODEL ?? "coding-router",
  OLLAYA_TIMEOUT_MS: Number(process.env.OLLAYA_TIMEOUT_MS ?? 120000),
  AZURE_LUNA_ENDPOINT: normalizeAzureEndpoint(process.env.AZURE_LUNA_ENDPOINT),
  AZURE_LUNA_DEPLOYMENT: process.env.AZURE_LUNA_DEPLOYMENT ?? "gpt-5.6-luna",
  AZURE_TERRA_ENDPOINT: normalizeAzureEndpoint(process.env.AZURE_TERRA_ENDPOINT),
  AZURE_TERRA_DEPLOYMENT: process.env.AZURE_TERRA_DEPLOYMENT ?? "gpt-5.6-terra",
  AZURE_SOL_ENDPOINT: normalizeAzureEndpoint(process.env.AZURE_SOL_ENDPOINT),
  AZURE_SOL_DEPLOYMENT: process.env.AZURE_SOL_DEPLOYMENT ?? "gpt-5.6-sol",
  AZURE_CLIENT_ID: process.env.AZURE_CLIENT_ID,
  ROUTE_CACHE_TTL_MS: Number(process.env.ROUTE_CACHE_TTL_MS ?? 60 * 60 * 1000)
};

if (!env.ROUTER_API_KEY) {
  throw new Error("ROUTER_API_KEY is required.");
}
if (!env.AZURE_LUNA_ENDPOINT || !env.AZURE_TERRA_ENDPOINT || !env.AZURE_SOL_ENDPOINT) {
  throw new Error(
    "AZURE_LUNA_ENDPOINT, AZURE_TERRA_ENDPOINT, and AZURE_SOL_ENDPOINT are required."
  );
}

const credential = new DefaultAzureCredential(
  env.AZURE_CLIENT_ID ? { managedIdentityClientId: env.AZURE_CLIENT_ID } : {}
);
const decisionCache = new DecisionCache({ ttlMs: env.ROUTE_CACHE_TTL_MS });

function normalizeAzureEndpoint(value) {
  if (!value) {
    return "";
  }
  const root = value.replace(/\/+$/, "");
  return root.endsWith("/openai/v1") ? root : `${root}/openai/v1`;
}

function secureEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function isAuthorized(request) {
  const header = request.headers.authorization ?? "";
  return header.startsWith("Bearer ") && secureEqual(header.slice(7), env.ROUTER_API_KEY);
}

function sendJson(response, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
    ...headers
  });
  response.end(body);
}

async function readJson(request) {
  const chunks = [];
  let length = 0;

  for await (const chunk of request) {
    length += chunk.length;
    if (length > 8 * 1024 * 1024) {
      const error = new Error("Request body exceeds 8 MiB.");
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("Request body must be valid JSON.");
    error.status = 400;
    throw error;
  }
}

async function routeInput(body) {
  const text = extractLatestUserText(body);
  const cached = decisionCache.get(text);
  if (cached) {
    return cached;
  }

  const decision = await decideRoute({
    text,
    ollayaUrl: env.OLLAYA_URL,
    model: env.OLLAYA_MODEL,
    timeoutMs: env.OLLAYA_TIMEOUT_MS
  });
  decisionCache.set(text, decision);
  return { ...decision, cacheHit: false };
}

async function azureToken() {
  const token = await credential.getToken("https://cognitiveservices.azure.com/.default");
  if (!token?.token) {
    throw new Error("Managed identity did not return an Azure AI token.");
  }
  return token.token;
}

function copyUpstreamHeaders(upstream, response, route, backend) {
  for (const name of ["content-type", "cache-control", "x-request-id", "apim-request-id"]) {
    const value = upstream.headers.get(name);
    if (value) {
      response.setHeader(name, value);
    }
  }
  response.setHeader("x-ollaya-route", route);
  response.setHeader("x-ollaya-model", backend.model);
}

async function proxyResponses(request, response, body) {
  const requestId = request.headers["x-request-id"]?.toString() ?? randomUUID();
  const requestedModel = body.model;
  let decision;

  if (requestedModel === "ollaya-baseline") {
    decision = {
      route: "hard",
      reasons: ["baseline"],
      topProbability: 1,
      margin: 1,
      confidence: 1,
      probabilities: { hard: 1 },
      deepReasoning: 1,
      complexity: 2,
      concurrencyState: 1,
      ollayaModel: null,
      ollayaDurationMs: 0,
      ollayaInputTokens: 0,
      cacheHit: false
    };
  } else {
    decision = await routeInput(body);
  }

  const backend = backendForRoute(decision.route, env);
  const upstreamBody = rewriteResponsesRequest(body, backend);
  const controller = new AbortController();
  request.on("close", () => {
    if (!response.writableEnded) {
      controller.abort();
    }
  });

  const upstream = await fetch(`${backend.endpoint}/responses`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${await azureToken()}`,
      "content-type": "application/json",
      "x-request-id": requestId
    },
    body: JSON.stringify(upstreamBody),
    signal: controller.signal
  });

  copyUpstreamHeaders(upstream, response, decision.route, backend);
  response.statusCode = upstream.status;

  const contentType = upstream.headers.get("content-type") ?? "";
  let usage = null;

  if (contentType.includes("text/event-stream") && upstream.body) {
    const collector = createSseUsageCollector();
    for await (const chunk of upstream.body) {
      collector.push(chunk);
      response.write(Buffer.from(chunk));
    }
    usage = collector.finish();
    response.end();
  } else {
    const payloadText = await upstream.text();
    try {
      usage = usageFromPayload(JSON.parse(payloadText));
    } catch {
      usage = null;
    }
    response.end(payloadText);
  }

  const metric = {
    requestId,
    timestamp: new Date().toISOString(),
    requestedModel,
    route: decision.route,
    backendModel: backend.model,
    reasoningEffort: backend.reasoningEffort,
    status: upstream.status,
    decision,
    usage
  };
  addMetric(metric);
  console.log(JSON.stringify({ event: "request.complete", ...metric }));
}

async function health(response) {
  try {
    const ollaya = await fetch(env.OLLAYA_URL, { signal: AbortSignal.timeout(2000) });
    sendJson(response, ollaya.ok ? 200 : 503, {
      status: ollaya.ok ? "ok" : "degraded",
      ollaya: ollaya.ok ? "ready" : `http-${ollaya.status}`
    });
  } catch (error) {
    sendJson(response, 503, {
      status: "degraded",
      ollaya: error.message
    });
  }
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);

    if (request.method === "GET" && url.pathname === "/healthz") {
      await health(response);
      return;
    }

    if (!isAuthorized(request)) {
      sendJson(response, 401, { error: "Unauthorized" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/v1/models") {
      sendJson(response, 200, {
        object: "list",
        data: [
          {
            id: "ollaya-auto",
            object: "model",
            owned_by: "ollaya-on-aca"
          },
          {
            id: "ollaya-baseline",
            object: "model",
            owned_by: "ollaya-on-aca"
          }
        ]
      });
      return;
    }

    if (request.method === "POST" && url.pathname === "/route") {
      sendJson(response, 200, await routeInput(await readJson(request)));
      return;
    }

    if (request.method === "GET" && url.pathname === "/admin/metrics") {
      sendJson(response, 200, getMetrics());
      return;
    }

    if (request.method === "DELETE" && url.pathname === "/admin/metrics") {
      resetMetrics();
      decisionCache.clear();
      sendJson(response, 200, { status: "reset" });
      return;
    }

    if (request.method === "POST" && url.pathname === "/v1/responses") {
      await proxyResponses(request, response, await readJson(request));
      return;
    }

    sendJson(response, 404, { error: "Not found" });
  } catch (error) {
    if (response.headersSent) {
      response.destroy(error);
      return;
    }
    const status = error.status ?? (error.name === "AbortError" ? 504 : 500);
    console.error(JSON.stringify({ event: "request.error", status, error: error.message }));
    sendJson(response, status, { error: error.message });
  }
});

server.listen(env.PORT, "0.0.0.0", () => {
  console.log(JSON.stringify({ event: "server.ready", port: env.PORT }));
});
