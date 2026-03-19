#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const OVERLAY_REVISION = "2026-03-19-windows-startup-hardening-v1";

function fail(message) {
  throw new Error(`[openclaw-overlay] ${message}`);
}

function parseArgs(argv) {
  const parsed = {
    bundleRoot: "",
    metadataFile: "",
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    const next = argv[index + 1];
    if (token === "--bundle-root" && next) {
      parsed.bundleRoot = next;
      index += 1;
      continue;
    }
    if (token === "--metadata-file" && next) {
      parsed.metadataFile = next;
      index += 1;
      continue;
    }
    fail(`Unknown or incomplete argument: ${token ?? "<empty>"}`);
  }

  if (!parsed.bundleRoot) {
    fail("Missing required --bundle-root argument.");
  }

  return parsed;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function ensureFileExists(filePath, label) {
  if (!fs.existsSync(filePath)) {
    fail(`Required ${label} is missing: ${filePath}`);
  }
}

function listDistFiles(distRoot) {
  ensureFileExists(distRoot, "dist directory");
  return fs.readdirSync(distRoot).filter((name) => name.endsWith(".js"));
}

function expectMatches(distFiles, pattern, label) {
  const matches = distFiles.filter((name) => pattern.test(name));
  if (matches.length === 0) {
    fail(`Expected at least one ${label} file matching ${pattern}, but none were found.`);
  }
  return matches;
}

function injectUtf8CodePage(cmdPath) {
  const raw = fs.readFileSync(cmdPath, "utf8");
  const headerMatch = raw.match(/^\ufeff?@echo off\r?\n/i);
  if (!headerMatch) {
    fail(`Cannot patch ${cmdPath}: missing "@echo off" header.`);
  }

  const newline = headerMatch[0].endsWith("\r\n") ? "\r\n" : "\n";
  const insertion = `chcp 65001 >nul${newline}`;
  const prefixLength = headerMatch[0].length;
  const currentBody = raw.slice(prefixLength);
  if (currentBody.startsWith(insertion)) {
    return false;
  }

  const next = raw.slice(0, prefixLength) + insertion + currentBody;
  fs.writeFileSync(cmdPath, next, "utf8");
  return true;
}

function writeMetadata(metadataFile, payload) {
  if (!metadataFile) {
    return;
  }
  fs.writeFileSync(metadataFile, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
}

function main() {
  const args = parseArgs(process.argv);
  const bundleRoot = path.resolve(args.bundleRoot);
  const packageRoot = path.join(bundleRoot, "node_modules", "openclaw");
  const distRoot = path.join(packageRoot, "dist");
  const packageJsonPath = path.join(packageRoot, "package.json");

  ensureFileExists(bundleRoot, "bundle root");
  ensureFileExists(packageRoot, "openclaw package directory");
  ensureFileExists(packageJsonPath, "openclaw package.json");
  ensureFileExists(path.join(packageRoot, "openclaw.mjs"), "openclaw.mjs");
  ensureFileExists(path.join(distRoot, "entry.js"), "dist/entry.js");
  ensureFileExists(path.join(distRoot, "index.js"), "dist/index.js");

  const distFiles = listDistFiles(distRoot);
  const runMainFiles = expectMatches(distFiles, /^run-main-.*\.js$/, "run-main");
  const gatewayCliFiles = expectMatches(distFiles, /^gateway-cli-.*\.js$/, "gateway-cli");
  const pathsFiles = expectMatches(distFiles, /^paths-.*\.js$/, "paths");

  const rootCmdFiles = fs
    .readdirSync(bundleRoot)
    .filter((name) => name.toLowerCase().endsWith(".cmd"))
    .map((name) => path.join(bundleRoot, name));

  if (rootCmdFiles.length === 0) {
    fail(`No bundle-root .cmd launchers were found in ${bundleRoot}`);
  }

  const cmdPatched = [];
  for (const cmdPath of rootCmdFiles) {
    if (injectUtf8CodePage(cmdPath)) {
      cmdPatched.push(path.basename(cmdPath));
    }
  }

  const packageJson = readJson(packageJsonPath);
  const metadata = {
    overlayApplied: true,
    overlayRevision: OVERLAY_REVISION,
    overlayTargetVersion: String(packageJson.version ?? ""),
    checkedFiles: {
      runMain: runMainFiles,
      gatewayCli: gatewayCliFiles,
      paths: pathsFiles,
    },
    cmdPatched,
  };

  writeMetadata(args.metadataFile, metadata);
  process.stdout.write(`${JSON.stringify(metadata)}\n`);
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
}
