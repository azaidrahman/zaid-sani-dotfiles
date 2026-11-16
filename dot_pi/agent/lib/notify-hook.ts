// Shared bridge from pi extensions to ~/.claude/hooks/notify-tmux.sh.
//
// The hook is the single notification system for every coding agent on this
// machine: it colours the tmux window and posts the Mac banner. pi reuses it
// instead of running its own.
//
// Events the hook accepts: working | permission_prompt | idle_prompt | stop | exit
// The payload is a Claude-Code-shaped JSON object on stdin.
//
// Fire-and-forget: a failure to spawn never reaches the agent loop.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type NotifyEvent = "working" | "permission_prompt" | "idle_prompt" | "stop" | "exit";

const HOOK = join(homedir(), ".claude", "hooks", "notify-tmux.sh");

export function notifyHookAvailable(): boolean {
	return existsSync(HOOK);
}

export function fireNotify(event: NotifyEvent, payload: Record<string, unknown> = {}): void {
	if (!existsSync(HOOK)) return;
	try {
		const child = spawn("bash", [HOOK, event], {
			stdio: ["pipe", "ignore", "ignore"],
			detached: true,
			// pi skips the Mac banner and the local sound.
			env: { ...process.env, CLAUDE_NOTIFY_AGENT: "pi", CLAUDE_NOTIFY_LOCAL: "0" },
		});
		child.on("error", () => {});
		child.stdin?.on("error", () => {});
		child.stdin?.end(JSON.stringify(payload));
		child.unref();
	} catch {
		// spawn can throw synchronously (ENOENT, EACCES). Stay silent.
	}
}
