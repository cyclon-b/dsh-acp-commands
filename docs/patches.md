# Fork hooks

`lib/index.js` is `@deepseek-ai/dsh-acp@0.2.1-rc.2` — its compiled
`lib/index.js`, 1467 lines upstream — with four additions. Everything else is
upstream code, unchanged.

When a new `dsh` release ships, port these four hooks onto the new file. Search
for the **anchor** text rather than line numbers; the compiled output is a
single flat module and line numbers move with every release.

---

## Hook 1 — plugin identity and dependency set

**Anchor:** the module-scope constants right before `invalidParams`.

Before:

```js
const name = "acp";
/** Core services required by the standard automation controls. */
const inject = [
	"agents",
	"llm",
	"sessionPersistence",
	"sessions"
];
```

After:

```js
const name = "acp-commands";
/** Core services required by the standard automation controls and the command plane. */
const inject = [
	"agents",
	"commands",
	"llm",
	"sessionPersistence",
	"sessions"
];
/** Canonical slash-command syntax, shared with the harness command registry. */
const COMMAND_LINE = /^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u;
/**
* The full command line when an ACP prompt is exactly one plain text block that starts a command.
* @param prompt - untrusted ACP prompt blocks.
* @returns the command line, or `undefined` when the prompt is ordinary model input.
*/
function commandLineOf(prompt) {
	if (!Array.isArray(prompt) || prompt.length !== 1) return void 0;
	const block = prompt[0];
	if (block?.type !== "text" || typeof block.text !== "string") return void 0;
	return COMMAND_LINE.test(block.text) ? block.text : void 0;
}
/**
* Project one harness command descriptor onto the standard ACP slash-command shape.
* @param descriptor - effective command descriptor for the addressed agent.
* @returns the wire advertisement entry.
*/
function availableCommand(descriptor) {
	return {
		name: descriptor.name,
		description: descriptor.description,
		...descriptor.input === void 0 ? {} : { input: { hint: descriptor.input.hint } }
	};
}
/**
* The assistant-visible text for a settled command execution.
* @param execution - settled registry execution.
* @returns display text for the ACP client.
*/
function commandResultText(execution) {
	const { result } = execution;
	if (result.text !== void 0 && result.text.length > 0) return result.text;
	return result.kind === "success" ? "Command completed." : "Command failed.";
}
```

The `commands` service must be required, not optional: the bridge dispatches
through it, and a missing service would otherwise surface as a runtime
`undefined` on the first slash prompt.

---

## Hook 2 — advertisement and refresh

**Anchor:** the `ctx.on("session/event", …)` listener inside `apply`, immediately
after it.

Before:

```js
	ctx.on("session/event", (session, event) => {
		const record = sessions.get(session.header.id);
		if (record?.ownsSession(session) === true) record.onSessionEvent(session, event);
	});
	ctx.on("agent/inbox/claimed", ({ agent, message, turn }) => {
```

After:

```js
	ctx.on("session/event", (session, event) => {
		const record = sessions.get(session.header.id);
		if (record?.ownsSession(session) === true) record.onSessionEvent(session, event);
	});
	/** Publish the effective harness command catalog to one ACP session. */
	const advertiseCommands = async (record) => {
		const registry = ctx.commands;
		if (registry === void 0) return;
		let availableCommands;
		try {
			availableCommands = registry.list(record.agent).map((command) => availableCommand(command));
		} catch {
			/* a record disposed between the trigger and this callback carries nothing to advertise */
			return;
		}
		try {
			logger.info(`acp: advertising ${availableCommands.length} slash command(s) for session ${record.agent.session.id}`);
		} catch {
			/* diagnostics are optional */
		}
		await notify({
			sessionId: record.agent.session.id,
			update: {
				sessionUpdate: "available_commands_update",
				availableCommands
			}
		});
	};
	/**
	* Advertise after the triggering response reaches the client: a client that
	* routes updates by session id ignores notifications for a session it has not
	* registered yet, so the session/new (or session/resume) response goes first.
	*/
	const scheduleAdvertise = (record) => {
		setTimeout(() => {
			void advertiseCommands(record);
		}, 0);
	};
	ctx.on("commands/change", () => {
		for (const record of sessions.values()) void advertiseCommands(record);
	});
	ctx.on("agent/inbox/claimed", ({ agent, message, turn }) => {
```

`notify` and `logger` already exist in `apply`; `record.agent` is the live Agent
of that ACP session.

The `setTimeout(…, 0)` is load-bearing. Awaiting `advertiseCommands` inside the
`session/new` handler writes the notification *before* the response, and Zed
discards updates whose session id it has not registered yet.

---

## Hook 3 — advertise on session creation and resume

**Anchor 1:** inside `newSession`, right before the success `return`.

```js
				assertOpen();
				await ctx.sessions.flush(record.agent.session);
				assertOpen();
				scheduleAdvertise(record);
				return {
					sessionId,
					configOptions
				};
```

**Anchor 2:** inside `resumeSession`, where the config options are produced.

Before:

```js
					return { configOptions: await record.configOptions(signal) };
```

After:

```js
					const configOptions = await record.configOptions(signal);
					scheduleAdvertise(record);
					return { configOptions };
```

Without hook 3 a client sees no commands until a `commands/change` event fires,
which normally never happens mid-session.

---

## Hook 4 — slash dispatch in the prompt handler

**Anchor:** `implementation.prompt`.

Before:

```js
		async prompt(params, requestSignal) {
			assertOpen();
			return requireSession(brandString(params.sessionId)).prompt(params, imagePromptEnabled, requestSignal);
		},
```

After:

```js
		async prompt(params, requestSignal) {
			assertOpen();
			const record = requireSession(brandString(params.sessionId));
			const line = commandLineOf(params.prompt);
			if (line !== void 0) {
				const execution = await ctx.commands.execute(record.agent, line, [], requestSignal);
				if (execution !== void 0) {
					await notify({
						sessionId: params.sessionId,
						update: {
							sessionUpdate: "agent_message_chunk",
							content: {
								type: "text",
								text: commandResultText(execution)
							}
						}
					});
					return { stopReason: "end_turn" };
				}
			}
			return record.prompt(params, imagePromptEnabled, requestSignal);
		},
```

Two deliberate choices:

- `execute()` returns `undefined` for unknown names and for non-command lines;
  falling through keeps ordinary prompts — including prose that begins with `/` —
  on the model path.
- The settled result is emitted as one `agent_message_chunk`. ACP has no
  dedicated command-result update, and a plain assistant message is what Zed
  renders for a command reply.

---

## Verifying a re-derivation

```sh
npm run check     # node --check + scripts/verify-hooks.mjs
```

Then drive the real server over stdio:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\probe.ps1 `
  -Prompts "/goal demo objective;/goal;/compact;/plan;reply with pong"
```

A correct port prints one `available_commands_update` with five commands, the
settled text of each command, and the model's answer to the free-form prompt.
