# dsh-acp-commands

> Slash commands — `/goal`, `/compact`, `/plan`, `/permission`, `/feedback` — for
> [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) agents running
> inside [Zed](https://zed.dev) (or any other ACP client).

[Русская версия](README.ru.md)

## The problem

In DeepSeek Harness, slash commands are a **UI-plane** feature: a registry
(`ctx.commands`) plus an adapter owned by each frontend (Web UI, CLI). The ACP
bridge — `@deepseek-ai/dsh-acp` — intentionally exposes only the standard ACP v1
surface:

- no `available_commands_update`, so no client renders a `/` menu;
- no slash dispatch, so `/goal …` would be sent to the model as plain text.

The command producers themselves (`dsh-commands`, `dsh-goal`, `dsh-command-goal`,
`dsh-command-compact`, `dsh-plan-mode`, `dsh-permission-presets`,
`dsh-command-feedback`) are already mounted by the base bundle in the `acp`
profile. Only the bridge is missing.

Checked against `deepseek-ai/deepseek-harness@master` on 2026-10-23: the bridge
still has no command surface, so this repository is not a duplicate of upstream
work.

## What this repository ships

An **additive fork of the ACP bridge** with four hooks, plus tooling to install,
verify and re-derive it after a `dsh` upgrade.

| Command | Behaviour in the Zed thread |
|---|---|
| `/goal [<objective> \| clear \| edit <objective> \| pause \| resume]` | creates/edits the goal, prints status, rounds and activation state |
| `/compact` | one manual compaction pass |
| `/plan [off \| <message>]` | enters/leaves plan mode |
| `/permission <preset>` | switches the permission preset |
| `/feedback <text>` | feedback channel |

`/export` and `/file` do **not** appear: they live in the web host and the web
client UI, not in the base bundle.

## How it works

`lib/index.js` is a patched copy of `@deepseek-ai/dsh-acp@0.2.1-rc.2`. The four
hooks, with exact snippets, are documented in [docs/patches.md](docs/patches.md).

1. **Advertise.** After `session/new` and `session/resume`, and again on
   `commands/change`, the bridge sends `session/update` with
   `sessionUpdate: "available_commands_update"`, mapping
   `ctx.commands.list(agent)` descriptors onto ACP `AvailableCommand`
   (`{name, description, input: {hint}}`).
2. **Order matters.** The advertisement is scheduled with `setTimeout(…, 0)` so
   the `session/new` *response* reaches the client first. A client that routes
   updates by session id — Zed included — drops notifications for a session it
   has not registered yet.
3. **Dispatch.** If `session/prompt` is exactly one text block whose first bytes
   are a registered command line, the bridge calls
   `ctx.commands.execute(agent, line, [], signal)` instead of `admitAcpPrompt`.
   The settled text is emitted as `agent_message_chunk` and the prompt returns
   `{stopReason: "end_turn"}`.
4. **Fallback.** Unknown `/…` input, or any prompt carrying non-text blocks,
   still goes to the model. Nothing that used to work stops working.

## Requirements

- `dsh` **0.2.1-rc.2** (tested). The fork is a compiled-JS copy, so a different
  release needs the hooks re-applied — see [Updating](#updating-for-a-new-dsh-release).
- Zed with External Agents (tested on 1.25.3), or any ACP v1 client that
  supports `available_commands_update`.
- Node.js ≥ 22, PowerShell 5.1+ (Windows) or `sh` (POSIX).

## Install

### Windows (tested)

```powershell
git clone https://github.com/cyclon-b/dsh-acp-commands.git
cd dsh-acp-commands
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

### POSIX (best effort, untested)

```sh
git clone https://github.com/cyclon-b/dsh-acp-commands.git
cd dsh-acp-commands
./install.sh
```

Both installers:

1. copy the fork to
   `<npm root -g>/@deepseek-ai/dsh/node_modules/dsh-acp-commands`;
2. link that directory into `~/.dsh/profiles/acp/node_modules/dsh-acp-commands`
   (junction on Windows, symlink elsewhere);
3. edit `~/.dsh/profiles/acp/cordis.patch.yml` so the stock `acp` row is disabled
   and `acp-commands` is mounted with the same provider/model config.

> **Do not install this package with `dsh plugin --profile acp add`.**
> The fork must resolve the *same* `cordis`, `dsh-agent` and ACP SDK instances as
> the rest of the `dsh` installation. A pnpm tree in the profile creates a second
> copy of every service, which fails at boot with
> `service "compaction" has been registered at <BasicCompactionEngine>`.
> The installers therefore materialize the package inside the global `dsh`
> installation and only link it into the profile.

Re-running an installer is idempotent. Both warn when the installed `dsh`
version differs from the one the fork was written for; pass `-Force` (Windows)
after re-deriving the hooks.

## Register the agent in Zed

If it is not registered yet, add it to Zed's settings (`settings.json`) — see
[Zed: External Agents](https://zed.dev/docs/ai/external-agents):

```json
{
  "agent_servers": {
    "DeepSeek Harness": {
      "type": "custom",
      "command": "cmd",
      "args": ["/c", "dsh", "--profile", "acp"],
      "env": {}
    }
  }
}
```

On macOS/Linux use `"command": "dsh", "args": ["--profile", "acp"]` instead —
`cmd /c` is only needed on Windows because the `dsh` shim is a `.cmd`/`.ps1`,
which `CreateProcess` cannot execute directly.

Then: Agent Panel → new thread → agent `DeepSeek Harness` → type `/`.
Transport debugging: `dev: open acp logs`.

## Verify without Zed

`scripts/probe.ps1` drives the real ACP server over stdio (`;` separates prompts):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\probe.ps1 `
  -Prompts "/goal demo objective;/goal;/compact;/plan;reply with pong"
```

Expected: one `available_commands_update` carrying the five commands, then the
result text of each command, then the model's answer.

## Updating for a new `dsh` release

A global upgrade replaces the installation directory, including the fork.

1. Upgrade: `npm i -g @deepseek-ai/dsh@<version>`.
2. Port the four hooks onto the new
   `node_modules/@deepseek-ai/dsh-acp/lib/index.js` — [docs/patches.md](docs/patches.md)
   contains the exact anchors and snippets.
3. `npm run check` (syntax + hook markers), then re-run the probe.
4. Re-install with `-Force`.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Revert
```

or `./install.sh --revert`. The stock bridge serves the `acp` profile again.

## Known behaviour and limitations

- **`/goal` starts autonomous work.** The goal round driver is mounted by the
  base bundle, so creating a goal arms it: the agent begins autonomous rounds,
  `/compact` then answers `agent is not idle`, and a following plain prompt is
  queued until the agent settles. That is stock DSH goal semantics, not a bridge
  defect.
- **Commands with attachments** are not intercepted — such prompts go to the model.
- **`/export`, `/file`** are absent by design (web host / web client only).
- **Unknown commands** fall back to the model instead of being rejected: ACP has
  no standard rejection channel and misclassifying prose that starts with `/`
  would be worse.
- The fork is **not merged upstream** and carries no DSH-specific presentation
  data: no plan cards, todo list, terminals or elicitation over ACP.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE). `lib/index.js` is a derivative
of `@deepseek-ai/dsh-acp` (MIT, Copyright (c) 2026 DeepSeek). Not affiliated with
or endorsed by DeepSeek.
