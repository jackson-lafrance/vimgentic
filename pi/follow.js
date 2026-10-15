const { randomUUID } = require("node:crypto");
const { closeSync, openSync, readSync, renameSync, writeFileSync } = require("node:fs");
const { homedir } = require("node:os");
const { isAbsolute, resolve } = require("node:path");

function control(path) {
  let descriptor;
  try {
    descriptor = openSync(path, "r");
    const buffer = Buffer.alloc(4097);
    const length = readSync(descriptor, buffer, 0, buffer.length, 0);
    if (length > 4096) return;
    const state = JSON.parse(buffer.toString("utf8", 0, length));
    if (typeof state?.enabled === "boolean" && typeof state.token === "string" && state.token) return state;
  } catch {
    // A missing or unreadable control file disables navigation, not the agent.
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function filePath(path, cwd) {
  if (typeof path !== "string" || !path || /[\x00-\x1f\x7f]/.test(path)) return;
  if (path.startsWith("~/")) path = resolve(homedir(), path.slice(2));
  return isAbsolute(path) ? resolve(path) : resolve(cwd, path);
}

const guidance = "After each read, edit, or write, decide whether showing that file helps the user follow the current task. "
  + "Use vimgentic_show_file for useful source context, important definitions, and meaningful changes, with a relevant line. "
  + "Include a short reason explaining why showing this file helps the user understand the task, not a summary of edits. "
  + "Neovim collects actual jumps and shows their reasons in quickfix when this prompt finishes. "
  + "Skip incidental lookups, repeated context, and noisy generated or dependency files unless they matter to the task. "
  + "Do not show every file automatically. No tool call is needed when you decide not to show a file. "
  + "This only changes the adjacent Neovim view; it never grants permission to edit files.";

module.exports = function follow(pi) {
  const controlPath = process.env.VIMGENTIC_FOLLOW_CONTROL;
  const requestPath = process.env.VIMGENTIC_FOLLOW_REQUEST;
  if (!controlPath || !requestPath) return;

  const visited = new Set();
  let enabled = false;
  let run = randomUUID();
  let lastRequest;

  function publish(state, request, done) {
    const temporary = `${requestPath}.tmp-${process.pid}`;
    writeFileSync(temporary, JSON.stringify({ token: state.token, run, request, done }), { mode: 0o600 });
    renameSync(temporary, requestPath);
  }

  function reset() {
    visited.clear();
    run = randomUUID();
    lastRequest = undefined;
  }

  pi.on("session_start", reset);
  pi.on("before_agent_start", () => {
    reset();
    enabled = control(controlPath)?.enabled === true;
    return { message: {
      customType: "vimgentic-follow",
      content: enabled ? "Vimgentic follow mode is ON. " + guidance
        : "Vimgentic follow mode is OFF. Do not call vimgentic_show_file unless a later tool result says it is ON.",
      display: false,
    } };
  });

  pi.on("agent_settled", () => {
    const request = lastRequest;
    lastRequest = undefined;
    if (!request) return;
    const state = control(controlPath);
    if (!state) return;
    try {
      // Retain the last choice so completion cannot overwrite an unread jump.
      publish(state, request, true);
    } catch {
      // Reporting completion must never break the agent's finished run.
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (!["read", "edit", "write"].includes(event.toolName)) return;
    const path = filePath(event.input.path, ctx.cwd);
    if (!event.isError && path) {
      visited.delete(path);
      visited.add(path);
      if (visited.size > 256) visited.delete(visited.values().next().value);
    }
    const wasEnabled = enabled;
    enabled = control(controlPath)?.enabled === true;
    let reminder;
    if (enabled && !event.isError && path) {
      reminder = "Vimgentic follow is ON: decide whether this file is worth showing. "
        + "If useful, call vimgentic_show_file with its path, a relevant line, and a short reason why showing it helps; "
        + "otherwise continue without navigating.";
    } else if (!enabled && wasEnabled) {
      reminder = "Vimgentic follow is now OFF. Do not call vimgentic_show_file.";
    }
    if (reminder) return {
      content: [...event.content, { type: "text", text: reminder }],
      structuredContent: event.structuredContent,
    };
  });

  pi.registerTool({
    name: "vimgentic_show_file",
    label: "Show in Neovim",
    description: "When Vimgentic follow is ON, show a file you just read, edited, or wrote in the adjacent Neovim editor. "
      + "Choose only files worth showing for the current task; skip incidental activity. Never use when follow is OFF.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", minLength: 1, description: "Path of a file read, edited, or written during this turn." },
        line: { type: "integer", minimum: 1, description: "Relevant 1-based line number." },
        reason: { type: "string", minLength: 1, maxLength: 500,
          description: "Briefly explain why showing this file helps the user follow the task, not what code changed." },
      },
      required: ["path", "line", "reason"],
      additionalProperties: false,
    },
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const state = control(controlPath);
      const result = (text, isError = false) => ({ content: [{ type: "text", text }], details: undefined, isError });
      if (!state?.enabled) return result("Follow is off; no navigation requested.");
      const path = filePath(params.path, ctx.cwd);
      if (!path || !visited.has(path)) return result("Only show files successfully read, edited, or written during this turn.", true);
      if (!Number.isSafeInteger(params.line) || params.line < 1) return result("The line must be a positive integer.", true);
      if (typeof params.reason !== "string" || !params.reason.trim() || [...params.reason].length > 500
        || /[\x00-\x08\x0b-\x1f\x7f]/.test(params.reason)) return result("Give a short, non-empty reason for showing this file (at most 500 characters).", true);
      const reason = params.reason.replace(/\s+/g, " ").trim();
      const request = { token: state.token, id: randomUUID(), path, line: params.line, reason };
      publish(state, request, false);
      lastRequest = request;
      return result("Navigation requested. Neovim may skip it if the sidebar is hidden or an editor buffer has unsaved changes.");
    },
  });
};
