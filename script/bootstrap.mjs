import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pins = JSON.parse(readFileSync(resolve(root, "dependencies.json"), "utf8"));
const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 22 || (major === 22 && minor < 13)) throw new Error("Use Node >=22.13 for the pinned pnpm toolchain.");
const env = { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH ?? ""}` };
const run = (command, args, cwd = root) => execFileSync(command, args, { cwd, env, stdio: "inherit" });
const git = (args, cwd) => execFileSync("git", args, { cwd, env, encoding: "utf8" }).trim();
mkdirSync(resolve(root, "lib"), { recursive: true });

for (const [name, pin] of [["reserve-index-dtf", pins.reserve], ["v4-core", pins.v4]]) {
  const dir = resolve(root, "lib", name);
  if (!existsSync(dir)) {
    run("git", ["clone", "--no-checkout", pin.url, dir]);
    run("git", ["checkout", "--detach", pin.commit], dir);
  }
  if (git(["rev-parse", "HEAD"], dir) !== pin.commit) throw new Error(`${name}: wrong revision; refusing to modify existing checkout.`);
  if (git(["status", "--porcelain", "--untracked-files=no"], dir)) throw new Error(`${name}: modified upstream source; refusing to proceed.`);
}

const reserve = resolve(root, "lib/reserve-index-dtf");
const lockHash = createHash("sha256").update(readFileSync(resolve(reserve, "pnpm-lock.yaml"))).digest("hex");
if (lockHash !== pins.reserve.lockfileSha256) throw new Error("Reserve lockfile does not match pin.");
// Reserve's packageManager field selects this exact pnpm version; verify before dependency writes.
const pnpmVersion = execFileSync("pnpm", ["--version"], { cwd: reserve, env, encoding: "utf8" }).trim();
if (pnpmVersion !== pins.pnpm) throw new Error(`Use pnpm ${pins.pnpm}; got ${pnpmVersion}.`);
run("pnpm", ["install", "--frozen-lockfile", "--ignore-scripts"], reserve);
run("git", ["submodule", "update", "--init", "lib/solmate"], resolve(root, "lib/v4-core"));
console.log("Pinned contract dependencies are ready.");
