#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const OVERLAY_REVISION = "2026-03-19-windows-startup-hardening-v1";
const RUNTIME_OVERLAY_TEMPLATE = "openclaw-windows-runtime-overlay.mjs";
const RUNTIME_OVERLAY_FILENAME = "windows-runtime-overlay.js";

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

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function writeText(filePath, content) {
  fs.writeFileSync(filePath, content, "utf8");
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
  const hasBom = raw.startsWith("\ufeff");
  const body = hasBom ? raw.slice(1) : raw;
  const newline = body.includes("\r\n") ? "\r\n" : "\n";
  const lines = body.split(/\r?\n/);

  if (
    lines.some((line) => {
      const normalized = line.trim().toLowerCase();
      return normalized === "chcp 65001 >nul" || normalized === "@chcp 65001 >nul";
    })
  ) {
    return false;
  }

  const echoOffIndex = lines.findIndex((line) => line.trim().toLowerCase() === "@echo off");
  const insertionIndex = echoOffIndex >= 0 ? echoOffIndex + 1 : 0;
  lines.splice(insertionIndex, 0, "@chcp 65001 >nul");

  let next = lines.join(newline);
  if (hasBom) {
    next = `\ufeff${next}`;
  }
  fs.writeFileSync(cmdPath, next, "utf8");
  return true;
}

function replaceRequired(content, search, replacement, label) {
  if (!content.includes(search)) {
    fail(`Missing overlay anchor for ${label}`);
  }
  return content.replace(search, replacement);
}

function ensureImport(content, anchorImport, overlayImport, label) {
  if (content.includes(overlayImport.trim())) {
    return content;
  }
  return replaceRequired(content, anchorImport, `${anchorImport}${overlayImport}`, label);
}

function ensureImportAfterPattern(content, pattern, overlayImport, label) {
  if (content.includes(overlayImport.trim())) {
    return content;
  }
  const match = content.match(pattern);
  if (!match || !match[0]) {
    fail(`Missing overlay anchor for ${label}`);
  }
  return content.replace(match[0], `${match[0]}${overlayImport}`);
}

function copyRuntimeOverlayTemplate(scriptRoot, distRoot) {
  const sourcePath = path.join(scriptRoot, RUNTIME_OVERLAY_TEMPLATE);
  const targetPath = path.join(distRoot, RUNTIME_OVERLAY_FILENAME);
  ensureFileExists(sourcePath, "runtime overlay template");
  writeText(targetPath, readText(sourcePath));
  return targetPath;
}

function patchOpenclawMjs(filePath) {
  let content = readText(filePath);
  content = ensureImport(
    content,
    'import module from "node:module";\n',
    'import { normalizeWindowsHomeEnv } from "./dist/windows-runtime-overlay.js";\n',
    `${filePath} import`,
  );
  if (!content.includes("normalizeWindowsHomeEnv();")) {
    content = replaceRequired(
      content,
      "ensureSupportedNodeVersion();\n",
      "normalizeWindowsHomeEnv();\nensureSupportedNodeVersion();\n",
      `${filePath} normalize call`,
    );
  }
  writeText(filePath, content);
}

