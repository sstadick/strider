// Execute the real extension and local modules without pi, providers, or npm deps.
// Node >=22.15 supplies registerHooks; native TS stripping loads the source as-is.
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const piRoot = new URL("../../pi/", import.meta.url);
const moduleURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;
const agentStub = moduleURL(`
  export const SessionManager = new Proxy({}, {
    get() { throw new Error("Lifecycle tests must not access stored sessions"); }
  });
`);
const typeboxStub = moduleURL(`
  // Schemas are registered, not validated or executed by this harness.
  export const Type = Object.fromEntries(
    ["Object", "Union", "Literal", "Optional", "Number", "String", "Array"]
      .map(kind => [kind, (...args) => ({ kind, args })])
  );
`);
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (["@mariozechner/pi-coding-agent", "@earendil-works/pi-coding-agent"].includes(specifier)) {
      return { url: agentStub, shortCircuit: true };
    }
    if (specifier === "@sinclair/typebox") return { url: typeboxStub, shortCircuit: true };
    if (context.parentURL?.startsWith(piRoot.href) && /^\.\/.*\.js$/.test(specifier)) {
      return nextResolve(specifier.replace(/\.js$/, ".ts"), context);
    }
    // Never accidentally load installed packages or user configuration.
    assert.ok(specifier.startsWith("node:") || specifier.startsWith("file:"), specifier);
    return nextResolve(specifier, context);
  },
});
const { default: registerStepper } = await import(new URL("strider-stepper.ts", piRoot));

const builtinTools = ["read", "edit", "write", "bash", "grep", "find", "ls"];
const readOnlyModes = ["plan", "review", "search"];
const unsafeBash = { command: "touch should-not-exist" };

function contextFor(h) {
  return {
    // Deliberately idle even between low-level runs: Strider must own its guard.
    isIdle: () => h.idle,
    model: { provider: "test", id: "no-provider" },
    sessionManager: { getSessionId: () => "abcdef012345", getSessionName: () => "test" },
    getContextUsage: () => h.usage,
    ui: {
      setWidget: (key, lines) => h.widgets.push({ key, lines: [...lines] }),
      setStatus: (key, value) => h.statuses.set(key, value),
      notify: (message, level) => h.notifications.push({ message, level }),
    },
  };
}

function apiFor(h) {
  return {
    on: (event, handler) => {
      const handlers = h.handlers.get(event) ?? [];
      handlers.push(handler);
      h.handlers.set(event, handlers);
    },
    registerCommand: (name, command) => h.commands.set(name, command),
    registerTool: (tool) => h.tools.set(tool.name, tool),
    getAllTools: () => [...h.tools.values()],
    setActiveTools: (names) => {
      for (const name of names) assert.ok(h.tools.has(name), `unregistered tool: ${name}`);
      h.activeTools = [...names];
      h.toolUpdates.push([...names]);
    },
    sendUserMessage: (message) => h.sent.push(message),
    getThinkingLevel: () => "medium",
  };
}

async function createHarness() {
  const h = {
    handlers: new Map(), commands: new Map(),
    tools: new Map(builtinTools.map(name => [name, { name }])),
    widgets: [], statuses: new Map(), notifications: [], sent: [],
    activeTools: [], toolUpdates: [], idle: true,
    usage: { tokens: 14000, contextWindow: 200000, percent: 7 },
  };
  h.ctx = contextFor(h);
  h.emit = async (type, fields = {}) => {
    let result;
    for (const handler of h.handlers.get(type) ?? []) {
      result = await handler({ type, ...fields }, h.ctx);
    }
    return result;
  };
  h.command = async (name, args = "inspect this repository") => {
    assert.ok(h.commands.has(name), `missing command: ${name}`);
    return h.commands.get(name).handler(args, h.ctx);
  };
  h.call = (toolName, input = {}) => h.emit("tool_call", { toolName, input, toolCallId: "probe" });
  registerStepper(apiFor(h));
  await h.emit("session_start", { reason: "new" });
  assertTools(h);
  assert.equal(h.statuses.get("strider"), "idle");
  return h;
}

function assertTools(h, mode) {
  const expected = [...h.tools.keys()].filter(name => {
    if (name === "strider_plan") return mode === "plan";
    if (name === "strider_append_stops") return mode === "plan" || mode === "review";
    return true;
  });
  assert.deepEqual(h.activeTools, expected, `operation-scoped tools for ${mode ?? "idle"}`);
  assert.ok(h.tools.has("strider_plan") && h.tools.has("strider_append_stops"));
  assert.ok(h.activeTools.includes("strider_clarify"));
}

