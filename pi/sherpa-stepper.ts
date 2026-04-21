import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type OperationKind = "search" | "teach" | "patch" | "work";

type SherpaState = {
	activeOperation?: OperationKind;
	lastTouchedFile?: string;
	recentFiles: string[];
	lastAssistantSummary?: string;
};

function emptyState(): SherpaState {
	return {
		recentFiles: [],
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

function explicitTeachRules(): string[] {
	return [
		"You are operating in explicit Sherpa teach/review mode.",
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

function workRules(): string[] {
	return [
		"You are operating in Sherpa work mode.",
		"You may make broader changes than tightly bounded patch mode.",
		"Prefer coherent progress over tiny forced stops.",
		"When you finish, summarize what changed and what should be reviewed next.",
	];
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

function explicitTeachPrompt(request: string): string {
	return [`Teach/review request: ${request}`, ...explicitTeachRules()].join("\n");
}

function searchPrompt(request: string): string {
	return [`Search request: ${request}`, ...searchRules()].join("\n");
}

function workPrompt(request: string): string {
	return [`Work request: ${request}`, ...workRules()].join("\n");
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
			const lines = ["Sherpa: idle", "Use /teach, /search, /work, or /patch to start."];
			if (state.lastTouchedFile) lines.push(`Last file: ${state.lastTouchedFile}`);
			if (state.lastAssistantSummary) lines.push(`Last response: ${state.lastAssistantSummary}`);
			return lines;
		}

		const lines = [
			`Sherpa operation: ${state.activeOperation}`,
			state.activeOperation === "teach" || state.activeOperation === "search"
				? "Mode: read-only"
				: "Mode: edits allowed",
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
		updateWidget(ctx);
	}

	function finishOperation(ctx: any) {
		state.activeOperation = undefined;
		updateWidget(ctx);
	}

	function readOnlyOperation(): boolean {
		return state.activeOperation === "teach" || state.activeOperation === "search";
	}

	pi.on("session_start", async (_event: any, ctx: any) => {
		state = emptyState();
		updateWidget(ctx);
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

	pi.registerCommand("teach", {
		description: "Run an explicit Sherpa teach/review request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /teach <request>", "warning");
				return;
			}
			startOperation("teach", ctx);
			pi.sendUserMessage(explicitTeachPrompt(request));
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

	pi.registerCommand("work", {
		description: "Run a broader Sherpa work request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /work <request>", "warning");
				return;
			}
			startOperation("work", ctx);
			pi.sendUserMessage(workPrompt(request));
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
