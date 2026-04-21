import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

type OperationKind = "search" | "review" | "patch" | "prompt" | "plan";

type SherpaState = {
	activeOperation?: OperationKind;
	lastTouchedFile?: string;
	recentFiles: string[];
	lastAssistantSummary?: string;
	// Budget: at most one sherpa_clarify call per user request. Reset in
	// startOperation so the next /prompt or /patch starts fresh.
	clarifyCount: number;
};

function emptyState(): SherpaState {
	return {
		recentFiles: [],
		clarifyCount: 0,
	};
}

function collapseWhitespace(text?: string): string | undefined {
	if (!text) return undefined;
	const collapsed = text.replace(/\s+/g, " ").trim();
	return collapsed.length > 0 ? collapsed : undefined;
}

function assistantText(message: any): string | undefined {
	if (!message || message.role !== "assistant") return undefined;
	const parts = (message.content ?? [])
		.filter((item: any) => item.type === "text" && item.text)
		.map((item: any) => item.text);
	return parts.length > 0 ? parts.join("\n") : undefined;
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

function clarifyGuidance(): string[] {
	return [
		"",
		"If the request is genuinely ambiguous, or you've discovered the change is much larger or more nuanced than the prompt implies, you MAY call the `sherpa_clarify` tool once before proceeding.",
		"Prefer action over questions. Only clarify when a specific ambiguity would change your approach in a non-trivial way. Do NOT clarify about preferences, style, or anything you can reasonably decide yourself.",
		"Use `kind: 'question'` for open-ended ambiguity, `kind: 'plan_proposal'` for a large change where the user should see the shape before you act, and `kind: 'confirm'` for destructive or expensive operations.",
		"If the user cancels the clarification, stop work and produce a short reply explaining what you were asking about — do NOT proceed with a guess.",
	];
}

function promptRules(): string[] {
	// Sherpa adds no mode-specific behavior here — the user's global pi
	// system prompt (APPEND_SYSTEM.md + pi defaults) governs. Only carry
	// the clarify tool affordance so the model knows it exists.
	return clarifyGuidance();
}

function patchRules(): string[] {
	return [
		"You are operating in Sherpa patch mode.",
		"Treat the provided file and range as a strong edit boundary.",
		"Prefer changing only the smallest necessary local region.",
		"Do not expand the edit to other files unless the user explicitly requires it.",
		"Summarize the local patch when you finish.",
		...clarifyGuidance(),
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

	function trackPath(path: string) {
		state.lastTouchedFile = path;
		state.recentFiles = [path, ...state.recentFiles.filter((item) => item !== path)].slice(0, 5);
	}

	function renderStatus(): string[] {
		if (!state.activeOperation) {
			const lines = ["Sherpa: idle", "Use /review, /search, /prompt, or /patch to start."];
			if (state.lastTouchedFile) lines.push(`Last file: ${state.lastTouchedFile}`);
			if (state.lastAssistantSummary) lines.push(`Last response: ${state.lastAssistantSummary}`);
			return lines;
		}

		const readOnly =
			state.activeOperation === "review" ||
			state.activeOperation === "search" ||
			state.activeOperation === "plan";
		const lines = [
			`Sherpa operation: ${state.activeOperation}`,
			readOnly ? "Mode: read-only" : "Mode: edits allowed",
			"Waiting for assistant response...",
		];
		if (state.lastTouchedFile) lines.push(`Last file: ${state.lastTouchedFile}`);
		return lines;
	}

	function updateWidget(ctx: any) {
		ctx.ui.setWidget("sherpa", renderStatus());
		ctx.ui.setStatus("sherpa-kind", state.activeOperation);
		ctx.ui.setStatus("sherpa-operation", state.activeOperation);
		ctx.ui.setStatus("sherpa", state.activeOperation ? `${state.activeOperation} active` : "idle");
	}

	function startOperation(kind: OperationKind, ctx: any) {
		state.activeOperation = kind;
		state.lastAssistantSummary = undefined;
		state.clarifyCount = 0;
		updateWidget(ctx);
	}

	function finishOperation(ctx: any) {
		state.activeOperation = undefined;
		updateWidget(ctx);
	}

	function readOnlyOperation(): boolean {
		return (
			state.activeOperation === "review" ||
			state.activeOperation === "search" ||
			state.activeOperation === "plan"
		);
	}

	pi.on("session_start", async (_event: any, ctx: any) => {
		state = emptyState();
		updateWidget(ctx);
	});

	pi.on("before_agent_start", async (event: any, _ctx: any) => {
		// Session-wide guidance appended to the base system prompt. Only
		// suggestive — harmless when no subagent/task tool is available.
		const extra = [
			"",
			"If a subagent, task, or agent-spawning tool is available to you, consider using it for independent read-heavy subtasks (searching multiple areas, summarizing unrelated files, pre-computing explanations for distinct code regions). Subagent work parallelizes and keeps the main turn focused.",
			"If no such tool is available, just proceed without subagents.",
		].join("\n");
		return {
			systemPrompt: (event.systemPrompt ?? "") + extra,
		};
	});

	pi.on("tool_call", async (event: any, ctx: any) => {
		const path = event.input?.path;
		if (path && ["read", "edit", "write"].includes(event.toolName)) trackPath(path);

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

		updateWidget(ctx);
		return undefined;
	});

	pi.on("message_end", async (event: any, ctx: any) => {
		const text = assistantText(event.message);
		if (text) {
			state.lastAssistantSummary = collapseWhitespace(text);
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
			"Pause the current turn and ask the user for clarification, approval of a proposed plan, or confirmation of a destructive action. Available during /prompt and /patch. Use sparingly.",
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

			// question + plan_proposal both use the editor; plan_proposal
			// prefills the editor with the proposal so the user can accept
			// as-is, edit, or cancel. question leaves the editor empty.
			const prefill = params.kind === "plan_proposal" ? params.body : "";
			const answer = await ctx.ui.editor(params.title, prefill);
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
}
