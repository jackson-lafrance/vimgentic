const assert = require("node:assert/strict");
const { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } = require("node:fs");
const { tmpdir, homedir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const follow = require("../pi/follow.js");

async function fixture(callback) {
  const directory = mkdtempSync(join(tmpdir(), "vimgentic-follow-"));
  const keys = ["VIMGENTIC_FOLLOW_CONTROL", "VIMGENTIC_FOLLOW_REQUEST"];
  const previous = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  const controlPath = join(directory, "control.json");
  const requestPath = join(directory, "request.json");
  process.env.VIMGENTIC_FOLLOW_CONTROL = controlPath;
  process.env.VIMGENTIC_FOLLOW_REQUEST = requestPath;
  const handlers = {};
  let tool;
  follow({
    on: (event, handler) => { handlers[event] = handler; },
    registerTool: (definition) => { tool = definition; },
  });
  const ctx = { cwd: directory };
  const state = (enabled, token = "generation-1") => writeFileSync(controlPath, JSON.stringify({ enabled, token }));
  const event = (toolName = "read", path = "app.lua", extra = {}) => ({
    toolName, input: { path }, content: [{ type: "text", text: "original result" }], isError: false, ...extra,
  });
  const result = (value = event()) => handlers.tool_result(value, ctx);
  const show = (path = "app.lua", line = 8, reason = "This function connects the caller to the implementation.") =>
    tool.execute("call-id", { path, line, reason }, undefined, undefined, ctx);
  try {
    await callback({ directory, controlPath, requestPath, state, event, result, show, handlers, tool });
  } finally {
    for (const key of keys) {
      if (previous[key] === undefined) delete process.env[key];
      else process.env[key] = previous[key];
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

test("an invocation outside Vimgentic registers no navigation tool or handlers", () => {
  const keys = ["VIMGENTIC_FOLLOW_CONTROL", "VIMGENTIC_FOLLOW_REQUEST"];
  const previous = keys.map((key) => process.env[key]);
  try {
    for (const key of keys) delete process.env[key];
    follow({
      on: () => assert.fail("registered a handler"),
      registerTool: () => assert.fail("registered a tool"),
    });
  } finally {
    keys.forEach((key, index) => {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    });
  }
});

test("follow off leaves file results unchanged and never queues navigation", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(false);
    assert.match(handlers.before_agent_start().message.content, /OFF/);
    assert.equal(result(), undefined);
    assert.equal((await show()).content[0].text, "Follow is off; no navigation requested.");
    assert.equal(existsSync(requestPath), false);
  });
});

test("enabled file operations ask Pi to decide but never navigate automatically", async () => {
  await fixture(({ state, handlers, event, result, requestPath }) => {
    state(true);
    const prompt = handlers.before_agent_start().message;
    assert.equal(prompt.display, false);
    assert.match(prompt.content, /After each read, edit, or write, decide/);
    assert.match(prompt.content, /No tool call is needed when you decide not to show a file/);
    for (const name of ["read", "edit", "write"]) {
      const original = event(name, "app.lua", { structuredContent: { preserved: true }, parentToolCallId: "codemode-1" });
      const changed = result(original);
      assert.deepEqual(changed.content[0], original.content[0]);
      assert.match(changed.content[1].text, /decide whether this file is worth showing/);
      assert.deepEqual(changed.structuredContent, { preserved: true });
      assert.deepEqual(original.content, [{ type: "text", text: "original result" }]);
    }
    assert.equal(result(event("bash")), undefined);
    assert.equal(result(event("grep")), undefined);
    assert.equal(existsSync(requestPath), false);
  });
});

test("an explicit Pi choice queues the absolute path and line with the current generation", async () => {
  await fixture(async ({ directory, state, result, show, requestPath }) => {
    state(true, "current-generation");
    result();
    const output = await show();
    assert.equal(output.isError, false);
    assert.match(output.content[0].text, /Navigation requested/);
    const report = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.equal(report.done, false);
    assert.equal(typeof report.run, "string");
    assert.notEqual(report.run, "");
    const request = report.request;
    assert.deepEqual({ ...request, id: "id" }, {
      path: join(directory, "app.lua"), line: 8, token: "current-generation", id: "id",
      reason: "This function connects the caller to the implementation.",
    });
    assert.equal(typeof request.id, "string");
    assert.equal(statSync(requestPath).mode & 0o777, 0o600);
    await show("app.lua", 2);
    const next = JSON.parse(readFileSync(requestPath, "utf8")).request;
    assert.equal(next.line, 2);
    assert.notEqual(next.id, request.id);
  });
});

test("a live toggle changes the next result and blocks a choice made before follow was disabled", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(false);
    handlers.before_agent_start();
    state(true);
    assert.match(result().content[1].text, /follow is ON/);
    state(false);
    assert.match(result().content[1].text, /follow is now OFF/);
    assert.equal(result(), undefined);
    assert.equal((await show()).isError, false);
    assert.equal(existsSync(requestPath), false);
    state(true, "new-generation");
    await show();
    assert.equal(JSON.parse(readFileSync(requestPath, "utf8")).token, "new-generation");
  });
});

test("invalid or missing control files disable follow without breaking file tools", async () => {
  await fixture(async ({ controlPath, handlers, result, show, requestPath }) => {
    const values = [null, "{broken", "x".repeat(4097), "null", "[]", '{"enabled":true}', '{"enabled":"yes","token":"1"}'];
    for (const value of values) {
      if (value !== null) writeFileSync(controlPath, value);
      assert.match(handlers.before_agent_start().message.content, /OFF/);
      assert.equal(result(), undefined);
      assert.match((await show()).content[0].text, /Follow is off/);
    }
    assert.equal(existsSync(requestPath), false);
  });
});

