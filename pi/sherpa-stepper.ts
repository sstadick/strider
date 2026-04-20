import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type WorkflowMode = "idle" | "guided" | "complete";
type WorkflowKind = "code" | "teach";
type OperationKind = "search" | "teach" | "patch" | "work";

type WorkflowState = {
	mode: WorkflowMode;
	kind: WorkflowKind;
	goal?: string;
	currentChunk: number;
	acceptedChunks: number;
	awaitingNext: boolean;
	lastAcceptedEntryId?: string;
	latestAssistantEntryId?: string;
	latestAssistantSummary?: string;
	openChunkEntryId?: string;
	openChunkSummary?: string;
	openChunkComplete: boolean;
	openChunkFile?: string;
	openChunkNextFocus?: string;
	lastTouchedFile?: string;
	recentFiles: string[];
};

type SherpaFooter = {
	cleanText: string;
	workflowComplete: boolean;
	nextFocus?: string;
};

const STATE_ENTRY = "sherpa-workflow-state";
const FOOTER_PATTERN = /\n?<SHERPA_STATUS>\s*workflow_complete:\s*(yes|no)\s*next_focus:\s*(.+?)\s*<\/SHERPA_STATUS>\s*$/s;
const TEACH_PATTERNS = [
	/\bwalk me through\b/i,
	/\bwalk through this codebase\b/i,
	/\bteach me\b/i,
	/\bshow me around\b/i,
	/\bguide me through\b/i,
	/\bcode tour\b/i,
	/\btour guide\b/i,
	/^teach:/i,
];

