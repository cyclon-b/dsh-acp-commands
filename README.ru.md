# dsh-acp-commands — слэш-команды DSH в Zed

> `/goal`, `/compact`, `/plan`, `/permission`, `/feedback` для агентов
> [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) в Zed и
> любом другом ACP-клиенте.

[English](README.md)

## Зачем форк

В DSH команды — это UI-плоскость: реестр `ctx.commands` плюс адаптер конкретного
фронтенда (Web UI, CLI). Штатный ACP-мост `@deepseek-ai/dsh-acp` отдаёт только
стандартную поверхность ACP v1:

- нет `available_commands_update` — клиент не рисует меню по `/`;
- нет диспетчеризации — `/goal …` ушёл бы в модель обычным текстом.

Сами продюсеры команд (`dsh-commands`, `dsh-goal`, `dsh-command-goal`,
`dsh-command-compact`, `dsh-plan-mode`, `dsh-permission-presets`,
`dsh-command-feedback`) base-bundle в профиле `acp` уже монтирует — не хватает
только моста.

Проверено по `deepseek-ai/deepseek-harness@master` 2026-10-23: командной
поверхности в мосте по-прежнему нет, форк не дублирует upstream.

## Что даёт

| Команда | Поведение в треде Zed |
|---|---|
| `/goal [<objective> \| clear \| edit <objective> \| pause \| resume]` | ставит/правит цель, печатает статус, раунды и активацию |
| `/compact` | одно ручное сжатие контекста |
| `/plan [off \| <message>]` | вход/выход из режима планирования |
| `/permission <preset>` | переключение пресета разрешений |
| `/feedback <text>` | канал обратной связи |

`/export` и `/file` не появляются: они живут в web-хосте и web-клиенте, а не в
base bundle.

## Как устроено

`lib/index.js` — пропатченная копия `@deepseek-ai/dsh-acp@0.2.1-rc.2`. Четыре
хука с точными фрагментами описаны в [docs/patches.md](docs/patches.md).

1. **Реклама.** После `session/new`, `session/resume` и на `commands/change`
   мост отправляет `session/update` с `available_commands_update`, проецируя
   `ctx.commands.list(agent)` в ACP `AvailableCommand`.
2. **Порядок.** Реклама планируется через `setTimeout(…, 0)`, чтобы ответ
   `session/new` ушёл клиенту первым: клиент, маршрутизирующий updates по
   session id (Zed в том числе), отбрасывает уведомления для ещё не
   зарегистрированной сессии.
3. **Диспетчеризация.** Если `session/prompt` — ровно один текстовый блок,
   начинающийся с зарегистрированной команды, вызывается
   `ctx.commands.execute(agent, line, [], signal)` вместо `admitAcpPrompt`.
   Результат уходит как `agent_message_chunk`, ответ — `end_turn`.
4. **Фолбэк.** Неизвестный `/…` или промпт с нетекстовыми блоками уходит в
   модель, как раньше.

## Установка

```powershell
git clone https://github.com/cyclon-b/dsh-acp-commands.git
cd dsh-acp-commands
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

POSIX: `./install.sh` (best effort, не тестировалось).

Установщик копирует форк в
`<npm root -g>/@deepseek-ai/dsh/node_modules/dsh-acp-commands`, линкует каталог в
`~/.dsh/profiles/acp/node_modules/dsh-acp-commands` (junction на Windows) и
правит `~/.dsh/profiles/acp/cordis.patch.yml`: штатная строка `acp` выключается,
вместо неё монтируется `acp-commands` с той же конфигурацией провайдера/модели.

> **Не ставьте пакет через `dsh plugin --profile acp add`.**
> Форк обязан резолвить те же инстансы `cordis`, `dsh-agent` и ACP SDK, что и
> остальная установка. Дерево pnpm в профиле создаёт вторую копию сервисов и
> падает на старте с `service "compaction" has been registered`.

Повторный запуск идемпотентен. При другой версии `dsh` установщик предупреждает
и требует `-Force` после переноса хуков.

Распространения через npm намеренно нет: установка из реестра попала бы в
отдельное дерево модулей и получила ровно ту же проблему дублирующихся
инстансов. Поддерживаемый путь — `git clone` (или tarball релиза) плюс
установщик.

## Регистрация агента в Zed

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

На macOS/Linux — `"command": "dsh", "args": ["--profile", "acp"]`: `cmd /c` нужен
только на Windows, потому что шим `dsh` — это `.cmd`/`.ps1`, а `CreateProcess`
не умеет их запускать напрямую.

Agent Panel → новый тред → агент `DeepSeek Harness` → набрать `/`.
Отладка транспорта — `dev: open acp logs`.

## Проверка без Zed

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\probe.ps1 `
  -Prompts "/goal demo objective;/goal;/compact;/plan;reply with pong"
```

Промпты разделяются `;`. Ожидаемо: один `available_commands_update` с пятью
командами, затем текст результата каждой команды и обычный ответ модели.

## Обновление dsh

1. `npm i -g @deepseek-ai/dsh@<version>`
2. Перенести четыре хука на новый `dsh-acp/lib/index.js` — см.
   [docs/patches.md](docs/patches.md).
3. `npm run check` (синтаксис + маркеры хуков), затем probe.
4. Переустановить с `-Force`.

## Откат

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Revert
```

или `./install.sh --revert` — профиль `acp` снова обслуживает штатный мост
(команд в Zed не будет).

## Известное поведение и ограничения

- **`/goal` запускает автономную работу.** Goal-драйвер монтируется base-bundle'ом,
  поэтому создание цели его взводит: агент начинает автономные раунды, `/compact`
  отвечает «agent is not idle», а следующий обычный промпт встаёт в очередь до
  остановки агента. Это штатная семантика DSH, а не дефект моста.
- **Команды с вложениями** не перехватываются — такие промпты уходят в модель.
- **`/export`, `/file`** отсутствуют намеренно (web host / web client).
- **Неизвестные команды** уходят в модель: в ACP нет стандартного канала отказа,
  а ошибочно классифицировать прозу, начинающуюся с `/`, хуже.
- Форк **не влит в upstream** и не несёт DSH-презентации: карточек планов, todo,
  терминалов и elicitation по ACP нет.

## Лицензия

MIT — см. [LICENSE](LICENSE) и [NOTICE](NOTICE). `lib/index.js` — производная от
`@deepseek-ai/dsh-acp` (MIT, Copyright (c) 2026 DeepSeek). Проект не связан с
DeepSeek и не одобрен ею.
