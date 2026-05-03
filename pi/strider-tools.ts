import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

function collapseWhitespace(text?: string): string | undefined {
	if (!text) return undefined;
	const collapsed = text.replace(/\s+/g, " ").trim();
	return collapsed.length > 0 ? collapsed : undefined;
}

export function registerStriderTools(pi: ExtensionAPI, getState: () => { clarifyCount: number }) {
	const state = new Proxy({}, {
		get(_target, prop) {
			return (getState() as any)[prop as any];
		},
		set(_target, prop, value) {
			(getState() as any)[prop as any] = value;
			return true;
		},
	}) as any;

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
		name: "strider_plan",
		label: "Strider plan",
		description: "Submit the review plan for a Strider review. Must be called exactly once during plan mode.",
		parameters: planSchema,
		promptSnippet: "strider_plan: submit the review plan during Strider plan mode.",
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, _ctx: any) {
			if (params.scope === "diff" && !params.base) {
				throw new Error("strider_plan: base is required when scope='diff'");
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
		name: "strider_append_stops",
		label: "Strider append stops",
		description: "Append new stops to an active free-scope Strider review. Only valid mid-review on free-scope plans.",
		parameters: appendStopsSchema,
		promptSnippet: "strider_append_stops: append stops to a free-scope Strider review in progress.",
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
		name: "strider_clarify",
		label: "Strider clarify",
		description:
			"Pause the current turn and ask the user for clarification, approval of a proposed plan, or confirmation of a destructive action. Available during /prompt and /patch. Use sparingly — prefer action over questions. Only clarify when a specific ambiguity would change your approach non-trivially. If the user cancels, stop work and explain what you were asking — do NOT proceed with a guess.",
		parameters: clarifySchema,
		promptSnippet:
			"strider_clarify: pause and ask the user (question / plan_proposal / confirm) when truly ambiguous.",
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
			const text = (s: string) => ({
				content: [{ type: "text", text: s }],
				details: { kind: params.kind },
			}) as any;

			if (state.clarifyCount >= 1) {
				throw new Error(
					"strider_clarify: budget exhausted for this request. Proceed with your best interpretation and summarize the ambiguity in your final reply.",
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
				title = `[strider-plan-proposal] ${params.title}`;
				prefill = params.body;
			}
			const answer = await ctx.ui.editor(title, prefill);
			if (answer === undefined) {
				return text("[user cancelled clarification]");
			}
			return text(answer);
		},
	});

	const vimExecSchema = Type.Object({
		intent: Type.String({
			description: "Short human-readable summary of why this Neovim Lua is being executed. Used for compact Strider logs.",
		}),
		lua: Type.String({
			description:
				"Lua chunk to execute inside the user's live Neovim. May use vim.*, vim.api, vim.fn, vim.cmd, require(), plugin APIs, key feeding, etc. Return a compact value when inspection results are useful.",
		}),
	});

	pi.registerTool({
		name: "strider_vim",
		label: "Strider Vim",
		description: "Execute arbitrary Lua inside the user's live Neovim. No allowlist or confirmation layer.",
		parameters: vimExecSchema,
		promptSnippet:
			"strider_vim: execute arbitrary Lua inside the user's live Neovim; provide intent + lua and return compact results.",
		promptGuidelines: [
			"Use strider_vim when live Neovim state, local plugins, buffers, windows, keymaps, LSP, diagnostics, help, or editor actions would help.",
			"Routine inspection should stay quiet: summarize it in intent and return compact JSON-serializable Lua values.",
			"You may freely use vim.api, vim.fn, vim.cmd, vim.lsp, vim.diagnostic, plugin APIs, and key feeding; there is no command allowlist.",
		],
		async execute(_toolCallId: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
			const lua = typeof params.lua === "string" ? params.lua : "";
			if (lua.trim() === "") {
				throw new Error("strider_vim: lua is required");
			}
			const intent = collapseWhitespace(params.intent)?.slice(0, 200) ?? "run Lua in Neovim";
			const result = await ctx.ui.editor(`[strider-vim-exec] ${intent}`, lua);
			if (result === undefined) {
				throw new Error("strider_vim: Neovim client did not return a result");
			}
			return {
				content: [{ type: "text", text: result }],
				details: { intent },
			} as any;
		},
	});

}