function patchPathsFile(filePath) {
  let content = readText(filePath);
  if (!content.includes("function resolveWindowsTrustedHome(homedir)")) {
    content = replaceRequired(
      content,
      "function normalize(value) {\n\tconst trimmed = value?.trim();\n\treturn trimmed ? trimmed : void 0;\n}\n",
      "function normalize(value) {\n\tconst trimmed = value?.trim();\n\treturn trimmed ? trimmed : void 0;\n}\nfunction resolveWindowsTrustedHome(homedir) {\n\tif (process.platform !== \"win32\") return;\n\treturn normalizeSafe(homedir);\n}\n",
      `${filePath} windows home helper`,
    );
  }
  if (!content.includes("const fallbackHome = resolveWindowsTrustedHome(homedir) ??")) {
    content = replaceRequired(
      content,
      "const fallbackHome = normalize(env.HOME) ?? normalize(env.USERPROFILE) ?? normalizeSafe(homedir);",
      "const fallbackHome = resolveWindowsTrustedHome(homedir) ?? normalize(env.HOME) ?? normalize(env.USERPROFILE) ?? normalizeSafe(homedir);",
      `${filePath} explicit home fallback`,
    );
  }
  if (!content.includes("const trustedHome = resolveWindowsTrustedHome(homedir);")) {
    content = replaceRequired(
      content,
      "const envHome = normalize(env.HOME);\n\tif (envHome) return envHome;\n\tconst userProfile = normalize(env.USERPROFILE);\n\tif (userProfile) return userProfile;\n\treturn normalizeSafe(homedir);",
      "const trustedHome = resolveWindowsTrustedHome(homedir);\n\tif (trustedHome) return trustedHome;\n\tconst envHome = normalize(env.HOME);\n\tif (envHome) return envHome;\n\tconst userProfile = normalize(env.USERPROFILE);\n\tif (userProfile) return userProfile;\n\treturn normalizeSafe(homedir);",
      `${filePath} base home fallback`,
    );
  }
  writeText(filePath, content);
}

function patchEntryJs(filePath) {
  let content = readText(filePath);
  content = ensureImport(
    content,
    'import process$1 from "node:process";\n',
    'import { printFatalError } from "./windows-runtime-overlay.js";\n',
    `${filePath} import`,
  );
  if (!content.includes('printFatalError(parsed.error, { title: "OpenClaw 参数解析失败。", suppressDoctorHint: true });')) {
    content = replaceRequired(
      content,
      'console.error(`[openclaw] ${parsed.error}`);',
      'printFatalError(parsed.error, { title: "OpenClaw 参数解析失败。", suppressDoctorHint: true });',
      `${filePath} profile parse fatal`,
    );
  }
  if (!content.includes('printFatalError(error, { title: "OpenClaw CLI 启动失败。" });')) {
    content = replaceRequired(
      content,
      'console.error("[openclaw] Failed to start CLI:", error instanceof Error ? error.stack ?? error.message : error);',
      'printFatalError(error, { title: "OpenClaw CLI 启动失败。" });',
      `${filePath} top-level catch fatal`,
    );
  }
  content = content.replace("process$1.exitCode = 1;", "process$1.exit(1);");
  writeText(filePath, content);
}

function patchRunMainFile(filePath) {
  let content = readText(filePath);
  content = ensureImport(
    content,
    'import process$1 from "node:process";\n',
    'import { printFatalError } from "./windows-runtime-overlay.js";\n',
    `${filePath} import`,
  );
  if (!content.includes('printFatalError(error, { title: "OpenClaw CLI 发生未捕获异常。" });')) {
    content = replaceRequired(
      content,
      'console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));',
      'printFatalError(error, { title: "OpenClaw CLI 发生未捕获异常。" });',
      `${filePath} uncaught exception fatal`,
    );
  }
  writeText(filePath, content);
}

function patchIndexJs(filePath) {
  let content = readText(filePath);
  content = ensureImport(
    content,
    'import process$1 from "node:process";\n',
    'import { printFatalError } from "./windows-runtime-overlay.js";\n',
    `${filePath} import`,
  );
  if (!content.includes('printFatalError(error, { title: "OpenClaw CLI 发生未捕获异常。" });')) {
    content = replaceRequired(
      content,
      'console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));',
      'printFatalError(error, { title: "OpenClaw CLI 发生未捕获异常。" });',
      `${filePath} uncaught exception fatal`,
    );
  }
  if (!content.includes('printFatalError(err, { title: "OpenClaw CLI 启动失败。" });')) {
    content = replaceRequired(
      content,
      'console.error("[openclaw] CLI failed:", formatUncaughtError(err));',
      'printFatalError(err, { title: "OpenClaw CLI 启动失败。" });',
      `${filePath} parseAsync fatal`,
    );
  }
  writeText(filePath, content);
}