function emptyState(): WorkflowState {
	return {
		mode: "idle",
		kind: "code",
		currentChunk: 1,
		acceptedChunks: 0,
		awaitingNext: false,
		openChunkComplete: false,
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

function parseFooter(text: string): SherpaFooter {
	const match = text.match(FOOTER_PATTERN);
	if (!match) return { cleanText: text.trim(), workflowComplete: false };
	const cleanText = text.replace(FOOTER_PATTERN, "").trim();
	const nextFocusRaw = match[2]?.trim();
	return {
		cleanText,
		workflowComplete: match[1] === "yes",
		nextFocus: nextFocusRaw && nextFocusRaw.toLowerCase() !== "none" ? nextFocusRaw : undefined,
	};
}

function detectWorkflowKind(request: string): WorkflowKind {
	return TEACH_PATTERNS.some((pattern) => pattern.test(request)) ? "teach" : "code";
}

function visibleSummary(state: WorkflowState): string | undefined {
	return state.awaitingNext ? state.openChunkSummary : state.latestAssistantSummary;
}

function unitLabel(state: WorkflowState): string {
	return state.kind === "teach" ? "stop" : "chunk";
}

function footerRules(): string[] {
	return [
		"End every response with this exact footer:",
		"<SHERPA_STATUS>",
		"workflow_complete: yes|no",
		"next_focus: <short next chunk description or none>",
		"</SHERPA_STATUS>",
		"If the current stop or chunk completes the overall workflow, set workflow_complete: yes and next_focus: none.",
		"If more work remains, set workflow_complete: no and next_focus to the smallest useful next stop or chunk.",
	];
}

function codeChunkRules(file?: string): string[] {
	return [
		"A chunk may mutate exactly one file.",
		file
			? `This open chunk is locked to: ${file}. Do not mutate any other file until the user accepts the chunk with :SherpaNext.`
			: "If another file also needs changes, stop after finishing the first file and mention it as the next chunk.",
		"Prefer the smallest reviewable chunk possible.",
		"If a file has several independent functions, blocks, or sections, change only one function or one small nearby cluster per chunk.",
		"Do not update an entire file when the work can be split across smaller reviewable chunks.",
	];
}

function teachStopRules(file?: string): string[] {
	return [
		"You are operating in Sherpa teach mode.",
		"A stop may inspect exactly one file.",
		file
			? `This open stop is locked to: ${file}. Stay in this file until the user accepts the stop with :SherpaNext.`
			: "Pick one file for the stop. If another file is relevant, mention it as the next stop instead of switching immediately.",
		"This mode is read-only. Do not use edit or write.",
		"Prefer read with offset and limit so the section stays small.",
		"Keep each stop to one small nearby section, usually around one function or one small block.",
		"Explain what the user is looking at, why it matters, and what the next logical stop should be.",
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

function explicitTeachRules(): string[] {
	return [
		"You are operating in explicit Sherpa teach/review mode.",
		"This mode is read-only. Do not use edit or write.",
		"Answer clearly and directly.",
		"If more context is needed, inspect only nearby code or the smallest relevant surface.",
		"Focus on the review item or question provided by the user.",
	];
}

function workRules(): string[] {
	return [
		"You are operating in Sherpa work mode.",
		"You may make broader changes than linear chunk mode.",
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

function initialPrompt(kind: WorkflowKind, request: string): string {
	if (kind === "teach") {
		return [
			`Initial request: ${request}`,
			"Treat this request as the start of a linear code tour.",
			"Choose the most logical first stop for understanding the codebase.",
			...teachStopRules(),
			...footerRules(),
		].join("\n");
	}
	return [
		`Initial request: ${request}`,
		"You are operating in Sherpa linear chunk mode.",
		"Treat this request as the start of a linear workflow.",
		"Make one bounded chunk of progress.",
		...codeChunkRules(),
		"Stop after the chunk and summarize what changed and what likely comes next.",
		...footerRules(),
	].join("\n");
}

function questionPrompt(state: WorkflowState, question: string): string {
	const unit = unitLabel(state);
	const context = [
		`Workflow goal: ${state.goal ?? "unknown"}`,
		`Current ${unit}: ${state.currentChunk}`,
		state.lastTouchedFile ? `Last touched file: ${state.lastTouchedFile}` : undefined,
		visibleSummary(state) ? `Current ${unit} summary: ${visibleSummary(state)}` : undefined,
	]
		.filter(Boolean)
		.join("\n");

	if (state.kind === "teach") {
		return [
			context,
			`User input: ${question}`,
			"Stay on the current stop unless the user clearly asks to move on.",
			"Answer explanatory questions directly.",
			"If more code inspection is needed, inspect one small section and stop again.",
			...teachStopRules(state.openChunkFile),
			...footerRules(),
		].join("\n");
	}

	return [
		context,
		`User input: ${question}`,
		"Stay on the current linear chunk unless the user clearly asks to move on.",
		"If the user is asking for explanation, answer directly and do not edit code.",
		"If the user is asking for a change, make one bounded chunk of progress and stop again.",
		...codeChunkRules(state.openChunkFile),
		...footerRules(),
	].join("\n");
}

function nextPrompt(state: WorkflowState): string {
	const unit = unitLabel(state);
	if (state.kind === "teach") {
		return [
			`Workflow goal: ${state.goal ?? "unknown"}`,
			`The previous stop is accepted. Continue with stop ${state.currentChunk}.`,
			"Choose the most logical next stop for understanding the codebase.",
			...teachStopRules(),
			...footerRules(),
		].join("\n");
	}
	return [
		`Workflow goal: ${state.goal ?? "unknown"}`,
		`The previous ${unit} is accepted. Continue with ${unit} ${state.currentChunk}.`,
		"Make one bounded chunk of progress.",
		...codeChunkRules(),
		"Stop after the chunk and summarize what changed and what likely comes next.",
		...footerRules(),
	].join("\n");
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

function lastAssistantEntryId(ctx: any): string | undefined {
	const entries = ctx.sessionManager.getEntries();
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type === "message" && entry.message.role === "assistant") return entry.id;
	}
	return undefined;
}

function checkpointLabel(state: WorkflowState): string {
	return `${state.kind === "teach" ? "stop" : "chunk"}-${state.acceptedChunks + 1}`;
}

function isSafeTeachBash(command?: string): boolean {
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
		"git log",
		"git grep",
		"head",
		"tail",
	];
	return allowed.some((item) => trimmed === item || trimmed.startsWith(`${item} `));
}

export default function (pi: ExtensionAPI) {
	let workflow = emptyState();
	let activeOperation: OperationKind | undefined;
	let requestMutatedFile = false;
	let requestReadStop = false;

	function persist() {
		pi.appendEntry(STATE_ENTRY, { ...workflow, recentFiles: [...workflow.recentFiles] });
	}

	function trackPath(path: string) {
		workflow.lastTouchedFile = path;
		workflow.recentFiles = [path, ...workflow.recentFiles.filter((item) => item !== path)].slice(0, 5);
	}

	function currentUiKind(): string | undefined {
		if (activeOperation === "teach") return "teach";
		if (workflow.mode !== "idle") return workflow.kind;
		return undefined;
	}

	function renderStatus(): string[] {
		if (workflow.mode === "idle") {
			if (!activeOperation) return ["Sherpa: idle", "Use /question, /work, /search, or /teach to start."];
			return [`Sherpa operation: ${activeOperation}`, "Waiting for assistant response..."];
		}

		const unit = unitLabel(workflow);
		const lines = [
			`Sherpa mode: ${workflow.kind}`,
			`Sherpa goal: ${workflow.goal ?? "unknown"}`,
			`Accepted checkpoints: ${workflow.acceptedChunks}`,
		];
		if (workflow.mode === "complete") {
			lines.push("State: Workflow complete");
		} else {
			lines.push(`Current ${unit}: ${workflow.currentChunk}`);
			lines.push(
				workflow.awaitingNext
					? workflow.openChunkComplete
						? `State: Final ${unit} awaiting :SherpaNext`
						: "State: Awaiting :SherpaNext"
					: `State: Working current ${unit}`,
			);
		}
		if (workflow.openChunkFile) lines.push(`${workflow.kind === "teach" ? "Stop" : "Chunk"} file: ${workflow.openChunkFile}`);
		if (workflow.lastTouchedFile) lines.push(`Last file: ${workflow.lastTouchedFile}`);
		if (workflow.awaitingNext && !workflow.openChunkComplete && workflow.openChunkNextFocus) {
			lines.push(`Next after accept: ${workflow.openChunkNextFocus}`);
		}
		const summary = visibleSummary(workflow);
		if (summary) lines.push(`Summary: ${summary}`);
		return lines;
	}

	function updateWidget(ctx: any) {
		ctx.ui.setWidget("sherpa", renderStatus());
		ctx.ui.setStatus("sherpa-kind", currentUiKind());
		ctx.ui.setStatus("sherpa-operation", activeOperation);
		const status = workflow.mode === "idle"
			? activeOperation
				? `${activeOperation} active`
				: "idle"
			: workflow.mode === "complete"
				? "complete"
				: workflow.awaitingNext
					? workflow.openChunkComplete
						? `chunk ${workflow.currentChunk} final-awaiting-next`
						: `chunk ${workflow.currentChunk} awaiting-next`
					: `chunk ${workflow.currentChunk} active`;
		ctx.ui.setStatus("sherpa", status);
	}

	function beginWorkflow(goal: string) {
		workflow = {
			mode: "guided",
			kind: detectWorkflowKind(goal),
			goal,
			currentChunk: 1,
			acceptedChunks: 0,
			awaitingNext: false,
			lastAcceptedEntryId: undefined,
			latestAssistantEntryId: undefined,
			latestAssistantSummary: undefined,
			openChunkEntryId: undefined,
			openChunkSummary: undefined,
			openChunkComplete: false,
			openChunkFile: undefined,
			openChunkNextFocus: undefined,
			lastTouchedFile: undefined,
			recentFiles: [],
		};
	}

	function startOperation(kind: OperationKind, ctx: any) {
		activeOperation = kind;
		updateWidget(ctx);
	}

	function clearOperation(ctx: any) {
		activeOperation = undefined;
		updateWidget(ctx);
	}

	function readOnlyOperation(): boolean {
		return activeOperation === "teach" || activeOperation === "search";
	}

	pi.on("session_start", async (_event: any, ctx: any) => {
		workflow = emptyState();
		activeOperation = undefined;
		requestMutatedFile = false;
		requestReadStop = false;
		for (const entry of ctx.sessionManager.getEntries()) {
			if (entry.type === "custom" && entry.customType === STATE_ENTRY && entry.data) {
				workflow = entry.data as WorkflowState;
			}
		}
		updateWidget(ctx);
	});

	pi.on("agent_start", async () => {
		requestMutatedFile = false;
		requestReadStop = false;
	});

	pi.on("tool_call", async (event: any, ctx: any) => {
		const path = event.input?.path;
		if (path && ["read", "edit", "write"].includes(event.toolName)) trackPath(path);

		if (readOnlyOperation()) {
			if (event.toolName === "edit" || event.toolName === "write") {
				ctx.ui.notify(`Blocked write tool in ${activeOperation} mode: ${event.toolName}`, "warning");
				return { block: true, reason: `Sherpa ${activeOperation} mode is read-only. Do not edit or write files.` };
			}
			if (event.toolName === "bash" && !isSafeTeachBash(event.input?.command)) {
				ctx.ui.notify(`Blocked unsafe bash command in ${activeOperation} mode`, "warning");
				return {
					block: true,
					reason: `Sherpa ${activeOperation} mode only allows safe read-only inspection commands. Use read, rg, grep, find, ls, tree, or git read-only inspection.`,
				};
			}
		}

		if (workflow.mode === "guided" && workflow.kind === "teach") {
			if (event.toolName === "edit" || event.toolName === "write") {
				ctx.ui.notify(`Blocked write tool in teach mode: ${event.toolName}`, "warning");
				return { block: true, reason: "Sherpa teach mode is read-only. Do not edit or write files during a tour stop." };
			}
			if (event.toolName === "bash" && !isSafeTeachBash(event.input?.command)) {
				ctx.ui.notify("Blocked unsafe bash command in teach mode", "warning");
				return {
					block: true,
					reason: "Sherpa teach mode only allows safe read-only inspection commands. Use read, rg, grep, find, ls, tree, or git read-only inspection.",
				};
			}
			if (event.toolName === "read" && path) {
				if (workflow.openChunkFile && workflow.openChunkFile !== path) {
					ctx.ui.notify(`Blocked multi-file stop: ${workflow.openChunkFile} -> ${path}`, "warning");
					return {
						block: true,
						reason: `Sherpa teach mode allows exactly one file per stop. The current stop is locked to ${workflow.openChunkFile}. Finish this stop and defer ${path} to the next stop after :SherpaNext.`,
					};
				}
				workflow.openChunkFile ??= path;
				requestReadStop = true;
			}
			persist();
			updateWidget(ctx);
			return undefined;
		}

		if (workflow.mode === "guided" && workflow.kind === "code" && path && (event.toolName === "edit" || event.toolName === "write")) {
			if (workflow.openChunkFile && workflow.openChunkFile !== path) {
				ctx.ui.notify(`Blocked multi-file chunk: ${workflow.openChunkFile} -> ${path}`, "warning");
				return {
					block: true,
					reason: `Sherpa allows exactly one mutated file per chunk. The current open chunk is locked to ${workflow.openChunkFile}. Finish that file and stop; defer ${path} to the next chunk after :SherpaNext.`,
				};
			}
			workflow.openChunkFile ??= path;
			requestMutatedFile = true;
		}

		persist();
		updateWidget(ctx);
		return undefined;
	});

	pi.on("message_end", async (event: any, ctx: any) => {
		const text = assistantText(event.message);
		if (!text) return;
		const footer = parseFooter(text);

		if (workflow.mode !== "idle" && !activeOperation) {
			workflow.latestAssistantSummary = collapseWhitespace(footer.cleanText);
			workflow.latestAssistantEntryId = lastAssistantEntryId(ctx);
			const openedUnit = workflow.kind === "teach" ? requestReadStop : requestMutatedFile;
			if (openedUnit && workflow.latestAssistantEntryId) {
				workflow.awaitingNext = true;
				workflow.openChunkEntryId = workflow.latestAssistantEntryId;
				workflow.openChunkSummary = collapseWhitespace(footer.cleanText);
				workflow.openChunkComplete = footer.workflowComplete;
				workflow.openChunkNextFocus = footer.nextFocus;
			}
			persist();
		}

		if (activeOperation) clearOperation(ctx);
		else updateWidget(ctx);
	});

	pi.registerCommand("question", {
		description: "Start or continue a linear Sherpa flow",
		handler: async (args: any, ctx: any) => {
			const question = args?.trim();
			if (!question) {
				ctx.ui.notify("Usage: /question <request>", "warning");
				return;
			}
			activeOperation = undefined;
			if (workflow.mode === "idle" || workflow.mode === "complete") {
				beginWorkflow(question);
				persist();
				updateWidget(ctx);
				pi.sendUserMessage(initialPrompt(workflow.kind, question));
				return;
			}
			persist();
			updateWidget(ctx);
			pi.sendUserMessage(questionPrompt(workflow, question));
		},
	});

	pi.registerCommand("next", {
		description: "Accept the current Sherpa stop or chunk and continue linearly",
		handler: async (_args: any, ctx: any) => {
			activeOperation = undefined;
			if (workflow.mode === "idle") {
				ctx.ui.notify("No active Sherpa workflow", "warning");
				return;
			}
			if (workflow.mode === "complete") {
				ctx.ui.notify("Workflow is already complete. Use /question to start a new flow.", "warning");
				return;
			}
			if (!workflow.awaitingNext || !workflow.openChunkEntryId) {
				ctx.ui.notify("No open stop or chunk is waiting for :SherpaNext", "warning");
				return;
			}
			if (workflow.lastAcceptedEntryId === workflow.openChunkEntryId) {
				ctx.ui.notify("Current stop or chunk is already accepted", "warning");
				return;
			}

			pi.setLabel(workflow.openChunkEntryId, checkpointLabel(workflow));
			workflow.lastAcceptedEntryId = workflow.openChunkEntryId;
			workflow.acceptedChunks += 1;
			const finishedWorkflow = workflow.openChunkComplete;
			workflow.awaitingNext = false;
			workflow.openChunkEntryId = undefined;
			workflow.openChunkSummary = undefined;
			workflow.openChunkComplete = false;
			workflow.openChunkFile = undefined;
			workflow.openChunkNextFocus = undefined;

			if (finishedWorkflow) {
				workflow.mode = "complete";
				persist();
				updateWidget(ctx);
				ctx.ui.notify("Sherpa workflow complete", "info");
				return;
			}

			workflow.currentChunk += 1;
			persist();
			updateWidget(ctx);
			pi.sendUserMessage(nextPrompt(workflow));
		},
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
