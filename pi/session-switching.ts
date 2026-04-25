import { existsSync } from "node:fs";
import { basename, isAbsolute, resolve } from "node:path";
import { SessionManager, type SessionInfo } from "@mariozechner/pi-coding-agent";

function collapseWhitespace(text?: string): string | undefined {
	if (!text) return undefined;
	const collapsed = text.replace(/\s+/g, " ").trim();
	return collapsed.length > 0 ? collapsed : undefined;
}

export function looksLikePath(value: string): boolean {
	const trimmed = value.trim();
	return trimmed.startsWith(".") || trimmed.startsWith("/") || trimmed.startsWith("~") ||
		trimmed.includes("/") || trimmed.includes("\\") || trimmed.endsWith(".jsonl") ||
		/^[A-Za-z]:[\\/]/.test(trimmed);
}

export function shortSessionId(id?: string): string {
	return (id ?? "").slice(0, 7);
}

function expandUserPath(value: string): string {
	if (value === "~") return process.env.HOME ?? value;
	if (value.startsWith("~/") || value.startsWith("~\\")) {
		const home = process.env.HOME;
		return home ? resolve(home, value.slice(2)) : value;
	}
	return value;
}

function absoluteSessionPath(value: string, cwd: string): string {
	const expanded = expandUserPath(value.trim());
	if (isAbsolute(expanded) || /^[A-Za-z]:[\\/]/.test(expanded) || expanded.startsWith("\\\\")) {
		return expanded;
	}
	return resolve(cwd, expanded);
}

function formatSessionDate(date: Date): string {
	const now = new Date();
	const sameDay = date.toDateString() === now.toDateString();
	const time = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
	if (sameDay) return `Today ${time}`;
	return date.toLocaleDateString([], { month: "short", day: "numeric" });
}

function truncateText(text: string, max: number): string {
	return text.length <= max ? text : `${text.slice(0, Math.max(0, max - 1))}…`;
}

export function sessionTitle(info: SessionInfo): string {
	return collapseWhitespace(info.name) ?? collapseWhitespace(info.firstMessage) ?? basename(info.path);
}

export function formatSessionLabel(info: SessionInfo, currentId?: string): string {
	const marker = info.id === currentId ? "●" : " ";
	const modified = formatSessionDate(info.modified).padEnd(12);
	const title = truncateText(sessionTitle(info), 32).padEnd(32);
	const id = shortSessionId(info.id).padEnd(7);
	const count = `${info.messageCount} ${info.messageCount === 1 ? "msg" : "msgs"}`;
	return `${marker} ${modified} ${title} ${id} ${count}`;
}

function currentSessionDir(ctx: any): string | undefined {
	return typeof ctx.sessionManager?.getSessionDir === "function"
		? ctx.sessionManager.getSessionDir()
		: undefined;
}

async function localSessions(ctx: any): Promise<SessionInfo[]> {
	const sessions = await SessionManager.list(ctx.cwd, currentSessionDir(ctx));
	return sessions.sort((a, b) => b.modified.getTime() - a.modified.getTime());
}

function matchingSessions(sessions: SessionInfo[], input: string): SessionInfo[] {
	return sessions.filter((session) => session.id.startsWith(input));
}

export async function resolveSessionPath(input: string, ctx: any): Promise<string | SessionInfo[]> {
	const value = input.trim();
	if (!value) return [];
	if (looksLikePath(value)) return absoluteSessionPath(value, ctx.cwd);

	const localMatches = matchingSessions(await localSessions(ctx), value);
	if (localMatches.length === 1) return localMatches[0].path;
	if (localMatches.length > 1) return localMatches;

	const allMatches = matchingSessions(await SessionManager.listAll(), value);
	if (allMatches.length === 1) return allMatches[0].path;
	return allMatches;
}

export function sessionIdentity(ctx: any): string | undefined {
	const id = shortSessionId(ctx.sessionManager?.getSessionId?.());
	if (!id) return undefined;
	const name = collapseWhitespace(ctx.sessionManager?.getSessionName?.());
	return name ? `${truncateText(name, 48)} ${id}` : id;
}

function sessionSwitchLabel(ctx: any): string {
	return sessionIdentity(ctx) ?? basename(ctx.sessionManager?.getSessionFile?.() ?? "session");
}

function uniqueSessionLabels(sessions: SessionInfo[], currentId?: string): Map<string, SessionInfo> {
	const byLabel = new Map<string, SessionInfo>();
	for (const session of sessions) {
		let label = formatSessionLabel(session, currentId);
		let suffix = 2;
		while (byLabel.has(label)) label = `${formatSessionLabel(session, currentId)} [${suffix++}]`;
		byLabel.set(label, session);
	}
	return byLabel;
}

async function pickSession(ctx: any, title: string, sessions: SessionInfo[]): Promise<string | undefined> {
	const byLabel = uniqueSessionLabels(sessions, ctx.sessionManager?.getSessionId?.());
	const choice = await ctx.ui.select(title, [...byLabel.keys()]);
	return choice ? byLabel.get(choice)?.path : undefined;
}

function notifyAmbiguousSessions(input: string, sessions: SessionInfo[], ctx: any) {
	const ids = sessions.slice(0, 5).map((info) => shortSessionId(info.id)).join(", ");
	const suffix = sessions.length > 5 ? ", …" : "";
	ctx.ui.notify(`Multiple sessions match ${input}: ${ids}${suffix}`, "warning");
}

async function chooseResolvedSession(input: string, ctx: any): Promise<string | undefined> {
	const resolved = await resolveSessionPath(input, ctx);
	if (typeof resolved === "string") return resolved;
	if (resolved.length === 0) {
		ctx.ui.notify(`No saved sessions match: ${input}`, "warning");
		return undefined;
	}
	if (ctx.hasUI === false) {
		notifyAmbiguousSessions(input, resolved, ctx);
		return undefined;
	}
	return pickSession(ctx, `Resume session matching "${input}"`, resolved);
}

export async function switchToSession(
	path: string,
	ctx: any,
	update: (nextCtx: any) => void = () => {},
): Promise<boolean> {
	if (!existsSync(path)) {
		ctx.ui.notify(`Session file not found: ${path}`, "error");
		return false;
	}
	try {
		const result = await ctx.switchSession(path, {
			withSession: async (nextCtx: any) => {
				update(nextCtx);
				nextCtx.ui.notify(`Resumed session ${sessionSwitchLabel(nextCtx)}`, "info");
			},
		});
		if (result?.cancelled) ctx.ui.notify("Session switch cancelled", "info");
		return !result?.cancelled;
	} catch (err: any) {
		ctx.ui.notify(`Session switch failed: ${err?.message ?? err}`, "error");
		return false;
	}
}

export async function browseSessions(ctx: any, update: (nextCtx: any) => void): Promise<boolean> {
	const sessions = await localSessions(ctx);
	if (sessions.length === 0) {
		ctx.ui.notify("No saved sessions found", "warning");
		return false;
	}
	if (ctx.hasUI === false) {
		ctx.ui.notify("Session picker is not available in this mode", "warning");
		return false;
	}
	const path = await pickSession(ctx, "Resume session", sessions);
	return path ? switchToSession(path, ctx, update) : false;
}

export async function resumeSession(
	input: string,
	ctx: any,
	update: (nextCtx: any) => void,
): Promise<boolean> {
	const path = await chooseResolvedSession(input, ctx);
	return path ? switchToSession(path, ctx, update) : false;
}
