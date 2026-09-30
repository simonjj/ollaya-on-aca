import { createHash, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { pipeline } from "node:stream/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { x as extractTar } from "tar";
import {
  coverageByThreshold,
  expectedCalibrationError,
  macroF1,
  percentile
} from "./lib/metrics.js";

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, "..");
const taxonomy = JSON.parse(readFileSync(join(root, "app", "taxonomy.json"), "utf8"));
const cacheRoot = join(root, ".cache", "massive-1.1");
const archivePath = join(cacheRoot, "amazon-massive-dataset-1.1.tar.gz");
const datasetPath = join(cacheRoot, "1.1", "data", "en-US.jsonl");
const datasetUrl =
  "https://amazon-massive-nlu-dataset.s3.amazonaws.com/amazon-massive-dataset-1.1.tar.gz";
const datasetSha256 = "4cba5faa11c71437928e17cb1b9b3d8b8e727e7ea363a3a9a8045e19c0491577";

function parseArgs(argv) {
  const options = {
    profile: "standard",
    provider: "both",
    mode: "latency",
    concurrency: 8,
    output: join(root, "benchmarks", "results.json"),
    limit: null
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (argument === "--profile") {
      options.profile = value;
      index += 1;
    } else if (argument === "--provider") {
      options.provider = value;
      index += 1;
    } else if (argument === "--mode") {
      options.mode = value;
      index += 1;
    } else if (argument === "--concurrency") {
      options.concurrency = Number(value);
      index += 1;
    } else if (argument === "--limit") {
      options.limit = Number(value);
      index += 1;
    } else if (argument === "--output") {
      options.output = resolve(value);
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  if (!["smoke", "standard"].includes(options.profile)) {
    throw new Error("--profile must be smoke or standard.");
  }
  if (!["winnow", "azure", "both"].includes(options.provider)) {
    throw new Error("--provider must be winnow, azure, or both.");
  }
  if (!["latency", "throughput", "both"].includes(options.mode)) {
    throw new Error("--mode must be latency, throughput, or both.");
  }
  if (!Number.isInteger(options.concurrency) || options.concurrency < 1) {
    throw new Error("--concurrency must be a positive integer.");
  }
  if (options.limit !== null && (!Number.isInteger(options.limit) || options.limit < 1)) {
    throw new Error("--limit must be a positive integer.");
  }
  return options;
}

async function sha256(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

async function ensureDataset() {
  mkdirSync(cacheRoot, { recursive: true });
  let download = true;
  try {
    download = (await sha256(archivePath)) !== datasetSha256;
  } catch {
    download = true;
  }
  if (download) {
    rmSync(archivePath, { force: true });
    const temporaryPath = `${archivePath}.${randomUUID()}.download`;
    const response = await fetch(datasetUrl, { signal: AbortSignal.timeout(300000) });
    if (!response.ok || !response.body) {
      throw new Error(`MASSIVE download returned ${response.status}.`);
    }
    await pipeline(Readable.fromWeb(response.body), createWriteStream(temporaryPath));
    if ((await sha256(temporaryPath)) !== datasetSha256) {
      rmSync(temporaryPath, { force: true });
      throw new Error("MASSIVE archive SHA-256 did not match the pinned value.");
    }
    renameSync(temporaryPath, archivePath);
  }
  try {
    statSync(datasetPath);
  } catch {
    await extractTar({
      file: archivePath,
      cwd: cacheRoot,
      filter: (path) =>
        path === "1.1/data/en-US.jsonl" ||
        path === "1.1/CITATION.md" ||
        path === "1.1/NOTICE.md"
    });
  }
}

async function loadRecords(options) {
  await ensureDataset();
  const records = [];
  const lines = createInterface({
    input: createReadStream(datasetPath, "utf8"),
    crlfDelay: Infinity
  });
  for await (const line of lines) {
    const row = JSON.parse(line);
    if (row.partition === "test") {
      records.push({
        id: String(row.id),
        text: row.utt,
        expectedScenario: row.scenario,
        expectedIntent: row.intent
      });
    }
  }
  records.sort((left, right) => left.id.localeCompare(right.id, "en", { numeric: true }));
  const profileLimit = options.profile === "smoke" ? 30 : records.length;
  return records.slice(0, options.limit ?? profileLimit);
}

function numberFromEnv(name) {
  const value = process.env[name];
  if (value === undefined || value === "") {
    return null;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative number.`);
  }
  return parsed;
}

function retryDelay(response, attempt) {
  const retryAfter = Number(response?.headers?.get("retry-after"));
  if (Number.isFinite(retryAfter) && retryAfter > 0) {
    return retryAfter * 1000;
  }
  return Math.min(30000, 1000 * 2 ** (attempt - 1));
}

async function callClassifier({ endpoint, apiKey, provider, record, timeoutMs }) {
  let lastError;
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    const startedAt = performance.now();
    let response;
    try {
      response = await fetch(`${endpoint}/v1/classify/${provider}`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
          "x-request-id": `benchmark-${provider}-${record.id}-${attempt}`
        },
        body: JSON.stringify({ text: record.text }),
        signal: AbortSignal.timeout(timeoutMs)
      });
      const clientDurationMs = Math.round((performance.now() - startedAt) * 1000) / 1000;
      const payload = await response.json();
      if (response.ok) {
        return { payload, clientDurationMs, attempts: attempt };
      }
      const error = new Error(
        `${provider} returned ${response.status}: ${payload.error ?? JSON.stringify(payload)}`
      );
      if (response.status < 500 && response.status !== 429) {
        throw error;
      }
      lastError = error;
    } catch (error) {
      lastError = error;
      if (error.name === "TimeoutError" || error.name === "AbortError") {
        lastError = new Error(`${provider} timed out after ${timeoutMs} ms.`);
      }
    }
    if (attempt < 8) {
      await new Promise((resolveDelay) =>
        setTimeout(resolveDelay, retryDelay(response, attempt))
      );
    }
  }
  throw lastError;
}

async function runProvider(provider, records, options, endpoint, apiKey) {
  const concurrency = options.mode === "latency" ? 1 : options.concurrency;
  const timeoutMs = Number(process.env.BENCHMARK_TIMEOUT_MS ?? 180000);
  const rows = new Array(records.length);
  let nextIndex = 0;
  let completed = 0;
  const startedAt = performance.now();

  async function worker() {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= records.length) {
        return;
      }
      const record = records[index];
      try {
        const { payload, clientDurationMs, attempts } = await callClassifier({
          endpoint,
          apiKey,
          provider,
          record,
          timeoutMs
        });
        rows[index] = {
          id: record.id,
          expectedScenario: record.expectedScenario,
          predictedScenario: payload.scenario.label,
          scenarioCorrect: payload.scenario.label === record.expectedScenario,
          expectedIntent: record.expectedIntent,
          predictedIntent: payload.intent.label,
          intentCorrect: payload.intent.label === record.expectedIntent,
          confidence:
            provider === "winnow"
              ? Number(payload.intent.probability ?? payload.intent.confidence ?? 0)
              : null,
          clientDurationMs,
          serverDurationMs: payload.durationMs,
          modelDurationMs: payload.modelDurationMs,
          attempts,
          usage: payload.usage
        };
      } catch (error) {
        rows[index] = {
          id: record.id,
          expectedScenario: record.expectedScenario,
          predictedScenario: null,
          scenarioCorrect: false,
          expectedIntent: record.expectedIntent,
          predictedIntent: null,
          intentCorrect: false,
          confidence: null,
          error: error.message
        };
      }
      completed += 1;
      if (completed % 100 === 0 || completed === records.length) {
        console.error(`${provider}: ${completed}/${records.length}`);
      }
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return {
    provider,
    mode: options.mode,
    concurrency,
    elapsedMs: Math.round(performance.now() - startedAt),
    rows
  };
}

function summarize(run) {
  const rows = run.rows;
  const successful = rows.filter((row) => !row.error);
  const durations = successful.map((row) => row.clientDurationMs);
  const usage = successful.reduce(
    (total, row) => {
      total.inputTokens += Number(row.usage?.inputTokens ?? 0);
      total.cachedInputTokens += Number(row.usage?.cachedInputTokens ?? 0);
      total.outputTokens += Number(row.usage?.outputTokens ?? 0);
      total.reasoningTokens += Number(row.usage?.reasoningTokens ?? 0);
      return total;
    },
    { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0 }
  );
  const inputRate = numberFromEnv("AZURE_INPUT_USD_PER_MILLION");
  const cachedRate = numberFromEnv("AZURE_CACHED_INPUT_USD_PER_MILLION");
  const outputRate = numberFromEnv("AZURE_OUTPUT_USD_PER_MILLION");
  const gpuRate = numberFromEnv("T4_USD_PER_SECOND");
  const nonCachedInput = Math.max(0, usage.inputTokens - usage.cachedInputTokens);
  const azureCost =
    run.provider === "azure" &&
    inputRate !== null &&
    cachedRate !== null &&
    outputRate !== null
      ? (nonCachedInput * inputRate +
          usage.cachedInputTokens * cachedRate +
          usage.outputTokens * outputRate) /
        1_000_000
      : null;
  const gpuCost =
    run.provider === "winnow" && gpuRate !== null
      ? (run.elapsedMs / 1000) * gpuRate
      : null;

  return {
    provider: run.provider,
    mode: run.mode,
    concurrency: run.concurrency,
    records: rows.length,
    successful: successful.length,
    failed: rows.length - successful.length,
    intentAccuracy: rows.filter((row) => row.intentCorrect).length / rows.length,
    intentMacroF1: macroF1(
      rows,
      Object.keys(taxonomy.intent.criteria),
      "expectedIntent",
      "predictedIntent"
    ),
    scenarioAccuracy: rows.filter((row) => row.scenarioCorrect).length / rows.length,
    latencyMs: {
      p50: percentile(durations, 0.5),
      p95: percentile(durations, 0.95),
      p99: percentile(durations, 0.99)
    },
    elapsedMs: run.elapsedMs,
    requestsPerSecond: rows.length / (run.elapsedMs / 1000),
    usage,
    estimatedCostUsd: run.provider === "azure" ? azureCost : gpuCost,
    calibration:
      run.provider === "winnow"
        ? {
            expectedCalibrationError: expectedCalibrationError(rows),
            coverage: coverageByThreshold(rows, [0.5, 0.6, 0.7, 0.8, 0.9])
          }
        : null
  };
}

const options = parseArgs(process.argv.slice(2));
const endpoint = process.env.CLASSIFIER_ENDPOINT?.replace(/\/$/, "");
const apiKey = process.env.CLASSIFIER_API_KEY;
if (!endpoint || !apiKey) {
  throw new Error("Set CLASSIFIER_ENDPOINT and CLASSIFIER_API_KEY.");
}

const records = await loadRecords(options);
const providers = options.provider === "both" ? ["winnow", "azure"] : [options.provider];
const modes = options.mode === "both" ? ["latency", "throughput"] : [options.mode];
const runs = [];
for (const mode of modes) {
  for (const provider of providers) {
    runs.push(
      await runProvider(provider, records, { ...options, mode }, endpoint, apiKey)
    );
  }
}

const gitResult = spawnSync("git", ["rev-parse", "HEAD"], {
  cwd: root,
  encoding: "utf8"
});
const report = {
  generatedAt: new Date().toISOString(),
  commit: gitResult.status === 0 ? gitResult.stdout.trim() : null,
  endpoint,
  dataset: {
    name: "Amazon MASSIVE",
    version: "1.1",
    locale: "en-US",
    split: "test",
    source: datasetUrl,
    sha256: datasetSha256,
    records: records.length,
    recordIds: records.map((record) => record.id)
  },
  configuration: {
    profile: options.profile,
    modes,
    requestedConcurrency: options.concurrency,
    providers,
    deployment: {
      mode: process.env.DEPLOYMENT_MODE ?? null,
      acaRegion: process.env.ACA_REGION ?? null,
      azureOpenAIRegion: process.env.AZURE_OPENAI_REGION ?? null,
      workloadProfile: process.env.GPU_WORKLOAD_PROFILE ?? null,
      gpuMinReplicas: numberFromEnv("GPU_MIN_REPLICAS"),
      ollayaModel: process.env.OLLAYA_MODEL ?? "massive-classifier",
      ollayaBaseModel: process.env.OLLAYA_BASE_MODEL ?? "winnow:e4b",
      ollayaVersion: process.env.OLLAYA_VERSION ?? null,
      ollayaImageDigest: process.env.OLLAYA_IMAGE_DIGEST ?? null,
      apiImageDigest: process.env.API_IMAGE_DIGEST ?? null,
      azureModel: process.env.AZURE_OPENAI_MODEL ?? "gpt-5.4-nano",
      azureModelVersion: process.env.AZURE_OPENAI_MODEL_VERSION ?? null,
      azureDeploymentSku: process.env.AZURE_OPENAI_DEPLOYMENT_SKU ?? null,
      azureDeploymentCapacity: numberFromEnv("AZURE_OPENAI_DEPLOYMENT_CAPACITY")
    },
    startupMeasurements: {
      firstModelPullSeconds: numberFromEnv("FIRST_MODEL_PULL_SECONDS"),
      cachedRevisionReadySeconds: numberFromEnv("CACHED_REVISION_READY_SECONDS"),
      cachedFirstInferenceMs: numberFromEnv("CACHED_FIRST_INFERENCE_MS")
    },
    azurePricingUsdPerMillion: {
      input: numberFromEnv("AZURE_INPUT_USD_PER_MILLION"),
      cachedInput: numberFromEnv("AZURE_CACHED_INPUT_USD_PER_MILLION"),
      output: numberFromEnv("AZURE_OUTPUT_USD_PER_MILLION")
    },
    t4UsdPerSecond: numberFromEnv("T4_USD_PER_SECOND")
  },
  summaries: runs.map(summarize),
  runs
};

mkdirSync(dirname(options.output), { recursive: true });
writeFileSync(options.output, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ output: options.output, summaries: report.summaries }, null, 2));
