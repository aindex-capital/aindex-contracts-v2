import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cwd = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pins = JSON.parse(readFileSync(resolve(cwd, "dependencies.json"), "utf8"));
for (const [name, commit] of [["reserve-index-dtf", pins.reserve.commit], ["v4-core", pins.v4.commit]]) {
  const dir = resolve(cwd, "lib", name);
  const actual = execFileSync("git", ["rev-parse", "HEAD"], { cwd: dir, encoding: "utf8" }).trim();

  const dirty = execFileSync("git", ["status", "--porcelain", "--untracked-files=no"], { cwd: dir, encoding: "utf8" }).trim();
  if (actual !== commit || dirty) throw new Error(`${name}: expected clean pinned source. Run bootstrap or inspect local changes.`);
}
const hash = createHash("sha256").update(readFileSync(resolve(cwd, "lib/reserve-index-dtf/pnpm-lock.yaml"))).digest("hex");
if (hash !== pins.reserve.lockfileSha256) throw new Error("Dependency lockfile mismatch.");
// Compilation is explicit because the PoolManager and Folio pin different compiler versions.
const env = { ...process.env, FOUNDRY_OFFLINE: "true" };
execFileSync("forge", ["build", "src/CompilePoolManager.sol"], { cwd, env, stdio: "inherit" });
execFileSync("forge", ["test", ...process.argv.slice(2)], { cwd, env, stdio: "inherit" });