function patchGatewayCliFile(filePath) {
  let content = readText(filePath);
  content = ensureImportAfterPattern(
    content,
    /import \{ t as formatCliCommand \} from "\.\/command-format-[^"]+\.js";\n/,
    'import { printFatalError, printFatalMessage } from "./windows-runtime-overlay.js";\n',
    `${filePath} import`,
  );
  if (!content.includes("function resolveWindowsLockOwnerStatus(pid)")) {
    content = replaceRequired(
      content,
      "async function resolveGatewayOwnerStatus(pid, payload, platform, port) {\n\tif (port != null) {\n\t\tif (await checkPortFree(port)) return \"dead\";\n\t}\n\tif (!isPidAlive(pid)) return \"dead\";\n\tif (platform !== \"linux\") return \"alive\";\n",
      "function resolveWindowsLockOwnerStatus(pid) {\n\tif (process.platform !== \"win32\") return null;\n\ttry {\n\t\tprocess.kill(pid, 0);\n\t\treturn \"alive\";\n\t} catch (error) {\n\t\tif (error && typeof error === \"object\" && error.code === \"ESRCH\") return \"dead\";\n\t\treturn \"unknown\";\n\t}\n}\nasync function resolveGatewayOwnerStatus(pid, payload, platform, port) {\n\tconst windowsOwnerStatus = resolveWindowsLockOwnerStatus(pid);\n\tif (windowsOwnerStatus) return windowsOwnerStatus;\n\tif (port != null) {\n\t\tif (await checkPortFree(port)) return \"dead\";\n\t}\n\tif (!isPidAlive(pid)) return \"dead\";\n\tif (platform !== \"linux\") return \"alive\";\n",
      `${filePath} windows lock owner status`,
    );
  }
  if (!content.includes('title: "检测到初次运行或配置缺失。"')) {
    content = replaceRequired(
      content,
      "if (!opts.allowUnconfigured && mode !== \"local\") {\n\t\tif (!configExists) defaultRuntime.error(`Missing config. Run \\`${formatCliCommand(\"openclaw setup\")}\\` or set gateway.mode=local (or pass --allow-unconfigured).`);\n\t\telse {\n\t\t\tdefaultRuntime.error(`Gateway start blocked: set gateway.mode=local (current: ${mode ?? \"unset\"}) or pass --allow-unconfigured.`);\n\t\t\tdefaultRuntime.error(`Config write audit: ${configAuditPath}`);\n\t\t}\n\t\tdefaultRuntime.exit(1);\n\t\treturn;\n\t}\n",
      "if (!opts.allowUnconfigured && mode !== \"local\") {\n\t\tprintFatalMessage({\n\t\t\ttitle: \"检测到初次运行或配置缺失。\",\n\t\t\tdetails: [!configExists ? `Missing config. Run \\`${formatCliCommand(\"openclaw setup\")}\\` or set gateway.mode=local (or pass --allow-unconfigured).` : `Gateway start blocked: set gateway.mode=local (current: ${mode ?? \"unset\"}) or pass --allow-unconfigured.`, configExists ? `Config write audit: ${configAuditPath}` : null],\n\t\t\tactions: [`请运行 \"${formatCliCommand(\"openclaw setup\")}\" 完成初始化。`, '如需跳过此检查，可使用 \"--allow-unconfigured\" 强行启动。']\n\t\t});\n\t\tdefaultRuntime.exit(1);\n\t\treturn;\n\t}\n",
      `${filePath} missing config fatal`,
    );
  }
  if (!content.includes('printFatalError(err, {\n\t\t\t\ttitle: "Gateway 启动失败。"')) {
    content = replaceRequired(
      content,
      "try {\n\t\tawait runGatewayLoop({\n\t\t\truntime: defaultRuntime,\n\t\t\tlockPort: port,\n\t\t\tstart: async () => await startGatewayServer(port, {\n\t\t\t\tbind,\n\t\t\t\tauth: authOverride,\n\t\t\t\ttailscale: tailscaleOverride\n\t\t\t})\n\t\t});\n\t} catch (err) {\n\t\tif (err instanceof GatewayLockError || err && typeof err === \"object\" && err.name === \"GatewayLockError\") {\n\t\t\tconst errMessage = describeUnknownError(err);\n\t\t\tdefaultRuntime.error(`Gateway failed to start: ${errMessage}\\nIf the gateway is supervised, stop it with: ${formatCliCommand(\"openclaw gateway stop\")}`);\n\t\t\ttry {\n\t\t\t\tconst diagnostics = await inspectPortUsage(port);\n\t\t\t\tif (diagnostics.status === \"busy\") for (const line of formatPortDiagnostics(diagnostics)) defaultRuntime.error(line);\n\t\t\t} catch {}\n\t\t\tawait maybeExplainGatewayServiceStop();\n\t\t\tdefaultRuntime.exit(1);\n\t\t\treturn;\n\t\t}\n\t\tdefaultRuntime.error(`Gateway failed to start: ${String(err)}`);\n\t\tdefaultRuntime.exit(1);\n\t}\n",
      "try {\n\t\tawait runGatewayLoop({\n\t\t\truntime: defaultRuntime,\n\t\t\tlockPort: port,\n\t\t\tstart: async () => await startGatewayServer(port, {\n\t\t\t\tbind,\n\t\t\t\tauth: authOverride,\n\t\t\t\ttailscale: tailscaleOverride\n\t\t\t})\n\t\t});\n\t} catch (err) {\n\t\tif (err instanceof GatewayLockError || err && typeof err === \"object\" && err.name === \"GatewayLockError\") {\n\t\t\tconst errMessage = describeUnknownError(err);\n\t\t\tprintFatalError(err, {\n\t\t\t\ttitle: \"Gateway 启动失败。\",\n\t\t\t\tsummary: `Gateway failed to start: ${errMessage}`,\n\t\t\t\tstopCommand: formatCliCommand(\"openclaw gateway stop\")\n\t\t\t});\n\t\t\ttry {\n\t\t\t\tconst diagnostics = await inspectPortUsage(port);\n\t\t\t\tif (diagnostics.status === \"busy\") {\n\t\t\t\t\tprintFatalMessage({\n\t\t\t\t\t\ttitle: \"附加端口诊断信息。\",\n\t\t\t\t\t\tdetails: formatPortDiagnostics(diagnostics)\n\t\t\t\t\t});\n\t\t\t\t}\n\t\t\t} catch {}\n\t\t\tawait maybeExplainGatewayServiceStop();\n\t\t\tdefaultRuntime.exit(1);\n\t\t\treturn;\n\t\t}\n\t\tprintFatalError(err, { title: \"Gateway 启动失败。\" });\n\t\tdefaultRuntime.exit(1);\n\t}\n",
      `${filePath} gateway fatal catch`,
    );
  }
  writeText(filePath, content);
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
  const scriptRoot = path.dirname(fileURLToPath(import.meta.url));
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
  const homeDirPathsFiles = pathsFiles.filter((fileName) =>
    readText(path.join(distRoot, fileName)).includes("function resolveEffectiveHomeDir"),
  );
  if (homeDirPathsFiles.length === 0) {
    fail("Expected at least one paths-* chunk containing resolveEffectiveHomeDir.");
  }

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

  const runtimeHelperPath = copyRuntimeOverlayTemplate(scriptRoot, distRoot);
  patchOpenclawMjs(path.join(packageRoot, "openclaw.mjs"));
  patchEntryJs(path.join(distRoot, "entry.js"));
  patchIndexJs(path.join(distRoot, "index.js"));
  for (const fileName of runMainFiles) {
    patchRunMainFile(path.join(distRoot, fileName));
  }
  for (const fileName of gatewayCliFiles) {
    patchGatewayCliFile(path.join(distRoot, fileName));
  }
  for (const fileName of homeDirPathsFiles) {
    patchPathsFile(path.join(distRoot, fileName));
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
      homeDirPaths: homeDirPathsFiles,
    },
    runtimeHelper: path.basename(runtimeHelperPath),
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
