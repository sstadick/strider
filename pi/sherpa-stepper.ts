import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

type OperationKind = "search" | "review" | "patch" | "prompt" | "plan";

type SherpaState = {
	activeOperation?: OperationKind;
	// Budget: at most one sherpa_clarify call per user request. Reset in
	// startOperation so the next /prompt or /patch starts fresh.
	clarifyCount: number;
	// Accumulated cost ($) across assistant turns in this session. Pi
	// reports per-turn cost on `message.usage.cost.total`; we sum it so
	// the log widget shows running total. Reset on session_start.
	sessionCost: number;
};

function emptyState(): SherpaState {
	return {
		clarifyCount: 0,
		sessionCost: 0,
	};
}

function collapseWhitespace(text?: string): string | undefined {
	if (!text) return undefined;
	const collapsed = text.replace(/\s+/g, " ").trim();
	return collapsed.length > 0 ? collapsed : undefined;
}

function explicitReviewRules(): string[] {
	return [
		"You are operating in explicit Sherpa review mode.",
		"This mode is read-only. Do not use edit or write.",
		"Answer clearly and directly.",
		"If more context is needed, inspect only nearby code or the smallest relevant surface.",
		"Focus on the review item or question provided by the user.",
		"Follow the most sensible order for understanding the user's question, not discovery order.",
		"Unless the user explicitly asks for a file-by-file audit, focus on the most relevant code.",
	];
}

function searchRules(): string[] {
	return [
		"You are operating in Sherpa search mode.",
		"This mode is read-only. Do not use edit or write.",
		"Prefer a broad `bash` ripgrep (`rg`) or `grep` as the first pass over multiple `read`s — one grep across the repo is usually faster than opening several candidate files.",
		"Return only matching locations in this exact format:",
		"/absolute/path/to/file.ext:line:column,count,notes",
		"Example:",
		"/path/to/project/src/main.tsx:6:1,4,Main app entrypoint; creates the root and renders App",
		"/path/to/project/src/App.tsx:1:1,6,Top-level app component rendered by the entrypoint",
		"line is 1-based.",
		"column is 1-based.",
		"count is how many lines are relevant starting at line.",
		"notes must stay on one line.",
		"Do not include markdown fences, bullets, numbering, or commentary before or after the result lines.",
		"If you find a clear likely match, prefer returning the best match over returning nothing.",
		"If nothing plausibly matches, return no lines.",
	];
}

function promptRules(): string[] {
	return [];
}

function patchRules(): string[] {
	return [
		"You are operating in Sherpa patch mode.",
		"Treat the provided file and range as a strong edit boundary.",
		"Prefer changing only the smallest necessary local region.",
		"Do not expand the edit to other files unless the user explicitly requires it.",
		"Summarize the local patch when you finish.",
	];
}

function planRules(): string[] {
	return [
		"You are operating in Sherpa plan mode.",
		"Your only job this turn is to produce a complete review plan by calling the `sherpa_plan` tool exactly once.",
		"Read whatever files you need first to understand the user's goal, then call sherpa_plan.",
		"Classify the review in the tool call: scope is 'selection' (user gave a range), 'diff' (user wants changes vs a branch/base — include the base ref), or 'free' (open-ended).",
		"Stops must be small — keep each stop ≤ 40 lines. Order them pedagogically (foundations → consumers → tests), not in discovery order.",
		"For 'selection' and 'diff' scopes, the union of stops must cover every line in the selected range / every changed line in the diff.",
		"",
		"LINE NUMBERS — read carefully. Your line numbers must be absolute file line numbers matching the actual file content. Do NOT use offsets relative to the stop's start. If you haven't read the exact range in this turn, read it before writing the plan — do not guess. For each stop you MUST include a `firstLineText` field containing the verbatim (trimmed) content of the file at `startLine`; Sherpa uses it to self-correct if your numbers are off.",
		"",
		"Each stop requires three tiers of detail, written for different surfaces:",
		"  - `title` — short label for the sidebar and TOC",
		"  - `why` — one-sentence hook shown on the current-item card",
		"  - `summary` — 2-3 sentence synopsis for the sidebar Explanation section; skimmable",
		"  - `explanation` — 3-5 sentence narrative rendered as a block annotation in the code buffer, pinned above the stop's start line. Grounded in the actual code — what it does, why it matters, any notable decisions or tradeoffs.",
		"`summary` and `explanation` should not be duplicates. `summary` is the sidebar view; `explanation` is the in-buffer narrative.",
		"",
		"Optional `annotations` array attaches extra pinned notes inside the stop:",
		"  - `kind: 'block'` with `startLine` + `endLine` renders a multi-line note above that sub-range.",
		"  - `kind: 'line'` with `line` renders an end-of-line inline comment on a single line.",
		"Annotation budget (strict): at most one `kind: 'block'` annotation per stop, and at most 25% of the stop's lines may receive a `kind: 'line'` annotation. Use them only when a specific line or sub-range carries real insight — skip them otherwise.",
		"",
		"Do NOT write a long prose reply outside the tool call — all explanations live inside `sherpa_plan`.",
	];
}

