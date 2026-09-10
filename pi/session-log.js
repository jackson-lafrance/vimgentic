const { appendFileSync, mkdirSync } = require("node:fs");
const { dirname } = require("node:path");

// The nvim side sets VIMGENTIC_SESSION_LOG to stdpath("data")/vimgentic/session-log.jsonl
// before spawning the chat terminal. Every session the terminal runs - the startup
// session, /new, /resume, and /fork switches - is appended here so vimgentic can index
// sessions it did not start directly.
module.exports = function sessionLog(pi) {
  pi.on("session_start", (_event, ctx) => {
    const logPath = process.env.VIMGENTIC_SESSION_LOG;
    if (!logPath) return;
    const path = ctx.sessionManager.getSessionFile();
    if (!path) return;
    try {
      mkdirSync(dirname(logPath), { recursive: true });
      appendFileSync(logPath, JSON.stringify({ cwd: process.cwd(), path }) + "\n");
    } catch {
      // Logging must never break session startup.
    }
  });
};
