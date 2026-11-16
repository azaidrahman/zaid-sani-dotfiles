// Drive the shared notify-tmux.sh hook from pi's lifecycle, so a pi session
// gets the same tmux colours and Mac banners as Claude Code.
//
//   pi before_agent_start  -> working   (window turns busy)
//   pi tool_call           -> working   (idempotent in the hook)
//   pi agent_end           -> stop      (done, or question if the reply ends in "?")
//   pi session_shutdown    -> exit      (clears the pane state)
//
// permission_prompt is fired by safety-gate.ts at the moment it asks you.
// Skipped when hasUI === false (print mode / subagents), like superset-hooks.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { fireNotify, notifyHookAvailable } from "../lib/notify-hook";

export default function (pi: ExtensionAPI) {
	if (!notifyHookAvailable()) return;

	const skip = (ctx: { hasUI?: boolean }) => ctx.hasUI === false;
	const sessionId = (ctx: { sessionManager?: { getSessionId?: () => string } }) => {
		try {
			return ctx.sessionManager?.getSessionId?.() ?? "";
		} catch {
			return "";
		}
	};

	// Final assistant text of the turn, so the hook can tell "done" from "asked you a question".
	const lastAssistantText = (messages: unknown[]): string => {
		for (let i = messages.length - 1; i >= 0; i--) {
			const m = messages[i] as { role?: string; content?: unknown };
			if (m?.role !== "assistant") continue;
			if (typeof m.content === "string") return m.content;
			if (Array.isArray(m.content)) {
				const texts = m.content
					.filter((c: { type?: string }) => c?.type === "text")
					.map((c: { text?: string }) => c.text ?? "");
				if (texts.length) return texts[texts.length - 1];
			}
			return "";
		}
		return "";
	};

	pi.on("before_agent_start", (_event, ctx) => {
		if (skip(ctx)) return;
		fireNotify("working", { session_id: sessionId(ctx) });
	});

	pi.on("tool_call", (_event, ctx) => {
		if (skip(ctx)) return undefined;
		fireNotify("working", { session_id: sessionId(ctx) });
		return undefined;
	});

	pi.on("agent_end", (event, ctx) => {
		if (skip(ctx)) return;
		fireNotify("stop", {
			session_id: sessionId(ctx),
			last_assistant_text: lastAssistantText(event.messages ?? []),
		});
	});

	pi.on("session_shutdown", (_event, ctx) => {
		if (skip(ctx)) return;
		fireNotify("exit", { session_id: sessionId(ctx) });
	});
}
