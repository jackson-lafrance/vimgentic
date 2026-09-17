const { appendFileSync, mkdirSync, renameSync, writeFileSync } = require("node:fs");
const { dirname } = require("node:path");

// The nvim side sets VIMGENTIC_SESSION_LOG to stdpath("data")/vimgentic/session-log.jsonl
// before spawning the chat terminal. Every session the terminal runs - the startup
// session, /new, /resume, and /fork switches - is appended here so vimgentic can index
// sessions it did not start directly.
module.exports = function sessionLog(pi) {
  pi.on("session_start", (_event, ctx) => {
    const path = ctx.sessionManager.getSessionFile();
    if (!path) return;
    const cwd = ctx.cwd;
    const statePath = process.env.VIMGENTIC_SESSION_STATE;
    if (statePath) {
      try {
        mkdirSync(dirname(statePath), { recursive: true });
        const temporary = `${statePath}.tmp-${process.pid}`;
        writeFileSync(temporary, JSON.stringify({
          path,
          cwd,
          id: ctx.sessionManager.getSessionId(),
          token: process.env.VIMGENTIC_SESSION_TOKEN,
        }), { mode: 0o600 });
        renameSync(temporary, statePath);
      } catch {
        // State reporting must never break session startup.
      }
    }
    const logPath = process.env.VIMGENTIC_SESSION_LOG;
    if (logPath) {
      try {
        mkdirSync(dirname(logPath), { recursive: true });
        appendFileSync(logPath, JSON.stringify({ cwd, path }) + "\n");
      } catch {
        // Logging must never break session startup.
      }
    }
  });
};