async function assertProtected(h, mode, boundary) {
  for (const tool of ["edit", "write"]) {
    const result = await h.call(tool);
    assert.equal(result?.block, true, `${mode}: ${tool} must remain blocked after ${boundary}`);
    assert.match(result.reason, new RegExp(`Strider ${mode} mode`));
  }
  assert.equal((await h.call("bash", unsafeBash))?.block, true, `${mode}: unsafe bash after ${boundary}`);
  assert.equal(await h.call("bash", { command: "git status --short" }), undefined);
  assert.equal(await h.call("read", { path: "example.ts" }), undefined);
  assertTools(h, mode);
  assert.equal(h.statuses.get("strider"), `${mode} active`, boundary);
}

async function assertBusy(h, mode) {
  const sent = h.sent.length;
  const updates = h.toolUpdates.length;
  for (const next of readOnlyModes) {
    await h.command(next);
    assert.equal(h.sent.length, sent, `${next} must wait for ${mode} to settle`);
    assert.match(h.notifications.at(-1).message, new RegExp(`already running \\(${mode}\\)`));
    assert.equal(h.notifications.at(-1).level, "warning");
  }
  assert.equal(h.toolUpdates.length, updates, "rejected request must not change tools");
}

function usage(total) {
  return { input: 10, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 12,
    cost: { input: 0, output: total, cacheRead: 0, cacheWrite: 0, total } };
}

function assistant(stopReason = "stop", cost = 0.1) {
  return { role: "assistant", content: [{ type: "text", text: "finished" }],
    api: "test", provider: "test", model: "no-provider", timestamp: 1,
    stopReason, usage: usage(cost) };
}

function messageFor(kind) {
  if (kind === "user") return { role: "user", content: "inspect", timestamp: 1 };
  if (kind === "toolResult") return { role: "toolResult", toolCallId: "call-1", toolName: "read",
    content: [{ type: "text", text: "source" }], isError: false, timestamp: 2 };
  if (kind === "tool-call") return { ...assistant("toolUse"), content: [
    { type: "toolCall", id: "call-1", name: "read", arguments: { path: "example.ts" } },
  ] };
  if (kind === "retry-error") return { ...assistant("error"), errorMessage: "529 overloaded" };
  if (kind === "aborted") return assistant("aborted");
  assert.ok(["final", "retry-final"].includes(kind), kind);
  return assistant();
}

async function messageBoundary(mode, kind) {
  // Isolate each boundary: skipping user messages alone is not a sufficient fix.
  const h = await createHarness();
  await h.command(mode);
  assert.equal(h.sent.length, 1);
  await assertProtected(h, mode, "command");
  const updates = h.toolUpdates.length;
  const widgets = h.widgets.length;
  await h.emit("message_end", { message: messageFor(kind) });
  await assertProtected(h, mode, `${kind} message_end`);
  await assertBusy(h, mode);
  assert.equal(h.toolUpdates.length, updates, "message_end must not change operation tools");
  assert.equal(h.widgets.length, widgets + 1, "every message refreshes the widget");
}

async function lowLevelEnd(mode, willRetry) {
  const h = await createHarness();
  await h.command(mode);
  await h.emit("agent_end", { messages: [], willRetry: willRetry === "true" });
  await assertProtected(h, mode, "agent_end");
  await assertBusy(h, mode);
}

async function retrySequence(mode) {
  const h = await createHarness();
  await h.command(mode);
  const updates = h.toolUpdates.length;
  for (const kind of ["user", "tool-call", "toolResult", "retry-error"]) {
    await h.emit("message_end", { message: messageFor(kind) });
    await assertProtected(h, mode, kind);
  }
  await h.emit("agent_end", { messages: [messageFor("retry-error")], willRetry: true });
  await assertBusy(h, mode);
  await h.emit("auto_retry_start", { attempt: 1, maxAttempts: 3, delayMs: 0, errorMessage: "overloaded" });
  await h.emit("agent_start");
  await h.emit("message_end", { message: messageFor("retry-final") });
  await h.emit("agent_end", { messages: [messageFor("retry-final")], willRetry: false });
  await h.emit("auto_retry_end", { success: true, attempt: 1 });
  await assertProtected(h, mode, "successful retry before settlement");
  await assertBusy(h, mode);
  assert.equal(h.toolUpdates.length, updates);
  await h.emit("agent_settled", { aborted: false });
  assertTools(h);
  assert.equal(h.statuses.get("strider"), "idle");
}