function planPrompt(request: string): string {
	return [`Plan request: ${request}`, ...planRules()].join("\n");
}

function explicitReviewPrompt(request: string): string {
	return [`Review request: ${request}`, ...explicitReviewRules()].join("\n");
}

function searchPrompt(request: string): string {
	return [`Search request: ${request}`, ...searchRules()].join("\n");
}

function promptPrompt(request: string): string {
	return [`Prompt request: ${request}`, ...promptRules()].join("\n");
}

function patchPrompt(request: string): string {
	return [`Patch request: ${request}`, ...patchRules()].join("\n");
}

function isSafeReadOnlyBash(command?: string): boolean {
	if (!command) return false;
	const trimmed = command.trim().toLowerCase();
	const allowed = [
		"pwd",
		"ls",
		"tree",
		"find",
		"fd",
		"rg",
		"grep",
		"git status",
		"git diff",
		"git show",
		"git log",
		"git ls-files",
		"git branch",
		"git rev-parse",
		"git grep",
		"head",
		"tail",
	];
	return allowed.some((item) => trimmed === item || trimmed.startsWith(`${item} `));
}

export default function (pi: ExtensionAPI) {
	let state = emptyState();

	function modelLabel(model: any): string | undefined {
		if (!model) return undefined;
		const name = model.name ?? model.id;
		return model.provider ? `${model.provider}/${name}` : name;
	}

	// Compact token count: 14000 → "14k", 1_200_000 → "1.2M". Keeps the
	// winbar readable in narrow log windows. Numbers under 1k render as-is.
	function formatTokens(n: number): string {
		if (n < 1000) return `${n}`;
		if (n < 1_000_000) {
			const k = n / 1000;
			return k >= 100 ? `${Math.round(k)}k` : `${k.toFixed(k >= 10 ? 0 : 1).replace(/\.0$/, "")}k`;
		}
		const m = n / 1_000_000;
		return m >= 100 ? `${Math.round(m)}M` : `${m.toFixed(m >= 10 ? 0 : 1).replace(/\.0$/, "")}M`;
	}

	function statusSuffix(ctx: any): string[] {
		const lines: string[] = [];
		const model = ctx.model;
		const label = modelLabel(model);
		// Attach thinking level to the model line — it's a property of
		// how the model runs, not a separate axis, so pairing them keeps
		// the winbar dense and scannable.
		const thinking = typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
		if (label) {
			lines.push(thinking ? `Model: ${label} (${thinking})` : `Model: ${label}`);
		}

		// Context usage: ctx.getContextUsage() returns { tokens, contextWindow, percent }
		// or undefined (no active model / pre-first-turn). tokens/percent can be null
		// immediately after compaction.
		const usage = typeof ctx.getContextUsage === "function" ? ctx.getContextUsage() : undefined;
		if (usage && usage.contextWindow) {
			const tokens = usage.tokens;
			const percent = usage.percent;
			if (tokens != null && percent != null) {
				lines.push(`Context: ${formatTokens(tokens)} / ${formatTokens(usage.contextWindow)} (${percent.toFixed(1)}%)`);
			} else {
				lines.push(`Context window: ${formatTokens(usage.contextWindow)}`);
			}
		}
		if (state.sessionCost != null) {
			lines.push(`Cost: $${state.sessionCost.toFixed(4)}`);
		}
		return lines;
	}

	function renderStatus(ctx: any): string[] {
		return statusSuffix(ctx);
	}

	function updateWidget(ctx: any) {
		ctx.ui.setWidget("sherpa", renderStatus(ctx));
		ctx.ui.setStatus("sherpa", state.activeOperation ? `${state.activeOperation} active` : "idle");
	}

	// Sherpa-owned tools whose validity is operation-scoped. These are
	// always registered (pi's registerTool is load-time only), but we
	// toggle which ones are *active* per turn via pi.setActiveTools so
	// the model only sees them when they'd actually do something.
	//
	// Without this gating, the model tends to call sherpa_plan during
	// prose turns because the tool name is suggestive — the call
	// quietly no-ops on our side but wastes tokens and looks weird in
	// the transcript.
	const SHERPA_OP_SCOPED_TOOLS = new Set(["sherpa_plan", "sherpa_append_stops"]);

	function toolsForOperation(allNames: string[], kind?: OperationKind): string[] {
		const keep = (name: string): boolean => {
			if (!SHERPA_OP_SCOPED_TOOLS.has(name)) return true;   // non-scoped tools always active
			if (name === "sherpa_plan") return kind === "plan";
			// sherpa_append_stops is only meaningful during plan (appending
			// to the plan being built) or during a /review turn on a free-
			// scope review. We enable it for both — the Lua side silently
			// rejects appends on non-free scopes so the overreach is safe.
			if (name === "sherpa_append_stops") return kind === "plan" || kind === "review";
			return false;
		};
		return allNames.filter(keep);
	}

	function applyOperationTools(ctx: any, kind?: OperationKind) {
		if (typeof pi.getAllTools !== "function" || typeof pi.setActiveTools !== "function") {
			return; // older pi runtimes: leave tool visibility alone
		}
		const allNames = pi.getAllTools().map((t: any) => t.name);
		const active = toolsForOperation(allNames, kind);
		try {
			pi.setActiveTools(active);
		} catch (_err) {
			// Non-fatal: if pi rejects the list (e.g. unknown tool name),
			// fall through with whatever was already active.
		}
	}

	function startOperation(kind: OperationKind, ctx: any) {
		state.activeOperation = kind;
		state.clarifyCount = 0;
		applyOperationTools(ctx, kind);
		updateWidget(ctx);
	}

	function finishOperation(ctx: any) {
		state.activeOperation = undefined;
		applyOperationTools(ctx, undefined);
		updateWidget(ctx);
	}

	function readOnlyOperation(): boolean {
		return (
			state.activeOperation === "review" ||
			state.activeOperation === "search" ||
			state.activeOperation === "plan"
		);
	}

	pi.on("session_start", async (event: any, ctx: any) => {
		state = emptyState();
		// Start with Sherpa's op-scoped tools hidden. They'll be turned
		// on by startOperation when a command that needs them runs.
		applyOperationTools(ctx, undefined);
		updateWidget(ctx);
		if (event.reason === "new" || event.reason === "fork" || event.reason === "resume") {
			ctx.ui.setStatus("sherpa-session", event.reason);
		}
	});

	pi.on("tool_call", async (event: any, ctx: any) => {
		if (readOnlyOperation()) {
			if (event.toolName === "edit" || event.toolName === "write") {
				ctx.ui.notify(`Blocked write tool in ${state.activeOperation} mode: ${event.toolName}`, "warning");
				return { block: true, reason: `Sherpa ${state.activeOperation} mode is read-only. Do not edit or write files.` };
			}
			if (event.toolName === "bash" && !isSafeReadOnlyBash(event.input?.command)) {
				ctx.ui.notify(`Blocked unsafe bash command in ${state.activeOperation} mode`, "warning");
				return {
					block: true,
					reason: `Sherpa ${state.activeOperation} mode only allows safe read-only inspection commands. Use read, rg, grep, find, ls, tree, or git read-only inspection.`,
				};
			}
		}
		return undefined;
	});

	pi.on("message_end", async (event: any, ctx: any) => {
		// Accumulate per-turn cost from assistant message usage. Absent on
		// non-assistant messages and on free-tier / subscription paths.
		const cost = event.message?.usage?.cost?.total;
		if (typeof cost === "number" && Number.isFinite(cost)) {
			state.sessionCost += cost;
		}
		if (state.activeOperation) finishOperation(ctx);
		else updateWidget(ctx);
	});

	const annotationSchema = Type.Object({
		kind: Type.Union([Type.Literal("block"), Type.Literal("line")], {
			description:
				"'block' renders as a multi-line note above a sub-range; 'line' renders as an end-of-line inline comment on a single line.",
		}),
		line: Type.Optional(
			Type.Number({ description: "Required for kind='line': 1-based target line within the stop." }),
		),
		startLine: Type.Optional(
			Type.Number({ description: "Required for kind='block': 1-based first line of the sub-range (inclusive)." }),
		),
		endLine: Type.Optional(
			Type.Number({ description: "Required for kind='block': 1-based last line of the sub-range (inclusive)." }),
		),
		text: Type.String({
			description:
				"Annotation content. For line annotations keep it to a short phrase (≤ ~80 chars). For block annotations a short paragraph is fine.",
		}),
	});

	const stopSchema = Type.Object({
		path: Type.String({ description: "Absolute or cwd-relative path to the file for this stop" }),
		startLine: Type.Number({ description: "1-based first line of the stop (inclusive), absolute file line number" }),
		endLine: Type.Number({ description: "1-based last line of the stop (inclusive), absolute file line number" }),
		firstLineText: Type.String({
			description:
				"Verbatim content of the file at `startLine` (trimmed of leading/trailing whitespace). Used as an anchor to self-correct if your line numbers are off. Must match a line that actually exists in the file.",
		}),
		title: Type.String({ description: "Short label for the stop, shown in the sidebar" }),
		why: Type.String({ description: "One-sentence hook shown in the sidebar current-item card and TOC" }),
		summary: Type.String({
			description:
				"2-3 sentence high-level synopsis shown in the review pane's Explanation section. Skimmable; complements the longer buffer annotation.",
		}),
		explanation: Type.String({
			description:
				"3-5 sentence narrative rendered as a block annotation above the stop's start line in the code buffer. Grounded in the actual code — what it does, why it matters, notable decisions.",
		}),
		annotations: Type.Optional(
			Type.Array(annotationSchema, {
				description:
					"Optional extra pinned notes inside this stop. Line numbers are absolute file line numbers (same frame as startLine/endLine), NOT offsets from the stop's start. Use sparingly — limit to lines that carry real insight. At most 25% of the stop's lines should receive a line annotation.",
			}),
		),
	});

	const planSchema = Type.Object({
		scope: Type.Union(
			[Type.Literal("selection"), Type.Literal("diff"), Type.Literal("free")],
			{ description: "What kind of review this is — determines coverage expectations" },
		),
		base: Type.Optional(Type.String({ description: "Base ref for diff reviews (required when scope='diff')" })),
		stops: Type.Array(stopSchema, { minItems: 1, description: "Ordered list of review stops" }),
	});

	pi.registerTool({
		name: "sherpa_plan",
		label: "Sherpa plan",
		description: "Submit the review plan for a Sherpa review. Must be called exactly once during plan mode.",
		parameters: planSchema,
		promptSnippet: "sherpa_plan: submit the review plan during Sherpa plan mode.",
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, _ctx: any) {
			if (params.scope === "diff" && !params.base) {
				throw new Error("sherpa_plan: base is required when scope='diff'");
			}
			return {
				content: [{ type: "text", text: `ok: ${params.stops.length} stop(s)` }],
				details: { count: params.stops.length, scope: params.scope },
			} as any;
		},
	});

	const appendStopsSchema = Type.Object({
		stops: Type.Array(stopSchema, { minItems: 1, description: "Stops to append to the current free-scope review" }),
	});

	pi.registerTool({
		name: "sherpa_append_stops",
		label: "Sherpa append stops",
		description: "Append new stops to an active free-scope Sherpa review. Only valid mid-review on free-scope plans.",
		parameters: appendStopsSchema,
		promptSnippet: "sherpa_append_stops: append stops to a free-scope Sherpa review in progress.",
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, _ctx: any) {
			return {
				content: [{ type: "text", text: `ok: appended ${params.stops.length} stop(s)` }],
				details: { count: params.stops.length },
			} as any;
		},
	});

	const clarifySchema = Type.Object({
		kind: Type.Union(
			[Type.Literal("question"), Type.Literal("plan_proposal"), Type.Literal("confirm")],
			{
				description:
					"'question' for open-ended ambiguity; 'plan_proposal' when you want the user to approve/edit a proposed approach before you act; 'confirm' for a yes/no gate on a destructive or expensive operation.",
			},
		),
		title: Type.String({ description: "One-line heading shown at the top of the user's prompt." }),
		body: Type.String({
			description:
				"Full context / question / proposed plan shown to the user. For 'plan_proposal' this is used as the editor's prefill — the user may submit as-is or edit before accepting.",
		}),
	});

	pi.registerTool({
		name: "sherpa_clarify",
		label: "Sherpa clarify",
		description:
			"Pause the current turn and ask the user for clarification, approval of a proposed plan, or confirmation of a destructive action. Available during /prompt and /patch. Use sparingly — prefer action over questions. Only clarify when a specific ambiguity would change your approach non-trivially. If the user cancels, stop work and explain what you were asking — do NOT proceed with a guess.",
		parameters: clarifySchema,
		promptSnippet:
			"sherpa_clarify: pause and ask the user (question / plan_proposal / confirm) when truly ambiguous.",
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
			const text = (s: string) => ({
				content: [{ type: "text", text: s }],
				details: { kind: params.kind },
			}) as any;

			if (state.clarifyCount >= 1) {
				throw new Error(
					"sherpa_clarify: budget exhausted for this request. Proceed with your best interpretation and summarize the ambiguity in your final reply.",
				);
			}
			state.clarifyCount += 1;

			if (params.kind === "confirm") {
				// ctx.ui.confirm returns false on both "No" and cancel — pi's
				// API doesn't distinguish. Treat false as "no"; don't claim
				// cancellation here.
				const confirmed = await ctx.ui.confirm(params.title, params.body);
				return text(confirmed ? "yes" : "no");
			}

			// question uses the floating editor directly.
			// plan_proposal uses a read-only preview + accept/modify/reject
			// picker on the Lua side. Both go through ctx.ui.editor; we
			// tag the plan_proposal title with a sentinel so the Lua
			// handler can route to the multi-step flow. The user-facing
			// title has the sentinel stripped before display.
			let title = params.title;
			let prefill = "";
			if (params.kind === "plan_proposal") {
				title = `[sherpa-plan-proposal] ${params.title}`;
				prefill = params.body;
			}
			const answer = await ctx.ui.editor(title, prefill);
			if (answer === undefined) {
				return text("[user cancelled clarification]");
			}
			return text(answer);
		},
	});

	pi.registerCommand("plan", {
		description: "Produce a Sherpa review plan",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /plan <request>", "warning");
				return;
			}
			startOperation("plan", ctx);
			pi.sendUserMessage(planPrompt(request));
		},
	});

	pi.registerCommand("review", {
		description: "Run an explicit Sherpa review request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /review <request>", "warning");
				return;
			}
			startOperation("review", ctx);
			pi.sendUserMessage(explicitReviewPrompt(request));
		},
	});

	pi.registerCommand("search", {
		description: "Run a Sherpa structured code search",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /search <request>", "warning");
				return;
			}
			startOperation("search", ctx);
			pi.sendUserMessage(searchPrompt(request));
		},
	});

	pi.registerCommand("prompt", {
		description: "Run a Sherpa prompt — plain agent turn with clarify available",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /prompt <request>", "warning");
				return;
			}
			startOperation("prompt", ctx);
			pi.sendUserMessage(promptPrompt(request));
		},
	});

	pi.registerCommand("patch", {
		description: "Run a Sherpa local patch request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /patch <request>", "warning");
				return;
			}
			startOperation("patch", ctx);
			pi.sendUserMessage(patchPrompt(request));
		},
	});

	// /models — fuzzy pick a model. Drives the Lua-side fzf/telescope picker
	// via ctx.ui.select. The extension handles apply via pi.setModel so the
	// Neovim plugin stays a dumb UI shell.
	pi.registerCommand("models", {
		description: "Switch the active pi model (fuzzy picker)",
		handler: async (args: any, ctx: any) => {
			const models = ctx.modelRegistry.getAvailable();
			if (!models || models.length === 0) {
				ctx.ui.notify("No available models (check API keys)", "warning");
				return;
			}
			// Filter by arg if given — substring match on provider/id/name.
			const filter = (args ?? "").trim().toLowerCase();
			const candidates = filter
				? models.filter((m: any) =>
					`${m.provider}/${m.id} ${m.name ?? ""}`.toLowerCase().includes(filter),
				)
				: models;
			if (candidates.length === 0) {
				ctx.ui.notify(`No models match: ${filter}`, "warning");
				return;
			}

			const current = ctx.model;
			const currentKey = current ? `${current.provider}/${current.id}` : undefined;
			const labelFor = (m: any) => {
				const key = `${m.provider}/${m.id}`;
				const marker = key === currentKey ? " ●" : "";
				const name = m.name && m.name !== m.id ? ` — ${m.name}` : "";
				return `${key}${name}${marker}`;
			};
			const byLabel = new Map<string, any>();
			const options: string[] = [];
			for (const m of candidates) {
				const label = labelFor(m);
				byLabel.set(label, m);
				options.push(label);
			}

			const choice = await ctx.ui.select("Switch model", options);
			if (!choice) return;
			const chosen = byLabel.get(choice);
			if (!chosen) {
				ctx.ui.notify(`Unknown selection: ${choice}`, "error");
				return;
			}
			const ok = await pi.setModel(chosen);
			if (!ok) {
				ctx.ui.notify(`No API key for ${chosen.provider}/${chosen.id}`, "error");
				return;
			}
			ctx.ui.notify(`Model: ${chosen.provider}/${chosen.name ?? chosen.id}`, "info");
			updateWidget(ctx);
		},
	});

	// /thinking — cycle or set the thinking level. With no args, cycles
	// to the next supported level (same as pi's own shift-tab). With an
	// arg, sets explicitly; pi clamps if the model doesn't support the
	// requested level. Widget refreshes so the `(level)` suffix on the
	// model line reflects the change immediately.
	const THINKING_CYCLE = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;
	pi.registerCommand("thinking", {
		description: "Cycle or set the thinking level (model-clamped)",
		handler: async (args: any, ctx: any) => {
			const arg = (args ?? "").trim().toLowerCase();
			const current = typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
			if (arg) {
				if (!(THINKING_CYCLE as readonly string[]).includes(arg)) {
					ctx.ui.notify(
						`Unknown thinking level: ${arg}. Valid: ${THINKING_CYCLE.join(", ")}`,
						"warning",
					);
					return;
				}
				pi.setThinkingLevel(arg as any);
			} else {
				// Cycle: find current in the list, advance by one. If the
				// model clamps (e.g. non-reasoning model forced to "off"),
				// getThinkingLevel() next read reflects the actual setting.
				const idx = current ? THINKING_CYCLE.indexOf(current as any) : -1;
				const next = THINKING_CYCLE[(idx + 1) % THINKING_CYCLE.length];
				pi.setThinkingLevel(next as any);
			}
			const now = typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
			ctx.ui.notify(`Thinking: ${now ?? "unknown"}`, "info");
			updateWidget(ctx);
		},
	});

	// /tree — fuzzy pick any user-message entry to navigate the session tree
	// to. Flat picker over user messages (same surface as /fork) driven via
	// pi.navigateTree. For full tree visualization, use pi's TUI /tree.
	pi.registerCommand("tree", {
		description: "Jump to a previous user message (session tree)",
		handler: async (_args: any, ctx: any) => {
			const entries = ctx.sessionManager.getEntries() ?? [];
			const leafId = ctx.sessionManager.getLeafId?.();
			const candidates: Array<{ id: string; preview: string; isLeaf: boolean }> = [];
			for (const entry of entries) {
				// Session entries wrap messages: { type: "message", id, message: { role, content, ... } }.
				// Skip non-message entries (model_change, compaction, etc.) and non-user messages.
				if (entry?.type !== "message") continue;
				const msg = entry.message;
				if (!msg || msg.role !== "user") continue;
				const content = msg.content;
				const raw = typeof content === "string"
					? content
					: Array.isArray(content)
						? content
							.filter((c: any) => c?.type === "text")
							.map((c: any) => c.text)
							.join(" ")
						: "";
				const preview = collapseWhitespace(raw)?.slice(0, 120) ?? "(empty)";
				candidates.push({ id: entry.id, preview, isLeaf: entry.id === leafId });
			}
			if (candidates.length === 0) {
				ctx.ui.notify("No user messages to navigate to", "warning");
				return;
			}

			const byLabel = new Map<string, string>();
			const options: string[] = [];
			candidates.forEach((c, i) => {
				const marker = c.isLeaf ? " ●" : "";
				const label = `${String(i + 1).padStart(3, " ")}: ${c.preview}${marker}`;
				byLabel.set(label, c.id);
				options.push(label);
			});

			const choice = await ctx.ui.select("Navigate to message", options);
			if (!choice) return;
			const targetId = byLabel.get(choice);
			if (!targetId) return;
			await navigateTo(ctx, targetId);
			updateWidget(ctx);
		},
	});

	// Shared helper for /tree navigation.
	async function navigateTo(ctx: any, targetId: string): Promise<boolean> {
		try {
			const result = await ctx.navigateTree(targetId);
			if (result?.cancelled) {
				ctx.ui.notify("Tree navigation cancelled", "info");
				return false;
			}
			return true;
		} catch (err: any) {
			ctx.ui.notify(`Tree navigation failed: ${err?.message ?? err}`, "error");
			return false;
		}
	}
}
