---
title: Skills
description: Skills are folders with a SKILL.md that the model or you load into a session. Where Finn finds them and how to write one.
weight: 70
---

# Skills

A skill is a folder with a `SKILL.md`: instructions, and any files they need, for one kind of task. Finn follows the [Agent Skills](https://agentskills.io) format, so skills written for other agents work too.

## Where Finn finds them

In these folders, of your home folder and of the session folder:

- `.finn/skills/`
- `.agents/skills/`
- `.claude/skills/`

The skills of the session folder count only when it is under a [trusted folder](config.md#trusted-folders). A project skill hides a home skill of the same name. Finn uses 100 skills at most (the built-in one comes after them).

## The finn skill

Finn has one skill of its own, `finn`, for tasks about Finn itself: extending it, its config, skills, MCP servers, providers, sessions, the server and the command line. It has the lowest precedence: a skill of yours with the name `finn` hides it, and a [slash command](cli.md#slash-commands) of that name wins over it (with a warning about the clash). It is added after your skills, only when there is room: with 100 of them it is not offered.

Its resources are the pages of this documentation, the Markdown files of `docs/content` in the install (regular files of that folder, not links), read in place and never copied, so they are the pages of the version that runs. When the model loads it, it gets one line for each page and reads the one that fits the task with `read_file`. You can read the same pages with `finn docs [PAGE]`.

The skill exists when the server knows the install: `bin/finn` sets `FINN_HOME` to it, and a server started by hand (`agentica core/main.agc serve`) needs `FINN_HOME` set to the folder that holds `docs/`. A session keeps the skills it was created with, so a session from before the server had the skill does not get it; a new session does.

## Write one

```text
.finn/skills/release-notes/
  SKILL.md
  template.md
```

```markdown
---
name: release-notes
description: Write the release notes of a version from CHANGELOG.md. Use when asked for release notes.
---

Read CHANGELOG.md, take the section of the version, and fill template.md...
```

- `description` is required. The model reads it to decide when to load the skill. Past 1024 characters it is cut, with a warning.
- `name` is the folder's name when left out: `a-z`, `0-9` and `-`, at most 64 characters.
- `disable-model-invocation: true` keeps the skill from the model: only you load it.

A skill that has a problem is skipped. The server's log (`finn server logs`) says why, and has the warnings.

## Load one

- **The model** sees the name and description of each skill in its system prompt, and loads one with the `activate_skill` tool when it fits the task.
- **You** type `/name` in a message: `/release-notes 1.2.0`. The skill's content goes before your message.

A skill loads once per session. Its other files are listed for the model, which reads them with `read_file`. When a compaction folds the message that loaded a skill, the skill comes back after the summary.
