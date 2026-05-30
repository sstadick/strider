export type OperationKind = "search" | "review" | "patch" | "prompt" | "plan";

export type ReadOnlyState = {
	activeOperation?: OperationKind;
	chatReadOnly?: boolean;
};

export type ReadOnlyGuard = {
	label: string;
	blocksBash: boolean;
};

export const CHAT_READ_ONLY_COMMAND = "strider_chat_read_only";

export function readOnlyGuard(state: ReadOnlyState): ReadOnlyGuard | undefined {
	if (state.activeOperation === "review" || state.activeOperation === "search" || state.activeOperation === "plan") {
		return { label: `Strider ${state.activeOperation} mode`, blocksBash: true };
	}
	if (state.activeOperation === "prompt" && state.chatReadOnly === true) {
		return { label: "Strider chat read-only mode", blocksBash: false };
	}
	return undefined;
}

export function isWriteTool(toolName?: string): boolean {
	return toolName === "edit" || toolName === "write";
}

export function parseChatReadOnlyArg(args: unknown, current: boolean): boolean | undefined {
	const value = String(args ?? "").trim().toLowerCase();
	if (value === "on" || value === "true" || value === "1" || value === "enable" || value === "enabled") {
		return true;
	}
	if (value === "off" || value === "false" || value === "0" || value === "disable" || value === "disabled") {
		return false;
	}
	if (value === "" || value === "toggle") {
		return !current;
	}
	return undefined;
}
