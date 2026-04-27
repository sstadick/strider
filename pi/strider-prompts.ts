const EXPLICIT_REVIEW_RULES = [
	"You are operating in explicit Strider review mode.",
	"This mode is read-only. Do not use edit or write.",
	"Answer clearly and directly.",
	"If more context is needed, inspect only nearby code or the smallest relevant surface.",
	"Focus on the review item or question provided by the user.",
	"Follow the most sensible order for understanding the user's question, not discovery order.",
	"Unless the user explicitly asks for a file-by-file audit, focus on the most relevant code.",
];

const SEARCH_RULES = [
	"You are operating in Strider search mode.",
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

const PATCH_RULES = [
	"You are operating in Strider patch mode.",
	"Treat the provided file and range as a strong edit boundary.",
	"Prefer changing only the smallest necessary local region.",
	"Do not expand the edit to other files unless the user explicitly requires it.",
	"Summarize the local patch when you finish.",
];

const PLAN_RULES = [
	"You are operating in Strider plan mode.",
	"Your only job this turn is to produce a complete review plan by calling the `strider_plan` tool exactly once.",
	"Read whatever files you need first to understand the user's goal, then call strider_plan.",
	"Classify the review in the tool call: scope is 'selection' (user gave a range), 'diff' (user wants changes vs a branch/base — include the base ref), or 'free' (open-ended).",
	"Stops must be small — keep each stop ≤ 40 lines. Order them pedagogically (foundations → consumers → tests), not in discovery order.",
	"For 'selection' and 'diff' scopes, the union of stops must cover every line in the selected range / every changed line in the diff.",
	"",
	"LINE NUMBERS — read carefully. Your line numbers must be absolute file line numbers matching the actual file content. Do NOT use offsets relative to the stop's start. If you haven't read the exact range in this turn, read it before writing the plan — do not guess. For each stop you MUST include a `firstLineText` field containing the verbatim (trimmed) content of the file at `startLine`; Strider uses it to self-correct if your numbers are off.",
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
	"Do NOT write a long prose reply outside the tool call — all explanations live inside `strider_plan`.",
];

function requestPrompt(label: string, request: string, rules: string[] = []): string {
	return [`${label} request: ${request}`, ...rules].join("\n");
}

export function planPrompt(request: string): string {
	return requestPrompt("Plan", request, PLAN_RULES);
}

export function explicitReviewPrompt(request: string): string {
	return requestPrompt("Review", request, EXPLICIT_REVIEW_RULES);
}

export function searchPrompt(request: string): string {
	return requestPrompt("Search", request, SEARCH_RULES);
}

export function promptPrompt(request: string): string {
	return requestPrompt("Prompt", request);
}

export function patchPrompt(request: string): string {
	return requestPrompt("Patch", request, PATCH_RULES);
}
