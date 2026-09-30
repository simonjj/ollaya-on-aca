import { timingSafeEqual, randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import { DefaultAzureCredential } from "@azure/identity";
import {
  classifyWithAzure,
  classifyWithWinnow,
  getOllayaModelStatus,
  loadTaxonomy
} from "./lib/classification.js";

const directory = dirname(fileURLToPath(import.meta.url));
const taxonomy = loadTaxonomy(join(directory, "taxonomy.json"));
const env = {
  PORT: Number(process.env.PORT ?? 8080),
  CLASSIFIER_API_KEY: process.env.CLASSIFIER_API_KEY ?? "",
  OLLAYA_URL: process.env.OLLAYA_URL ?? "http://127.0.0.1:11435",
  OLLAYA_MODEL: process.env.OLLAYA_MODEL ?? "massive-classifier",
  OLLAYA_TIMEOUT_MS: Number(process.env.OLLAYA_TIMEOUT_MS ?? 600000),
  OLLAYA_REQUIRED_DEVICE: process.env.OLLAYA_REQUIRED_DEVICE ?? "",
  ENABLE_AZURE: String(process.env.ENABLE_AZURE ?? "true").toLowerCase() === "true",
  AZURE_OPENAI_ENDPOINT: normalizeAzureEndpoint(process.env.AZURE_OPENAI_ENDPOINT),
  AZURE_OPENAI_DEPLOYMENT: process.env.AZURE_OPENAI_DEPLOYMENT ?? "gpt-5.4-nano",
  AZURE_REASONING_EFFORT: process.env.AZURE_REASONING_EFFORT ?? "none",
  AZURE_TIMEOUT_MS: Number(process.env.AZURE_TIMEOUT_MS ?? 120000),
  AZURE_CLIENT_ID: process.env.AZURE_CLIENT_ID
};

if (!env.CLASSIFIER_API_KEY) {
  throw new Error("CLASSIFIER_API_KEY is required.");
}
if (env.ENABLE_AZURE && !env.AZURE_OPENAI_ENDPOINT) {
  throw new Error("AZURE_OPENAI_ENDPOINT is required when ENABLE_AZURE=true.");
}

const credential = env.ENABLE_AZURE
  ? new DefaultAzureCredential(
      env.AZURE_CLIENT_ID ? { managedIdentityClientId: env.AZURE_CLIENT_ID } : {}
    )
  : null;

let readyResult = null;
let readyPromise = null;

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
  return header.startsWith("Bearer ") && secureEqual(header.slice(7), env.CLASSIFIER_API_KEY);
}

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body)
  });
  response.end(body);
}

