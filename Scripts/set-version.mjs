#!/usr/bin/env node
// Write one semantic version into the authoritative VERSION file.
// Used by the Forgejo release job; safe to run by hand. Never commits, tags, or pushes.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  console.error("usage: node Scripts/set-version.mjs <major.minor.patch>");
  process.exit(2);
}

const versionPath = resolve(ROOT, "VERSION");
const current = readFileSync(versionPath, "utf8").trim();
writeFileSync(versionPath, `${version}\n`);
console.log(`VERSION ${current} -> ${version}`);
