export function percentile(values, probability) {
  if (!values.length) {
    return null;
  }
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(probability * sorted.length) - 1)
  );
  return sorted[index];
}

export function macroF1(rows, labels, expectedKey, predictedKey) {
  const scores = labels.map((label) => {
    let truePositive = 0;
    let falsePositive = 0;
    let falseNegative = 0;
    for (const row of rows) {
      const expected = row[expectedKey];
      const predicted = row[predictedKey];
      if (expected === label && predicted === label) {
        truePositive += 1;
      } else if (expected !== label && predicted === label) {
        falsePositive += 1;
      } else if (expected === label && predicted !== label) {
        falseNegative += 1;
      }
    }
    const precision =
      truePositive + falsePositive === 0 ? 0 : truePositive / (truePositive + falsePositive);
    const recall =
      truePositive + falseNegative === 0 ? 0 : truePositive / (truePositive + falseNegative);
    return precision + recall === 0 ? 0 : (2 * precision * recall) / (precision + recall);
  });
  return scores.reduce((sum, score) => sum + score, 0) / scores.length;
}

export function expectedCalibrationError(rows, binCount = 10) {
  const candidates = rows.filter(
    (row) => Number.isFinite(row.confidence) && typeof row.intentCorrect === "boolean"
  );
  if (!candidates.length) {
    return null;
  }
  let error = 0;
  for (let index = 0; index < binCount; index += 1) {
    const lower = index / binCount;
    const upper = (index + 1) / binCount;
    const bin = candidates.filter(
      (row) =>
        row.confidence >= lower &&
        (index === binCount - 1 ? row.confidence <= upper : row.confidence < upper)
    );
    if (!bin.length) {
      continue;
    }
    const accuracy = bin.filter((row) => row.intentCorrect).length / bin.length;
    const confidence = bin.reduce((sum, row) => sum + row.confidence, 0) / bin.length;
    error += (bin.length / candidates.length) * Math.abs(accuracy - confidence);
  }
  return error;
}

export function coverageByThreshold(rows, thresholds) {
  const candidates = rows.filter(
    (row) => Number.isFinite(row.confidence) && typeof row.intentCorrect === "boolean"
  );
  return Object.fromEntries(
    thresholds.map((threshold) => {
      const accepted = candidates.filter((row) => row.confidence >= threshold);
      return [
        threshold.toFixed(2),
        {
          accepted: accepted.length,
          coverage: candidates.length ? accepted.length / candidates.length : 0,
          accuracy: accepted.length
            ? accepted.filter((row) => row.intentCorrect).length / accepted.length
            : null
        }
      ];
    })
  );
}
