const assert = require("node:assert/strict");
const { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const sessionLog = require("../pi/session-log.js");

function fixture(callback) {
  const directory = mkdtempSync(join(tmpdir(), "vimgentic-session-"));
  const keys = ["VIMGENTIC_SESSION_LOG", "VIMGENTIC_SESSION_STATE", "VIMGENTIC_SESSION_TOKEN"];
  const previous = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  const logPath = join(directory, "session-log.jsonl");
  const statePath = join(directory, "state.json");
  process.env.VIMGENTIC_SESSION_LOG = logPath;
  process.env.VIMGENTIC_SESSION_STATE = statePath;
  process.env.VIMGENTIC_SESSION_TOKEN = "3";
  let handler;
  sessionLog({ on(event, callback) {
    assert.equal(event, "session_start");
    handler = callback;
  } });
  const start = (reason, path, cwd, id = "session-id") => handler({ reason }, {
    cwd,
    sessionManager: { getSessionFile: () => path, getSessionId: () => id },
  });
  try {
    callback({ directory, logPath, statePath, start });
  } finally {
    for (const key of keys) {
      if (previous[key] === undefined) delete process.env[key];
      else process.env[key] = previous[key];
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

test("native session changes report the latest session and its context directory", () => {
  fixture(({ directory, logPath, statePath, start }) => {
    const expectedLog = [];
    for (const reason of ["startup", "new", "fork", "resume", "reload"]) {
      const path = join(directory, `${reason}.jsonl`);
      const cwd = join(directory, `${reason}-project`);
      assert.notEqual(cwd, process.cwd());
      start(reason, path, cwd, `${reason}-id`);
      expectedLog.push({ cwd, path });
      assert.deepEqual(JSON.parse(readFileSync(statePath, "utf8")), {
        path, cwd, id: `${reason}-id`, token: "3",
      });
    }
    assert.deepEqual(readFileSync(logPath, "utf8").trim().split("\n").map(JSON.parse), expectedLog);
    assert.equal(statSync(statePath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(directory).sort(), ["session-log.jsonl", "state.json"]);
  });
});

test("a log write failure does not prevent the current session state report", () => {
  fixture(({ logPath, statePath, start }) => {
    mkdirSync(logPath);
    start("fork", "/sessions/fork.jsonl", "/project", "fork-id");
    assert.deepEqual(JSON.parse(readFileSync(statePath, "utf8")), {
      path: "/sessions/fork.jsonl", cwd: "/project", id: "fork-id", token: "3",
    });
  });
});

test("a state write failure does not prevent history registration", () => {
  fixture(({ logPath, statePath, start }) => {
    mkdirSync(statePath);
    start("resume", "/sessions/resumed.jsonl", "/project");
    assert.deepEqual(JSON.parse(readFileSync(logPath, "utf8")), { cwd: "/project", path: "/sessions/resumed.jsonl" });
  });
});

test("a session without a file creates no state or history files", () => {
  fixture(({ directory, start }) => {
    start("startup", undefined, "/project");
    assert.deepEqual(readdirSync(directory), []);
  });
});

test("an invocation without Vimgentic environment variables creates no files", () => {
  fixture(({ directory, start }) => {
    delete process.env.VIMGENTIC_SESSION_LOG;
    delete process.env.VIMGENTIC_SESSION_STATE;
    start("startup", "/sessions/session.jsonl", "/project");
    assert.deepEqual(readdirSync(directory), []);
  });
});
