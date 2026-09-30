import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

assert.equal(await readFile("answer.txt", "utf8"), "Azure Container Apps\n");
