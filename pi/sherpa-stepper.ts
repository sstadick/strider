import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type WorkflowMode = "idle" | "guided" | "complete";

type WorkflowState = {
	mode: WorkflowMode;
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

function emptyState(): WorkflowState {
	return {
		mode: "idle",
		currentChunk: 1,
		acceptedChunks: 0,
		awaitingNext: false,
		openChunkComplete: false,
		recentFiles: [],
	};
}

function cloneState(state: WorkflowState): WorkflowState {
	return {
		mode: state.mode,
		goal: state.goal,
		currentChunk: state.currentChunk,
		acceptedChunks: state.acceptedChunks,
		awaitingNext: state.awaitingNext,
		lastAcceptedEntryId: state.lastAcceptedEntryId,
		latestAssistantEntryId: state.latestAssistantEntryId,
		latestAssistantSummary: state.latestAssistantSummary,
		openChunkEntryId: state.openChunkEntryId,
		openChunkSummary: state.openChunkSummary,
		openChunkComplete: state.openChunkComplete,
		openChunkFile: state.openChunkFile,
		openChunkNextFocus: state.openChunkNextFocus,
		lastTouchedFile: state.lastTouchedFile,
		recentFiles: [...state.recentFiles],
	};
}

function collapseWhitespace(text?: string): string | undefined {
	if (!text) return undefined;
	const collapsed = text.replace(/\s+/g, " ").trim();
	return collapsed.length > 0 ? collapsed : undefined;
}

function visibleSummary(state: WorkflowState): string | undefined {
	return state.awaitingNext ? state.openChunkSummary : state.latestAssistantSummary;
}

function renderStatus(state: WorkflowState): string[] {
	if (state.mode === "idle") {
		return ["Sherpa: idle", "Use /question <request> to start a linear chunk flow."];
	}

	const lines = [
		`Sherpa goal: ${state.goal ?? "unknown"}`,
		`Accepted checkpoints: ${state.acceptedChunks}`,
	];

	if (state.mode === "complete") {
		lines.push("State: Workflow complete");
	} else {
		lines.push(`Current chunk: ${state.currentChunk}`);
		if (state.awaitingNext) {
			lines.push(state.openChunkComplete ? "State: Final chunk awaiting :SherpaNext" : "State: Awaiting :SherpaNext");
		} else {
			lines.push("State: Working current chunk");
		}
	}

	if (state.openChunkFile) lines.push(`Chunk file: ${state.openChunkFile}`);
	if (state.lastTouchedFile) lines.push(`Last file: ${state.lastTouchedFile}`);
	if (state.awaitingNext && !state.openChunkComplete && state.openChunkNextFocus) {
		lines.push(`Next after accept: ${state.openChunkNextFocus}`);
	}
	const summary = visibleSummary(state);
	if (summary) lines.push(`Summary: ${summary}`);
	return lines;
}

function trackPath(state: WorkflowState, path: string) {
	state.lastTouchedFile = path;
	state.recentFiles = [path, ...state.recentFiles.filter((item) => item !== path)].slice(0, 5);
}

function assistantText(message: any): string | undefined {
	if (!message || message.role !== "assistant") {
		return undefined;
	}

	const parts = (message.content ?? [])
		.filter((item: any) => item.type === "text" && item.text)
		.map((item: any) => item.text);
	return parts.length > 0 ? parts.join("\n") : undefined;
}

function parseFooter(text: string): SherpaFooter {
	const match = text.match(FOOTER_PATTERN);
	if (!match) {
		return { cleanText: text.trim(), workflowComplete: false };
	}

	const cleanText = text.replace(FOOTER_PATTERN, "").trim();
	const workflowComplete = match[1] === "yes";
	const nextFocusRaw = match[2]?.trim();
	return {
		cleanText,
		workflowComplete,
		nextFocus: nextFocusRaw && nextFocusRaw.toLowerCase() !== "none" ? nextFocusRaw : undefined,
	};
}

function smallChunkRules(file?: string): string[] {
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

function footerRules(): string[] {
	return [
		"End every response with this exact footer:",
		"<SHERPA_STATUS>",
		"workflow_complete: yes|no",
		"next_focus: <short next chunk description or none>",
		"</SHERPA_STATUS>",
		"If the current chunk completes the overall workflow, set workflow_complete: yes and next_focus: none.",
		"If more chunks remain, set workflow_complete: no and next_focus to the smallest useful next chunk.",
	];
}

function initialPrompt(request: string): string {
	return [
		`Initial request: ${request}`,
		"You are operating in Sherpa linear chunk mode.",
		"Treat this request as the start of a linear workflow.",
		"Make one bounded chunk of progress.",
		...smallChunkRules(),
		"Stop after the chunk and summarize what changed and what likely comes next.",
		...footerRules(),
	].join("\n");
}

function questionPrompt(state: WorkflowState, question: string): string {
	const context = [
		`Workflow goal: ${state.goal ?? "unknown"}`,
		`Current chunk: ${state.currentChunk}`,
		state.lastTouchedFile ? `Last touched file: ${state.lastTouchedFile}` : undefined,
		visibleSummary(state) ? `Current chunk summary: ${visibleSummary(state)}` : undefined,
	]
		.filter(Boolean)
		.join("\n");

	return [
		context,
		`User input: ${question}`,
		"Stay on the current linear chunk unless the user clearly asks to move on.",
		"If the user is asking for explanation, answer directly and do not edit code.",
		"If the user is asking for a change, make one bounded chunk of progress and stop again.",
		...smallChunkRules(state.openChunkFile),
		...footerRules(),
	].join("\n");
}

function nextPrompt(state: WorkflowState): string {
	return [
		`Workflow goal: ${state.goal ?? "unknown"}`,
		`The previous chunk is accepted. Continue with chunk ${state.currentChunk}.`,
		"Make one bounded chunk of progress.",
		...smallChunkRules(),
		"Stop after the chunk and summarize what changed and what likely comes next.",
		...footerRules(),
	].join("\n");
}

function lastAssistantEntryId(ctx: any): string | undefined {
	const entries = ctx.sessionManager.getEntries();
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type === "message" && entry.message.role === "assistant") {
			return entry.id;
		}
	}
	return undefined;
}

