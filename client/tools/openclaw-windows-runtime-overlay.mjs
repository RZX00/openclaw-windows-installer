import os from "node:os";
import path from "node:path";
import process from "node:process";

const RED = "\x1b[31m";
const RESET = "\x1b[0m";

function normalizeLine(value) {
  const text = typeof value === "string" ? value : value == null ? "" : String(value);
  const trimmed = text.trim();
  return trimmed ? trimmed : "";
}

function summarizeError(error) {
  if (error instanceof Error) {
    return normalizeLine(error.message || error.stack || String(error));
  }
  return normalizeLine(error);
}

function pushUnique(target, value) {
  const normalized = normalizeLine(value);
  if (!normalized || target.includes(normalized)) {
    return;
  }
  target.push(normalized);
}

export function normalizeWindowsHomeEnv(env = process.env, homedir = os.homedir) {
  if (process.platform !== "win32") {
    return "";
  }

  let resolvedHome = "";
  try {
    resolvedHome = normalizeLine(homedir());
  } catch {
    return "";
  }

  if (!resolvedHome) {
    return "";
  }

  const trustedHome = path.resolve(resolvedHome);
  env.USERPROFILE = trustedHome;
  env.HOME = trustedHome;
  return trustedHome;
}

export function printFatalMessage(spec = {}) {
  const title = normalizeLine(spec.title) || "OpenClaw 启动失败。";
  const details = [];
  const actions = [];

  for (const value of Array.isArray(spec.details) ? spec.details : []) {
    pushUnique(details, value);
  }
  for (const value of Array.isArray(spec.actions) ? spec.actions : []) {
    pushUnique(actions, value);
  }

  const lines = [title, ...details];
  if (actions.length > 0) {
    lines.push("建议操作:");
    for (const action of actions) {
      lines.push(`- ${action}`);
    }
  }

  console.error(`${RED}${lines.join("\n")}${RESET}`);
}

export function printFatalError(error, options = {}) {
  const summary = normalizeLine(options.summary) || summarizeError(error) || "Unknown fatal error.";
  const lower = summary.toLowerCase();
  const details = [];
  const actions = [];
  let title = normalizeLine(options.title) || "OpenClaw 启动失败。";
  let addDoctorHint = !options.suppressDoctorHint;

  for (const value of Array.isArray(options.details) ? options.details : []) {
    pushUnique(details, value);
  }
  for (const value of Array.isArray(options.actions) ? options.actions : []) {
    pushUnique(actions, value);
  }

  if (
    options.kind === "missing-config" ||
    /missing config|gateway\.mode=local|allow-unconfigured|set gateway\.mode=local/.test(lower)
  ) {
    title = "检测到初次运行或配置缺失。";
    pushUnique(details, `错误摘要: ${summary}`);
    pushUnique(actions, `请运行 "${options.setupCommand || "openclaw setup"}" 完成初始化。`);
    pushUnique(actions, '如需跳过此检查，可使用 "--allow-unconfigured" 强行启动。');
    addDoctorHint = false;
  } else if (
    /(eperm|operation not permitted)/.test(lower) &&
    /(mkdir|directory|workspace|userprofile|home|path)/.test(lower)
  ) {
    title = "检测到 Windows 路径/权限启动错误。";
    pushUnique(details, "这通常是中文用户目录被错误编码后，创建工作区目录失败。");
    pushUnique(details, `错误摘要: ${summary}`);
    pushUnique(actions, "请重新通过最新的一键包启动；它会强制使用 os.homedir() 修正 HOME/USERPROFILE。");
    pushUnique(actions, "如仍失败，请检查当前终端中的 HOME / USERPROFILE 是否仍然是乱码路径。");
    addDoctorHint = false;
  } else if (
    /eaddrinuse|already listening on ws:\/\/|gateway already running|lock timeout|failed to acquire gateway lock|another gateway instance is already listening/.test(
      lower,
    )
  ) {
    title = "检测到 Gateway 端口或锁冲突。";
    pushUnique(details, `错误摘要: ${summary}`);
    pushUnique(actions, `请运行 "${options.stopCommand || "openclaw gateway stop"}" 清理进程后重试。`);
    addDoctorHint = false;
  } else {
    pushUnique(details, `错误摘要: ${summary}`);
  }

  if (addDoctorHint) {
    pushUnique(actions, `如仍失败，请运行 "${options.doctorCommand || "openclaw doctor"}" 继续排查。`);
  }

  printFatalMessage({ title, details, actions });
}
