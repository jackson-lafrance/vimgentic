const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const guidance = readFileSync(join(__dirname, "pairing.md"), "utf8").trim();

module.exports = function pairing(pi) {
  pi.on("before_agent_start", (event) => ({
    systemPrompt: event.systemPrompt + "\n\n" + guidance,
  }));
};
