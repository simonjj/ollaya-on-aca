const records = [];
const maxRecords = 500;

export function addMetric(record) {
  records.push(record);
  if (records.length > maxRecords) {
    records.splice(0, records.length - maxRecords);
  }
}

export function resetMetrics() {
  records.length = 0;
}

export function getMetrics() {
  const totals = records.reduce(
    (result, record) => {
      result.requests += 1;
      result.inputTokens += record.usage?.input_tokens ?? 0;
      result.outputTokens += record.usage?.output_tokens ?? 0;
      result.reasoningTokens += record.usage?.output_tokens_details?.reasoning_tokens ?? 0;
      result.ollayaInputTokens += record.decision?.ollayaInputTokens ?? 0;
      result.ollayaDurationMs += record.decision?.ollayaDurationMs ?? 0;
      return result;
    },
    {
      requests: 0,
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      ollayaInputTokens: 0,
      ollayaDurationMs: 0
    }
  );

  return {
    totals,
    records: structuredClone(records)
  };
}

export function usageFromPayload(payload) {
  return payload?.response?.usage ?? payload?.usage ?? null;
}

export function createSseUsageCollector() {
  const decoder = new TextDecoder();
  let pending = "";
  let usage = null;

  return {
    push(chunk) {
      pending += decoder.decode(chunk, { stream: true });
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";

      for (const line of lines) {
        if (!line.startsWith("data:")) {
          continue;
        }
        const data = line.slice(5).trim();
        if (!data || data === "[DONE]") {
          continue;
        }
        try {
          const parsed = JSON.parse(data);
          usage = usageFromPayload(parsed) ?? usage;
        } catch {
          // Partial or provider-specific events are ignored; the stream is still proxied unchanged.
        }
      }
    },
    finish() {
      pending += decoder.decode();
      return usage;
    }
  };
}
