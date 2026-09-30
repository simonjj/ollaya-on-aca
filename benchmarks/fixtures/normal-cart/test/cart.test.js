import assert from "node:assert/strict";
import test from "node:test";
import { calculateTotal } from "../src/cart.js";

test("calculates line totals, quantities, and tax", () => {
  assert.equal(
    calculateTotal(
      [
        { price: 10, quantity: 2 },
        { price: 4.5, quantity: 1 }
      ],
      0.0825
    ),
    26.52
  );
});

test("rounds only the final currency amount", () => {
  assert.equal(calculateTotal([{ price: 0.1, quantity: 3 }], 0), 0.3);
});

test("accepts an empty cart", () => {
  assert.equal(calculateTotal([], 0.1), 0);
});

test("rejects malformed data", () => {
  assert.throws(() => calculateTotal(null, 0), TypeError);
  assert.throws(() => calculateTotal([{ price: -1, quantity: 1 }], 0), RangeError);
  assert.throws(() => calculateTotal([{ price: 1, quantity: 0 }], 0), RangeError);
  assert.throws(() => calculateTotal([{ price: 1, quantity: 1.5 }], 0), RangeError);
  assert.throws(() => calculateTotal([{ price: 1, quantity: 1 }], -0.1), RangeError);
});
