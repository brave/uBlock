import assert from "node:assert";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

const loaded = new Set();

registerHooks({
  load(url, context, nextLoad) {
    assert(url.startsWith("file:///"), `Remote URL blocked [${url}].`);
    const filePath = fileURLToPath(url);
    const relativePath = path.relative(process.cwd(), filePath);
    const escaped = relativePath.startsWith("..") || path.isAbsolute(relativePath);
    assert(!escaped, `Outside repo root [${relativePath}].`);
    loaded.add(relativePath);
    return nextLoad(url, context);
  },
});

const { builtinScriptlets } = await import("../src/js/resources/scriptlets.js");
assert(Array.isArray(builtinScriptlets), "scriptlets not an array.");

const config = JSON.parse(fs.readFileSync(".github/pull-merge.json", "utf8"));
const filterdiffArgs = config.filterdiff_args;
assert(typeof filterdiffArgs === "string" && filterdiffArgs.length > 0,
  ".github/pull-merge.json filterdiff_args missing/empty.");

const syntheticDiff = [...loaded].map(p =>
  `diff --git a/${p} b/${p}\n--- a/${p}\n+++ b/${p}\n@@ -0,0 +1 @@\n+x\n`
).join("");

const reviewed = await new Promise((resolve, reject) => {
  const cp = spawn("filterdiff", ["--strip=1", "--list", ...filterdiffArgs.split(/\s+/).filter(Boolean)]);
  const out = [], err = [];
  cp.stdin.write(syntheticDiff);
  cp.stdout.on("data", d => out.push(d));
  cp.stderr.on("data", d => err.push(d));
  cp.stdin.end();
  cp.on("close", code => {
    if (code !== 0) return reject(new Error(Buffer.concat(err).toString()));
    resolve(new Set(Buffer.concat(out).toString().split("\n").filter(Boolean)));
  });
});

const unreviewed = [...loaded].filter(p => !reviewed.has(p));
assert(unreviewed.length === 0,
  `Loaded but not in LLM review scope (filterdiff_args):\n${unreviewed.join("\n")}`);

console.log(`Verified ${loaded.size} files against filterdiff_args. All in review scope.`);
console.log("All checks succeeded.");