function checkpointLabel(state: WorkflowState): string {
	return `chunk-${state.acceptedChunks + 1}`;
}

export default function (pi: ExtensionAPI) {
	let workflow = emptyState();
	let requestChangedFiles = new Set<string>();

	function persist() {
		pi.appendEntry(STATE_ENTRY, cloneState(workflow));
	}

	function updateWidget(ctx: any) {
		ctx.ui.setWidget("sherpa", renderStatus(workflow));
		const status = workflow.mode === "idle"
			? "idle"
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

	pi.on("session_start", async (_event, ctx) => {
		workflow = emptyState();
		requestChangedFiles = new Set<string>();
		for (const entry of ctx.sessionManager.getEntries()) {
			if (entry.type === "custom" && entry.customType === STATE_ENTRY && entry.data) {
				workflow = entry.data as WorkflowState;
			}
		}
		updateWidget(ctx);
	});

	pi.on("agent_start", async () => {
		requestChangedFiles = new Set<string>();
	});

	pi.on("tool_call", async (event: any, ctx) => {
		const path = event.input?.path;
		if (!path || !["read", "edit", "write"].includes(event.toolName)) {
			return undefined;
		}
		trackPath(workflow, path);
		if (event.toolName === "edit" || event.toolName === "write") {
			if (workflow.openChunkFile && workflow.openChunkFile !== path) {
				ctx.ui.notify(`Blocked multi-file chunk: ${workflow.openChunkFile} -> ${path}`, "warning");
				return {
					block: true,
					reason: `Sherpa allows exactly one mutated file per chunk. The current open chunk is locked to ${workflow.openChunkFile}. Finish that file and stop; defer ${path} to the next chunk after :SherpaNext.`,
				};
			}
			workflow.openChunkFile ??= path;
			requestChangedFiles.add(path);
		}
		persist();
		updateWidget(ctx);
		return undefined;
	});

	pi.on("message_end", async (event: any, ctx) => {
		const text = assistantText(event.message);
		if (!text) {
			return;
		}
		const footer = parseFooter(text);
		workflow.latestAssistantSummary = collapseWhitespace(footer.cleanText);
		workflow.latestAssistantEntryId = lastAssistantEntryId(ctx);
		if (requestChangedFiles.size > 0 && workflow.latestAssistantEntryId) {
			workflow.awaitingNext = true;
			workflow.openChunkEntryId = workflow.latestAssistantEntryId;
			workflow.openChunkSummary = collapseWhitespace(footer.cleanText);
			workflow.openChunkComplete = footer.workflowComplete;
			workflow.openChunkNextFocus = footer.nextFocus;
		}
		persist();
		updateWidget(ctx);
	});

	pi.registerCommand("question", {
		description: "Start or continue a linear Sherpa chunk flow",
		handler: async (args, ctx) => {
			const question = args?.trim();
			if (!question) {
				ctx.ui.notify("Usage: /question <request>", "warning");
				return;
			}

			if (workflow.mode === "idle" || workflow.mode === "complete") {
				beginWorkflow(question);
				persist();
				updateWidget(ctx);
				pi.sendUserMessage(initialPrompt(question));
				return;
			}

			persist();
			updateWidget(ctx);
			pi.sendUserMessage(questionPrompt(workflow, question));
		},
	});

	pi.registerCommand("next", {
		description: "Accept the current chunk and continue linearly",
		handler: async (_args, ctx) => {
			if (workflow.mode === "idle") {
				ctx.ui.notify("No active Sherpa workflow", "warning");
				return;
			}
			if (workflow.mode === "complete") {
				ctx.ui.notify("Workflow is already complete. Use /question to start a new flow.", "warning");
				return;
			}
			if (!workflow.awaitingNext || !workflow.openChunkEntryId) {
				ctx.ui.notify("No open chunk is waiting for :SherpaNext", "warning");
				return;
			}
			if (workflow.lastAcceptedEntryId === workflow.openChunkEntryId) {
				ctx.ui.notify("Current chunk is already accepted", "warning");
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
}
