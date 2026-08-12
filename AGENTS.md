# Writing style

## Commit messages

One subject line telling its part of the story — that is the whole message.
A body (a few lines, tops) is earned only by a hard-won fix whose cause the
diff can't show: a dontaudit'd SELinux denial, a target nothing pulls in.
Design narration, decision logs, and trailers belong nowhere in history.

## Code comments

The code carries its own meaning; ship it bare. A comment exists only where
the code cannot speak: a constraint invisible in the file (why two units
can't be ordered), or a config example whose values need explaining
(deploy.env.example). One line each.

## Docs

Lean wording. Every fact has one home; other docs point at it. Document only
what a reader can't look up: conventions, reasons, gotchas. The environment
(Makefile, configs, --help) is the source of truth for commands and values —
restating it is a cache that goes stale.
