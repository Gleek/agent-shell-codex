# agent-shell-codex

Codex extensions for [agent-shell](https://github.com/xenodium/agent-shell):

- Account login and switching through `codex-auth`.
- Remaining subscription quota in Codex headers.
- Rewind to before a selected turn, or archive a session.
- Automatic `continue` after capacity failures, with a ten-second delay.

## Requirements

Emacs 29.1+, agent-shell 0.87.10+, and the `codex` CLI on Emacs's `exec-path`.
Login and account switching also require `codex-auth` from
`@loongphy/codex-auth`. Other features do not require it.

The package uses agent-shell event subscriptions and internal prompt/header
helpers. It is tested against the author's current checkout; internal API
changes may require updates.

## Installation

With Elpaca and use-package:

```elisp
(use-package agent-shell-codex
  :ensure (:host github :repo "Gleek/agent-shell-codex")
  :after agent-shell
  :demand t
  :custom
  (agent-shell-codex-show-usage-indicator t))
```

For a local checkout:

```elisp
(add-to-list 'load-path "/path/to/agent-shell-codex")
(require 'agent-shell-codex)
```

Loading enables capacity retries and installs the quota header integration.
Quota display is disabled by default.

## Commands

| Command | Action |
| --- | --- |
| `agent-shell-codex-login` | Add an account through browser login. |
| `agent-shell-codex-switch-account` | Select a saved account and open a new Codex shell. |
| `agent-shell-codex-refresh-usage` | Refresh the CLI account's quota. |
| `agent-shell-codex-rewind` | Choose a turn and confirm rewinding to before it. |
| `agent-shell-codex-archive-this-session` | Confirm archiving the session and close its shell. |

The CLI account and quota cache are shared across shells. Existing clients
need restarting to use a changed login. Quota in an older shell may therefore
belong to a different account than that shell uses. When enabled, quota
refreshes once a minute while a Codex shell is visible.

Capacity retries handle request errors and streamed capacity messages.
Streamed messages wait for turn completion. Each new capacity failure schedules
another retry. Submitting input or closing the shell cancels a pending retry.
Retries skip busy sessions and leave unsubmitted shell input alone.

## Configuration

| Variable | Default |
| --- | --- |
| `agent-shell-codex-show-usage-indicator` | `nil` |
| `agent-shell-codex-app-server-command` | `("codex" "app-server" "--listen" "stdio://")` |
| `agent-shell-codex-app-server-timeout` | `10` seconds |

## Session history

The Codex app-server protocol is experimental. Methods and payloads may change.

Rewind uses `thread/revert` to discard the selected turn and all later turns,
then reloads the shell. Project files are unchanged. It requires Codex's
paginated history format. To migrate an older session, run:

```sh
codex migrate-rollouts --thread SESSION_ID --apply
```

This requires a Codex version that supports `thread/revert` (tested with
0.163.0). The removed `thread/rollback` API and direct JSONL edits are no
longer used. Archive uses `thread/archive`.

Both commands require an idle Codex shell and ask for confirmation. They stop
the ACP client before changing history to release its writer lock. Rewind
reloads the shell even if the operation fails; archive reloads on failure.

## Development

With local dependency checkouts:

```sh
make test AGENT_SHELL_DIR=/path/to/agent-shell SHELL_MAKER_DIR=/path/to/shell-maker ACP_DIR=/path/to/acp
make compile AGENT_SHELL_DIR=/path/to/agent-shell SHELL_MAKER_DIR=/path/to/shell-maker ACP_DIR=/path/to/acp
```

Use `EXTRA_LOAD_PATH="-L /path/to/dependency"` for additional dependencies
required by your agent-shell checkout, such as a newer Transient.

Tests exercise capacity retries without contacting Codex. Account and history
commands need a live CLI session for integration testing.

## License

GPL-3.0-or-later. See [COPYING](COPYING).
