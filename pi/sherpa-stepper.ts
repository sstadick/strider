import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type StepStatus = "todo" | "active" | "done" | "blocked";

type WorkflowStep = {
	id: number;
	title: string;
	status: StepStatus;
	file?: string;
};

type WorkflowState = {
	mode: "idle" | "guided";
	goal?: string;
	currentStepId?: number;
	lastTouchedFile?: string;
	recentFiles: string[];
	lastAssistantSummary?: string;
	steps: WorkflowStep[];
};

const STATE_ENTRY = "sherpa-workflow-state";

function emptyState(): WorkflowState {
	return {
		mode: "idle",
		recentFiles: [],
		steps: [],
	};
}

function cloneState(state: WorkflowState): WorkflowState {
	return {
		mode: state.mode,
		goal: state.goal,
		currentStepId: state.currentStepId,
		lastTouchedFile: state.lastTouchedFile,
		recentFiles: [...state.recentFiles],
		lastAssistantSummary: state.lastAssistantSummary,
		steps: state.steps.map((step) => ({ ...step })),
	};
}

function currentStep(state: WorkflowState): WorkflowStep | undefined {
	return state.steps.find((step) => step.id === state.currentStepId);
}

function nextStepId(state: WorkflowState): number {
	return state.steps.reduce((max, step) => Math.max(max, step.id), 0) + 1;
}

function renderStatus(state: WorkflowState): string[] {
	if (state.mode === "idle") {
		return ["Sherpa: idle"];
	}

	const active = currentStep(state);
	const lines = [
		`Sherpa goal: ${state.goal ?? "unknown"}`,
		`Current step: ${active?.title ?? "none"}`,
		`Remaining: ${state.steps.filter((step) => step.status !== "done").length}`,
	];
	if (state.lastTouchedFile) lines.push(`File: ${state.lastTouchedFile}`);
	return lines;
}

function trackPath(state: WorkflowState, path: string) {
	state.lastTouchedFile = path;
	state.recentFiles = [path, ...state.recentFiles.filter((item) => item !== path)].slice(0, 5);
	const active = currentStep(state);
	if (active) active.file = path;
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

function guidePrompt(goal: string): string {
	return [
		`Goal: ${goal}`,
		"You are operating in guided chunk mode.",
		"Create a short plan in your own reasoning, but execute only the first bounded chunk.",
		"Prefer one file when possible.",
		"After the chunk, stop and summarize what changed and what should come next.",
	].join("\n");
}

function nextPrompt(state: WorkflowState): string {
	const active = currentStep(state);
	return [
		`Goal: ${state.goal ?? "unknown"}`,
		`Continue with ${active?.title ?? "the next chunk"}.`,
		"Make one bounded chunk of progress.",
		"Stop again when the chunk is complete and summarize the result.",
	].join("\n");
}

function revisePrompt(state: WorkflowState, feedback: string): string {
	return [
		`Goal: ${state.goal ?? "unknown"}`,
		`Current step: ${currentStep(state)?.title ?? "current chunk"}`,
		`Feedback: ${feedback}`,
		"Revise only the current chunk.",
		"Stop after the revision and summarize the change.",
	].join("\n");
}

function questionPrompt(state: WorkflowState, question: string): string {
	const context = [
		`Goal: ${state.goal ?? "unknown"}`,
		`Current step: ${currentStep(state)?.title ?? "current chunk"}`,
		state.lastTouchedFile ? `Last touched file: ${state.lastTouchedFile}` : undefined,
		state.lastAssistantSummary ? `Last summary: ${state.lastAssistantSummary}` : undefined,
	]
		.filter(Boolean)
		.join("\n");
	return [context, `Question: ${question}`, "Answer the question about the current chunk.", "Do not edit code unless the user explicitly asks for it."].join("\n");
}

export default function (pi: ExtensionAPI) {
	let workflow = emptyState();

	function persist() {
		pi.appendEntry(STATE_ENTRY, cloneState(workflow));
	}

	function updateWidget(ctx: any) {
		ctx.ui.setWidget("sherpa", renderStatus(workflow));
		ctx.ui.setStatus("sherpa", workflow.mode === "idle" ? "idle" : `step ${workflow.currentStepId}`);
	}

	pi.on("session_start", async (_event, ctx) => {
		workflow = emptyState();
		for (const entry of ctx.sessionManager.getEntries()) {
			if (entry.type === "custom" && entry.customType === STATE_ENTRY && entry.data) {
				workflow = entry.data as WorkflowState;
			}
		}
		updateWidget(ctx);
	});

	pi.on("tool_call", async (event: any, ctx) => {
		const path = event.input?.path;
		if (!path || !["read", "edit", "write"].includes(event.toolName)) {
			return undefined;
		}
		trackPath(workflow, path);
		persist();
		updateWidget(ctx);
		return undefined;
	});

	pi.on("message_end", async (event: any, ctx) => {
		const text = assistantText(event.message);
		if (!text) {
			return;
		}
		workflow.lastAssistantSummary = text.replace(/\s+/g, " ").trim();
		persist();
		updateWidget(ctx);
	});

	pi.registerCommand("guide", {
		description: "Start a guided chunked coding task",
		handler: async (args, ctx) => {
			const goal = args?.trim();
			if (!goal) {
				ctx.ui.notify("Usage: /guide <goal>", "warning");
				return;
			}

			workflow = {
				mode: "guided",
				goal,
				currentStepId: 1,
				lastAssistantSummary: undefined,
				lastTouchedFile: undefined,
				recentFiles: [],
				steps: [{ id: 1, title: "Chunk 1", status: "active" }],
			};
			persist();
			updateWidget(ctx);
			pi.sendUserMessage(guidePrompt(goal));
		},
	});

	pi.registerCommand("question", {
		description: "Ask a question about the current chunk without advancing",
		handler: async (args, ctx) => {
			if (workflow.mode !== "guided") {
				ctx.ui.notify("No active Sherpa workflow", "warning");
				return;
			}

			const question = args?.trim();
			if (!question) {
				ctx.ui.notify("Usage: /question <question>", "warning");
				return;
			}

			updateWidget(ctx);
			pi.sendUserMessage(questionPrompt(workflow, question));
		},
	});

	pi.registerCommand("next", {
		description: "Advance to the next chunk",
		handler: async (_args, ctx) => {
			if (workflow.mode !== "guided") {
				ctx.ui.notify("No active Sherpa workflow", "warning");
				return;
			}

			const active = currentStep(workflow);
			if (active) active.status = "done";
			const id = nextStepId(workflow);
			workflow.currentStepId = id;
			workflow.steps.push({ id, title: `Chunk ${id}`, status: "active" });
			persist();
			updateWidget(ctx);
			pi.sendUserMessage(nextPrompt(workflow));
		},
	});

	pi.registerCommand("revise", {
		description: "Revise the current chunk with user feedback",
		handler: async (args, ctx) => {
			if (workflow.mode !== "guided") {
				ctx.ui.notify("No active Sherpa workflow", "warning");
				return;
			}

			const feedback = args?.trim();
			if (!feedback) {
				ctx.ui.notify("Usage: /revise <feedback>", "warning");
				return;
			}

			persist();
			updateWidget(ctx);
			pi.sendUserMessage(revisePrompt(workflow, feedback));
		},
	});

	pi.registerCommand("status", {
		description: "Show Sherpa workflow status",
		handler: async (_args, ctx) => {
			updateWidget(ctx);
			ctx.ui.notify(renderStatus(workflow).join(" | "), "info");
		},
	});
}