test("failed operations and invalid paths never become eligible for navigation", async () => {
  await fixture(async ({ state, event, result, show, requestPath }) => {
    state(true);
    assert.equal(result(event("read", "failed.lua", { isError: true })), undefined);
    for (const path of ["failed.lua", "unread.lua", "", "bad\npath", null]) {
      assert.equal(result(event("read", path, { isError: true })), undefined);
      assert.equal((await show(path)).isError, true);
    }
    assert.equal(result(event("read", "bad\npath")), undefined);
    result();
    for (const line of [0, -1, 1.5, Infinity, "3"]) assert.equal((await show("app.lua", line)).isError, true);
    assert.equal(existsSync(requestPath), false);
  });
});

test("new turns and native session changes discard earlier eligible paths", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(true);
    result();
    handlers.before_agent_start();
    assert.equal((await show()).isError, true);
    result();
    handlers.session_start();
    assert.equal((await show()).isError, true);
    assert.equal(existsSync(requestPath), false);
  });
});

test("relative and home paths resolve against the tool context rather than the process directory", async () => {
  await fixture(async ({ directory, state, event, result, show, requestPath }) => {
    state(true);
    result(event("edit", "./nested/../app.lua"));
    assert.equal((await show(join(directory, "app.lua"))).isError, false);
    result(event("read", "~/app.lua"));
    await show("~/app.lua");
    assert.equal(JSON.parse(readFileSync(requestPath, "utf8")).request.path, join(homedir(), "app.lua"));
  });
});

test("the recent-path limit removes the oldest path while retaining recent files", async () => {
  await fixture(async ({ state, event, result, show }) => {
    state(true);
    for (let index = 0; index < 257; index++) result(event("read", `file-${index}.lua`));
    assert.equal((await show("file-0.lua")).isError, true);
    assert.equal((await show("file-256.lua")).isError, false);
  });
});

test("a reason is required and whitespace is normalized for quickfix", async () => {
  await fixture(async ({ state, result, show, tool, requestPath }) => {
    state(true);
    result();
    assert.deepEqual(tool.parameters.required, ["path", "line", "reason"]);
    assert.match(tool.parameters.properties.reason.description, /not what code changed/);
    for (const reason of [null, "", " \t\n", "x".repeat(501), "bad\u0000reason"]) {
      assert.equal((await show("app.lua", 1, reason)).isError, true);
      assert.equal(existsSync(requestPath), false);
    }
    assert.equal((await show("app.lua", 1, "  Trace the caller\n to its implementation.  ")).isError, false);
    assert.equal(JSON.parse(readFileSync(requestPath, "utf8")).request.reason, "Trace the caller to its implementation.");
  });
});

test("final settlement preserves the last unread jump and reports completion once", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(true);
    handlers.before_agent_start();
    result();
    await show();
    const pending = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.equal(pending.done, false);
    assert.equal(handlers.agent_end, undefined);
    handlers.agent_settled({ aborted: false });
    const completed = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.deepEqual(completed, { ...pending, done: true });
    rmSync(requestPath);
    handlers.agent_settled({ aborted: false });
    assert.equal(existsSync(requestPath), false);
  });
});

test("each prompt uses a fresh run and an empty prompt leaves the earlier report unchanged", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(true);
    handlers.before_agent_start();
    result();
    await show();
    handlers.agent_settled({ aborted: false });
    const first = JSON.parse(readFileSync(requestPath, "utf8"));
    handlers.before_agent_start();
    handlers.agent_settled({ aborted: false });
    assert.deepEqual(JSON.parse(readFileSync(requestPath, "utf8")), first);
    result();
    await show("app.lua", 2, "Show the return value.");
    handlers.agent_settled({ aborted: false });
    const second = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.notEqual(second.run, first.run);
    assert.equal(second.request.reason, "Show the return value.");
    assert.equal(second.done, true);
  });
});

test("completion after a toggle uses the current token without reviving the earlier jump", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(true, "old-token");
    result();
    await show();
    state(false, "new-token");
    handlers.agent_settled({ aborted: true });
    const report = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.equal(report.token, "new-token");
    assert.equal(report.request.token, "old-token");
    assert.equal(report.done, true);
  });
});

test("a native session switch prevents completion of the previous session's pending request", async () => {
  await fixture(async ({ state, handlers, result, show, requestPath }) => {
    state(true);
    result();
    await show();
    handlers.session_start();
    rmSync(requestPath);
    handlers.agent_settled({ aborted: false });
    assert.equal(existsSync(requestPath), false);
  });
});

test("completion reporting failures do not break a finished agent run", async () => {
  await fixture(async ({ state, handlers, result, show, controlPath, requestPath }) => {
    state(true);
    result();
    await show();
    rmSync(controlPath);
    rmSync(requestPath);
    assert.doesNotThrow(() => handlers.agent_settled({ aborted: false }));
    assert.equal(existsSync(requestPath), false);
    state(true);
    await show();
    rmSync(requestPath);
    mkdirSync(requestPath);
    assert.doesNotThrow(() => handlers.agent_settled({ aborted: false }));
  });
});

test("a request write failure reports a failed tool instead of claiming navigation succeeded", async () => {
  await fixture(async ({ state, result, show, requestPath }) => {
    state(true);
    result();
    mkdirSync(requestPath);
    await assert.rejects(show(), /EISDIR/);
  });
});
