import assert from "node:assert/strict";
import test from "node:test";
import {
  coverageByThreshold,
  expectedCalibrationError,
  macroF1,
  percentile
} from "../lib/metrics.js";

test("percentile uses the nearest rank", () => {
  assert.equal(percentile([1, 2, 3, 4], 0.5), 2);
  assert.equal(percentile([1, 2, 3, 4], 0.95), 4);
  assert.equal(percentile([], 0.5), null);
});

test("macroF1 averages labels", () => {
  const rows = [
    { expected: "a", predicted: "a" },
    { expected: "a", predicted: "b" },
    { expected: "b", predicted: "b" }
  ];
  assert.equal(macroF1(rows, ["a", "b"], "expected", "predicted"), 2 / 3);
});

test("calibration and coverage use Winnow confidence", () => {
  const rows = [
    { confidence: 0.9, intentCorrect: true },
    { confidence: 0.8, intentCorrect: true },
    { confidence: 0.6, intentCorrect: false }
  ];
  assert.ok(expectedCalibrationError(rows) > 0);
  assert.equal(coverageByThreshold(rows, [0.75])["0.75"].accepted, 2);
});
