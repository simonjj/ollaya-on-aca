# Pivot: Winnow classification benchmark on ACA

> Approved implementation brief. The historical `ollaya+opencode` tag was created before the pivot.

## Goal

Replace the OpenCode routing sample with a reproducible comparison between:

- Ollaya running `winnow:e4b` on an Azure Container Apps T4 serverless GPU
- Azure OpenAI `gpt-5.4-nano` using structured output
- Amazon MASSIVE 1.1, using the complete `en-US` test split

The repository must support:

1. A full deployment with Winnow, GPT-5.4 Nano, the classification API, and benchmark tooling.
2. An `ollaya-only` deployment with Winnow and a thin authenticated gateway, but no Azure OpenAI resources.

The benchmark must be a simple, performant CLI committed to the repository. There is no preset hosted-inference spending cap. Record estimated and actual cost.

## Preserve the current sample first

Before changing application or infrastructure code, verify and tag the current published commit:

```powershell
git fetch origin
git merge-base --is-ancestor 4112b187506b45ac969f0af9172306031cb39364 origin/main
git tag -a "ollaya+opencode" 4112b187506b45ac969f0af9172306031cb39364 `
  -m "Preserve the Ollaya and OpenCode routing sample"
git push origin "ollaya+opencode"
```

Do not move the tag after publishing it. Replace the OpenCode implementation on `main`; do not retain a duplicate legacy folder.

## Target architecture

```text
Benchmark CLI or client
          |
          v
Authenticated classification API on ACA
       |                         |
       v                         v
Internal Ollaya             Azure OpenAI
winnow:e4b on T4            GPT-5.4 Nano
```

Use managed identity for Azure OpenAI and disable local model keys. Do not expose the raw Ollaya API publicly.

Deploy the T4 workload in South Central US with `minReplicas=1` by default. Document `minReplicas=0` as an idle-cost option with cold-start tradeoffs. If T4 or GPT-5.4 Nano quota/availability blocks deployment, stop and report the exact blocker; do not switch models or regions silently.

Use a new validation environment such as `ollaya-test-2`. Do not delete the existing resources unless explicitly requested.

## Classification task

Use one checked-in taxonomy shared by both models:

- 18 MASSIVE scenarios
- 60 MASSIVE intents

Intent accuracy is the primary result; scenario accuracy is secondary. Both models must process the same record IDs and receive equivalent label names and descriptions.

Pin the MASSIVE dataset revision and download it through the benchmark CLI. Do not commit the full dataset. Attribute its CC BY 4.0 license in the README.

The GPT-5.4 Nano request must use strict structured output and the lowest supported reasoning effort. Do not use an LLM-generated confidence value as if it were equivalent to Winnow's probabilities.

## Benchmark

The published benchmark uses the complete MASSIVE `en-US` test split. The CLI should also support a small smoke-test subset for deployment validation.

Record:

- intent accuracy and macro-F1;
- scenario accuracy;
- invalid or failed responses;
- p50, p95, and p99 latency;
- throughput at configurable bounded concurrency;
- cold-start and first-inference time;
- Winnow calibration and accuracy-versus-coverage;
- Azure OpenAI input, output, and reasoning tokens;
- estimated and actual hosted-model cost;
- T4 active time and estimated GPU cost.

Run latency and throughput modes separately. Report client-observed time separately from server-side inference time. Keep failures and retries in the results.

Write machine-readable results under `benchmarks/` with the dataset revision, selected record IDs, commit SHA, model versions, Azure region, ACA workload profile, replica settings, concurrency, and timestamp.

## Model pull and warm-up issue

The current container starts Ollaya and runs `ollaya pull` during startup. With ephemeral storage, a new revision or replica can repeat the download.

The Goose Ollama sample uses an init container and a shared NFS volume:

`https://github.com/simonjj/goose-on-aca/blob/main/infra/ollama.bicep`

Do not copy that design without testing it. Prototype these two options:

1. Persistent Azure Files cache with model pull in the main startup script.
2. Init-container prefetch into a shared persistent cache.

For each option, measure first deployment, subsequent revision startup, scale-from-zero, readiness, and first classification latency. Validate Ollaya's cache path, non-root permissions, file locking, and SMB Azure Files performance.

Avoid adding a VNet and NFS dependency unless SMB storage proves unsuitable. Baking Winnow into the image is the fallback if persistent prefetch is unreliable.

Whichever approach is selected must:

- avoid unnecessary repeated downloads;
- pull `winnow:e4b` before readiness succeeds;
- run a real `/api/decide` warm-up;
- keep `/readyz` false until the warmed model can classify successfully.

## Expected code changes

- Replace the OpenCode gateway with a small classification API.
- Add `/healthz`, `/readyz`, Winnow classification, and GPT-5.4 Nano classification endpoints.
- Replace Laya and `coding-router` with `winnow:e4b` and the MASSIVE taxonomy.
- Add the ACA T4 workload profile and GPU app configuration.
- Replace Luna, Terra, and Sol with one GPT-5.4 Nano deployment in full mode.
- Add `full` and `ollaya-only` Bicep/`azd` deployment modes.
- Add the benchmark CLI, dataset download, fixed record selection, metrics, and result generation.
- Add unit, integration, deployment, GPU, readiness, and managed-identity smoke tests.
- Replace the architecture diagram and rewrite `README.md`.
- Use immutable image tags and explicit errors; never silently fall back between models or deployment modes.

## Definition of done

The work is complete only when:

- `ollaya+opencode` exists upstream and points to the preserved commit.
- A clean clone can deploy both `full` and `ollaya-only` modes through the documented `azd` flow.
- ACA confirms the Ollaya app is running on a T4 workload profile.
- `winnow:e4b` is downloaded, warmed, and available through the authenticated endpoint.
- The complete MASSIVE `en-US` test split runs successfully against Winnow and GPT-5.4 Nano.
- Results include accuracy, latency, throughput, failures, and cost measurements without hiding unfavorable outcomes.
- Model persistence, prefetch, readiness, cold-start behavior, quota requirements, API usage, and benchmark reproduction are documented in `README.md`.
- Tests pass, the deployed endpoints are smoke-tested, and the implementation is committed and pushed.

No new blog post is required unless requested separately.
