import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { browseSessions, resumeSession, sessionIdentity } from "./session-switching.js";
import { registerStriderTools } from "./strider-tools.js";
import {
	explicitReviewPrompt,
	patchPrompt,
	planPrompt,
	promptPrompt,
	searchPrompt,
} from "./strider-prompts.js";

type OperationKind = "search" | "review" | "patch" | "prompt" | "plan";

type StriderState = {
	activeOperation?: OperationKind;
	// Budget: at most one strider_clarify call per user request. Reset in
	// startOperation so the next /prompt or /patch starts fresh.
	clarifyCount: number;
	// Accumulated cost ($) across assistant turns in this session. Pi
	// reports per-turn cost on `message.usage.cost.total`; we sum it so
	// the log widget shows running total. Reset on session_start.
	sessionCost: number;
};

function emptyState(): StriderState {
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
		const session = sessionIdentity(ctx);
		if (session) lines.push(`Session: ${session}`);
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
		ctx.ui.setWidget("strider", renderStatus(ctx));
		ctx.ui.setStatus("strider", state.activeOperation ? `${state.activeOperation} active` : "idle");
	}

	// Strider-owned tools whose validity is operation-scoped. These are
	// always registered (pi's registerTool is load-time only), but we
	// toggle which ones are *active* per turn via pi.setActiveTools so
	// the model only sees them when they'd actually do something.
	//
	// Without this gating, the model tends to call strider_plan during
	// prose turns because the tool name is suggestive — the call
	// quietly no-ops on our side but wastes tokens and looks weird in
	// the transcript.
	const STRIDER_OP_SCOPED_TOOLS = new Set(["strider_plan", "strider_append_stops"]);

	function toolsForOperation(allNames: string[], kind?: OperationKind): string[] {
		const keep = (name: string): boolean => {
			if (!STRIDER_OP_SCOPED_TOOLS.has(name)) return true;   // non-scoped tools always active
			if (name === "strider_plan") return kind === "plan";
			// strider_append_stops is only meaningful during plan (appending
			// to the plan being built) or during a /review turn on a free-
			// scope review. We enable it for both — the Lua side silently
			// rejects appends on non-free scopes so the overreach is safe.
			if (name === "strider_append_stops") return kind === "plan" || kind === "review";
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

	function agentIsIdle(ctx: any): boolean {
		if (state.activeOperation) return false;
		return typeof ctx.isIdle !== "function" || ctx.isIdle();
	}

	function sendOperationMessage(kind: OperationKind, ctx: any, message: string) {
		if (!agentIsIdle(ctx)) {
			const active = state.activeOperation ? ` (${state.activeOperation})` : "";
			ctx.ui.notify(`Strider is already running${active}; wait for it to finish.`, "warning");
			return;
		}
		startOperation(kind, ctx);
		pi.sendUserMessage(message);
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
		// Start with Strider's op-scoped tools hidden. They'll be turned
		// on by startOperation when a command that needs them runs.
		applyOperationTools(ctx, undefined);
		updateWidget(ctx);
		if (event.reason === "new" || event.reason === "fork" || event.reason === "resume") {
			ctx.ui.setStatus("strider-session", event.reason);
		}
	});

	pi.on("tool_call", async (event: any, ctx: any) => {
		if (readOnlyOperation()) {
			if (event.toolName === "edit" || event.toolName === "write") {
				ctx.ui.notify(`Blocked write tool in ${state.activeOperation} mode: ${event.toolName}`, "warning");
				return { block: true, reason: `Strider ${state.activeOperation} mode is read-only. Do not edit or write files.` };
			}
			if (event.toolName === "bash" && !isSafeReadOnlyBash(event.input?.command)) {
				ctx.ui.notify(`Blocked unsafe bash command in ${state.activeOperation} mode`, "warning");
				return {
					block: true,
					reason: `Strider ${state.activeOperation} mode only allows safe read-only inspection commands. Use read, rg, grep, find, ls, tree, or git read-only inspection.`,
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

	registerStriderTools(pi, () => state);

	pi.registerCommand("plan", {
		description: "Produce a Strider review plan",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /plan <request>", "warning");
				return;
			}
			sendOperationMessage("plan", ctx, planPrompt(request));
		},
	});

	pi.registerCommand("review", {
		description: "Run an explicit Strider review request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /review <request>", "warning");
				return;
			}
			sendOperationMessage("review", ctx, explicitReviewPrompt(request));
		},
	});

	pi.registerCommand("search", {
		description: "Run a Strider structured code search",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /search <request>", "warning");
				return;
			}
			sendOperationMessage("search", ctx, searchPrompt(request));
		},
	});

	pi.registerCommand("prompt", {
		description: "Run a Strider prompt — plain agent turn with clarify available",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /prompt <request>", "warning");
				return;
			}
			sendOperationMessage("prompt", ctx, promptPrompt(request));
		},
	});

	pi.registerCommand("patch", {
		description: "Run a Strider local patch request",
		handler: async (args: any, ctx: any) => {
			const request = args?.trim();
			if (!request) {
				ctx.ui.notify("Usage: /patch <request>", "warning");
				return;
			}
			sendOperationMessage("patch", ctx, patchPrompt(request));
		},
	});

	pi.registerCommand("sessions", {
		description: "Browse saved sessions for this project",
		handler: async (_args: any, ctx: any) => {
			await browseSessions(ctx);
		},
	});

	pi.registerCommand("resume", {
		description: "Resume a saved session by id prefix or path",
		handler: async (args: any, ctx: any) => {
			const input = args?.trim();
			if (!input) {
				await browseSessions(ctx);
				return;
			}
			await resumeSession(input, ctx);
		},
	});

	pi.registerCommand("switch_session", {
		description: "Resume a saved session by id prefix or path",
		handler: async (args: any, ctx: any) => {
			const input = args?.trim();
			if (!input) {
				ctx.ui.notify("Usage: /switch_session <path-or-id>", "warning");
				return;
			}
			await resumeSession(input, ctx);
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