async function readJson(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 1024 * 1024) {
      const error = new Error("Request body exceeds 1 MiB.");
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

function inputText(body) {
  const text = body?.text;
  if (typeof text !== "string" || !text.trim()) {
    const error = new Error("text must be a non-empty string.");
    error.status = 400;
    throw error;
  }
  if (text.length > 20000) {
    const error = new Error("text must not exceed 20,000 characters.");
    error.status = 400;
    throw error;
  }
  return text.trim();
}

async function azureToken() {
  const token = await credential.getToken("https://cognitiveservices.azure.com/.default");
  if (!token?.token) {
    throw new Error("Managed identity did not return an Azure AI token.");
  }
  return token.token;
}

async function classifyWinnow(text) {
  return classifyWithWinnow({
    text,
    ollayaUrl: env.OLLAYA_URL,
    model: env.OLLAYA_MODEL,
    taxonomy,
    timeoutMs: env.OLLAYA_TIMEOUT_MS
  });
}

async function classifyAzure(text) {
  if (!env.ENABLE_AZURE) {
    const error = new Error("Azure classification is disabled in ollaya-only mode.");
    error.status = 503;
    throw error;
  }
  return classifyWithAzure({
    text,
    endpoint: env.AZURE_OPENAI_ENDPOINT,
    deployment: env.AZURE_OPENAI_DEPLOYMENT,
    reasoningEffort: env.AZURE_REASONING_EFFORT,
    taxonomy,
    accessToken: await azureToken(),
    timeoutMs: env.AZURE_TIMEOUT_MS
  });
}

async function ollayaModelStatus() {
  const status = await getOllayaModelStatus({
    ollayaUrl: env.OLLAYA_URL,
    model: env.OLLAYA_MODEL,
    timeoutMs: env.OLLAYA_TIMEOUT_MS
  });
  if (
    env.OLLAYA_REQUIRED_DEVICE &&
    (!status.device?.startsWith(env.OLLAYA_REQUIRED_DEVICE) || status.sizeVramBytes <= 0)
  ) {
    throw new Error(
      `Ollaya loaded ${status.model} on ${status.device ?? "an unknown device"} with ` +
        `${status.sizeVramBytes} VRAM bytes; expected ${env.OLLAYA_REQUIRED_DEVICE}.`
    );
  }
  return status;
}

async function ensureReady() {
  if (readyResult) {
    return readyResult;
  }
  if (!readyPromise) {
    readyPromise = classifyWinnow("set an alarm for seven tomorrow morning")
      .then(async (result) => {
        const modelStatus = await ollayaModelStatus();
        readyResult = {
          status: "ready",
          model: result.model,
          device: modelStatus.device,
          sizeVramBytes: modelStatus.sizeVramBytes,
          warmupDurationMs: result.durationMs,
          scenario: result.scenario.label,
          intent: result.intent.label
        };
        console.log(JSON.stringify({ event: "model.ready", ...readyResult }));
        return readyResult;
      })
      .finally(() => {
        readyPromise = null;
      });
  }
  return readyPromise;
}

const server = http.createServer(async (request, response) => {
  const requestId = request.headers["x-request-id"]?.toString() ?? randomUUID();
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);

    if (request.method === "GET" && url.pathname === "/healthz") {
      sendJson(response, 200, { status: "ok" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/readyz") {
      try {
        sendJson(response, 200, await ensureReady());
      } catch (error) {
        sendJson(response, 503, { status: "not-ready", error: error.message });
      }
      return;
    }

    if (!isAuthorized(request)) {
      sendJson(response, 401, { error: "Unauthorized", requestId });
      return;
    }

    if (request.method === "GET" && url.pathname === "/v1/taxonomy") {
      sendJson(response, 200, taxonomy);
      return;
    }

    if (request.method === "POST" && url.pathname.startsWith("/v1/classify/")) {
      const text = inputText(await readJson(request));
      let result;
      if (url.pathname === "/v1/classify/winnow") {
        result = await classifyWinnow(text);
      } else if (url.pathname === "/v1/classify/azure") {
        result = await classifyAzure(text);
      } else if (url.pathname === "/v1/classify/compare") {
        const [winnow, azure] = await Promise.allSettled([
          classifyWinnow(text),
          classifyAzure(text)
        ]);
        result = {
          provider: "compare",
          winnow:
            winnow.status === "fulfilled"
              ? winnow.value
              : { error: winnow.reason?.message ?? String(winnow.reason) },
          azure:
            azure.status === "fulfilled"
              ? azure.value
              : { error: azure.reason?.message ?? String(azure.reason) }
        };
      } else {
        sendJson(response, 404, { error: "Not found", requestId });
        return;
      }
      console.log(
        JSON.stringify({
          event: "classification.complete",
          requestId,
          provider: result.provider,
          durationMs: result.durationMs
        })
      );
      sendJson(response, 200, { requestId, ...result });
      return;
    }

    sendJson(response, 404, { error: "Not found", requestId });
  } catch (error) {
    const status =
      error.status ??
      (error.name === "TimeoutError" || error.name === "AbortError" ? 504 : 500);
    console.error(JSON.stringify({ event: "request.error", requestId, status, error: error.message }));
    sendJson(response, status, { error: error.message, requestId });
  }
});

server.listen(env.PORT, "0.0.0.0", () => {
  console.log(
    JSON.stringify({
      event: "server.ready",
      port: env.PORT,
      mode: env.ENABLE_AZURE ? "full" : "ollaya-only"
    })
  );
  ensureReady().catch((error) => {
    console.error(JSON.stringify({ event: "model.warmup-failed", error: error.message }));
  });
});
