#!/usr/bin/env node
/**
 * Guards the four fork hooks in lib/index.js.
 *
 * The file is a patched copy of an upstream artifact, so a hand edit, a botched
 * merge or a careless re-derivation can silently drop one hook while the file
 * still parses. This script asserts that every hook marker is present and that
 * the two advertise call sites have not gone missing.
 */
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const target = join(here, '..', 'lib', 'index.js')
const source = await readFile(target, 'utf8')

/** Each entry: what the hook does, and the markers that must exist for it. */
const hooks = [
  {
    name: 'hook 1 — plugin identity and the commands injection',
    markers: [
      'const name = "acp-commands";',
      '\t"commands",\n'
    ]
  },
  {
    name: 'hook 2 — command-shape projection helpers',
    markers: [
      'const COMMAND_LINE = /^\\/([a-z][a-z0-9_-]*)(?=$|[\\t\\n\\r ])/u;',
      'function commandLineOf(prompt) {',
      'function availableCommand(descriptor) {',
      'function commandResultText(execution) {'
    ]
  },
  {
    name: 'hook 3 — available_commands_update advertising',
    markers: [
      'sessionUpdate: "available_commands_update"',
      'const advertiseCommands = async (record) => {',
      'const scheduleAdvertise = (record) => {',
      'ctx.on("commands/change"'
    ]
  },
  {
    name: 'hook 4 — slash dispatch in the prompt handler',
    markers: [
      'const line = commandLineOf(params.prompt);',
      'await ctx.commands.execute(record.agent, line, [], requestSignal)',
      'sessionUpdate: "agent_message_chunk"'
    ]
  }
]

const failures = []
for (const hook of hooks) {
  for (const marker of hook.markers) {
    if (!source.includes(marker)) failures.push(`${hook.name}: missing ${JSON.stringify(marker)}`)
  }
}

const advertiseCallSites = source.split('scheduleAdvertise(record);').length - 1
if (advertiseCallSites !== 2) {
  failures.push(`hook 3: expected 2 scheduleAdvertise(record) call sites (session/new, session/resume), found ${advertiseCallSites}`)
}

if (failures.length > 0) {
  console.error(`verify-hooks: ${failures.length} problem(s) in ${target}`)
  for (const failure of failures) console.error(`  - ${failure}`)
  process.exit(1)
}

console.log(`verify-hooks: all ${hooks.length} hooks present in lib/index.js`)
