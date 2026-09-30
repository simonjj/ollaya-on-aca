import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDirectory, "..");
const tasks = JSON.parse(readFileSync(join(root, "benchmarks", "tasks.json"), "utf8"));
const endpoint = process.env.OLLAYA_ROUTER_ENDPOINT?.replace(/\/$/, "");
const apiKey = process.env.OLLAYA_ROUTER_API_KEY;
const windowsOpenCode = join(
  process.env.APPDATA ?? "",
  "npm",
  "node_modules",
  "opencode-ai",
  "bin",
  "opencode.exe"
);
const opencode =
  process.env.OPENCODE_BIN ??
  (process.platform === "win32" && existsSync(windowsOpenCode) ? windowsOpenCode : "opencode");
const workRoot = join(root, "benchmark-work");

if (!endpoint || !apiKey) {
  throw new Error("Set OLLAYA_ROUTER_ENDPOINT and OLLAYA_ROUTER_API_KEY.");
}

async function routerFetch(path, options = {}) {
  let lastError;

  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      const response = await fetch(`${endpoint}${path}`, {
        ...options,
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
          ...options.headers
        },
        signal: AbortSignal.timeout(30000)
      });
      if (response.ok) {
        return response.json();
      }
      const message = `${path} returned ${response.status}: ${await response.text()}`;
      if (response.status < 500) {
        throw new Error(message);
      }
      lastError = new Error(message);
    } catch (error) {
      lastError = error;
    }
    if (attempt < 5) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, attempt * 1000));
    }
  }

  throw lastError;
}

function opencodeConfig(model) {
  return {
    $schema: "https://opencode.ai/config.json",
    model: `ollaya-aca/${model}`,
    provider: {
      "ollaya-aca": {
        npm: "@ai-sdk/openai",
        name: "Ollaya benchmark",
        options: {
          baseURL: `${endpoint}/v1`,
          apiKey
        },
        models: {
          [model]: {
            name: model,
            limit: { context: 922000, output: 128000 }
          }
        }
      }
    }
  };
}

function run(command, args, cwd, env = process.env, useShell = false) {
  const options = {
    cwd,
    env,
    encoding: "utf8",
    shell: useShell
  };
  const shellCommand = [command, ...args]
    .map((argument) => (/[\s"]/u.test(argument) ? `"${argument.replaceAll('"', '\\"')}"` : argument))
    .join(" ");
  const result = useShell
    ? spawnSync(shellCommand, options)
    : spawnSync(command, args, options);
  if (result.status !== 0) {
    throw new Error(
      `${basename(command)} failed in ${cwd}\n${result.stdout ?? ""}\n${result.stderr ?? ""}`
    );
  }
  return result;
}

async function runTask(task, model) {
  const taskRoot = join(workRoot, `${task.id}-${model}`);
  rmSync(taskRoot, { recursive: true, force: true });
  mkdirSync(taskRoot, { recursive: true });
  cpSync(join(root, "benchmarks", "fixtures", task.fixture), taskRoot, { recursive: true });

  const configPath = join(taskRoot, "opencode.json");
  writeFileSync(configPath, `${JSON.stringify(opencodeConfig(model), null, 2)}\n`);

  await routerFetch("/admin/metrics", { method: "DELETE" });
  const startedAt = performance.now();
  run(
    opencode,
    [
      "run",
      "--pure",
      "--auto",
      "--format",
      "json",
      "--title",
      `${task.id}-${model}`,
      "-m",
      `ollaya-aca/${model}`,
      task.prompt
    ],
    taskRoot,
    {
      ...process.env,
      OPENCODE_CONFIG: configPath
    }
  );
  const durationMs = performance.now() - startedAt;
  run(task.validation[0], task.validation.slice(1), taskRoot, process.env, true);

  const metrics = await routerFetch("/admin/metrics");
  return {
    task: task.id,
    difficulty: task.difficulty,
    mode: model === "ollaya-auto" ? "routed" : "baseline",
    durationMs: Math.round(durationMs),
    requests: metrics.totals.requests,
    inputTokens: metrics.totals.inputTokens,
    outputTokens: metrics.totals.outputTokens,
    reasoningTokens: metrics.totals.reasoningTokens,
    totalTokens: metrics.totals.inputTokens + metrics.totals.outputTokens,
    ollayaInputTokens: metrics.totals.ollayaInputTokens,
    allModelTokens:
      metrics.totals.inputTokens +
      metrics.totals.outputTokens +
      metrics.totals.ollayaInputTokens,
    ollayaDurationMs: Math.round(metrics.totals.ollayaDurationMs),
    routes: metrics.records.map((record) => record.route)
  };
}

rmSync(workRoot, { recursive: true, force: true });
mkdirSync(workRoot, { recursive: true });

const results = [];
for (const task of tasks) {
  results.push(await runTask(task, "ollaya-auto"));
  results.push(await runTask(task, "ollaya-baseline"));
}

const totals = Object.groupBy(results, (result) => result.mode);
const summary = Object.fromEntries(
  Object.entries(totals).map(([mode, rows]) => [
    mode,
    rows.reduce(
      (total, row) => {
        total.tasks += 1;
        total.inputTokens += row.inputTokens;
        total.outputTokens += row.outputTokens;
        total.reasoningTokens += row.reasoningTokens;
        total.totalTokens += row.totalTokens;
        total.ollayaInputTokens += row.ollayaInputTokens;
        total.allModelTokens += row.allModelTokens;
        total.durationMs += row.durationMs;
        return total;
      },
      {
        tasks: 0,
        inputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0,
        ollayaInputTokens: 0,
        allModelTokens: 0,
        durationMs: 0
      }
    )
  ])
);

const report = {
  generatedAt: new Date().toISOString(),
  endpoint,
  results,
  summary
};

writeFileSync(join(root, "benchmarks", "results.json"), `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify(report, null, 2));