async function settlement(mode, outcome) {
  const h = await createHarness();
  await h.command(mode);
  // Cover settlement without a model response (not pre-run startup rejection).
  const messages = outcome === "no-message" || outcome === "early-abort" ? [] : [
    messageFor(outcome === "error" ? "retry-error" : outcome === "abort" ? "aborted" : "final"),
  ];
  for (const message of messages) await h.emit("message_end", { message });
  await h.emit("agent_end", { messages, willRetry: false });
  await assertBusy(h, mode);
  await h.emit("agent_settled", { aborted: outcome.includes("abort") });
  assert.equal(h.statuses.get("strider"), "idle", `${outcome} releases the operation`);
  assertTools(h);
  for (const tool of ["edit", "write", "bash"]) assert.equal(await h.call(tool, unsafeBash), undefined);
  const updates = h.toolUpdates.length;
  await h.emit("agent_settled", { aborted: false });
  assert.equal(h.toolUpdates.length, updates, "duplicate idle settlement does not alter tools");
  const next = readOnlyModes[(readOnlyModes.indexOf(mode) + 1) % readOnlyModes.length];
  await h.command(next);
  assert.equal(h.sent.length, 2, "settled operation permits the next request");
  await assertProtected(h, next, "next request");
}

async function chatReadOnly() {
  const h = await createHarness();
  await h.command("strider_chat_read_only", "on");
  for (const mode of ["prompt", "patch", "plan", "prompt"]) {
    await h.command(mode);
    await h.emit("message_end", { message: messageFor("user") });
    const guard = await h.call("write");
    assert.equal(guard?.block, mode === "patch" ? undefined : true, mode);
    if (mode === "prompt") assert.match(guard.reason, /chat read-only mode/);
    assert.equal((await h.call("bash", unsafeBash))?.block, mode === "plan" ? true : undefined);
    await h.emit("agent_settled", { aborted: mode === "patch" });
    assert.equal(await h.call("write"), undefined, "chat flag does not guard idle work");
  }
  await h.command("prompt");
  await h.command("strider_chat_read_only", "off");
  assert.equal(await h.call("write"), undefined, "chat can be toggled off mid-request");
  await h.command("strider_chat_read_only", "on");
  assert.equal((await h.call("write"))?.block, true);
  await h.emit("agent_settled", { aborted: true });
  await h.command("plan");
  await h.command("strider_chat_read_only", "off");
  await assertProtected(h, "plan", "chat read-only disabled");
  await h.emit("agent_settled", { aborted: false });
  await h.command("prompt");
  assert.equal(await h.call("write"), undefined, "settlement preserves disabled chat flag too");
}

async function costAndWidgets() {
  const h = await createHarness();
  await h.command("plan");
  const messages = [messageFor("user"), assistant("toolUse", 0.125), messageFor("toolResult"),
    assistant("error", 0.025), assistant("stop", 0.15),
    ...[undefined, NaN, Infinity, "7"].map(cost => ({ ...assistant(), usage: usage(cost) }))];
  let total = 0;
  for (const message of messages) {
    const count = h.widgets.length;
    await h.emit("message_end", { message });
    const cost = message.usage?.cost?.total;
    if (typeof cost === "number" && Number.isFinite(cost)) total += cost;
    assert.equal(h.widgets.length, count + 1);
    assert.ok(h.widgets.at(-1).lines.includes(`Cost: $${total.toFixed(4)}`));
    assert.equal(h.statuses.get("strider"), "plan active");
  }
  await h.emit("agent_end", { messages, willRetry: false });
  await h.emit("agent_settled", { aborted: false });
  assert.deepEqual(h.widgets.at(-1), { key: "strider", lines: [
    "Session: test abcdef0", "Model: test/no-provider (medium)",
    "Context: 14k / 200k (7.0%)", "Cost: $0.3000",
  ] });
  await h.emit("message_end", { message: assistant("stop", 0.2) });
  assert.ok(h.widgets.at(-1).lines.includes("Cost: $0.5000"), "idle messages still add cost");
  await h.emit("session_start", { reason: "new" });
  assert.ok(h.widgets.at(-1).lines.includes("Cost: $0.0000"));
}

const scenarios = { messageBoundary, lowLevelEnd, retrySequence, settlement, chatReadOnly, costAndWidgets };
const [scenario, ...args] = process.argv.slice(2);
assert.ok(Object.hasOwn(scenarios, scenario), `unknown scenario: ${scenario}`);
await scenarios[scenario](...args);
console.log(`PASS ${scenario} ${args.join(" ")}`);
