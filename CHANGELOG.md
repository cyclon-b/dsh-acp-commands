# Changelog

## 0.1.0 — 2026-10-23

First working release, verified against `dsh 0.2.1-rc.2` and Zed 1.25.3.

- Advertise the harness command registry to ACP clients with
  `available_commands_update` after `session/new`, after `session/resume`, and on
  `commands/change`; the notification is ordered after the triggering response.
- Dispatch slash prompts through `ctx.commands.execute()` and render the settled
  text as an `agent_message_chunk`; the prompt settles with `stopReason: end_turn`.
- Keep prompts that carry non-text blocks or name an unknown command on the
  model path.
- `install.ps1` (Windows, tested) and `install.sh` (POSIX, best effort) with an
  idempotent profile patch, a `dsh` version guard and `-Revert`/`--revert`.
- `scripts/probe.ps1` end-to-end ACP probe, `scripts/verify-hooks.mjs` hook guard,
  CI on Node 22.

Commands observed in a Zed thread: `/goal`, `/compact`, `/plan`, `/permission`,
`/feedback`.
