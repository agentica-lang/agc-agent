---
title: Skills
description: Skills are folders with a SKILL.md that the model or you load into a session. Where Finn finds them and how to write one.
weight: 70
---

# Skills

A skill is a folder with a `SKILL.md`: instructions, and any files they need,
for one kind of task. Finn follows the [Agent Skills](https://agentskills.io)
format, so skills written for other agents work too.

## Where Finn finds them

In these folders, of your home folder and of the session folder:

- `.finn/skills/`
- `.agents/skills/`
- `.claude/skills/`

The skills of the session folder count only when it is under one of
`FINN_TRUSTED_DIRS` (folders separated by `:`), since anyone who can write a
repository can write its skills. A project skill hides a home skill of the
same name. Finn uses 100 skills at most.

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

- `description` is required, at most 1024 characters. The model reads it to
  decide when to load the skill.
- `name` is the folder's name when left out: `a-z`, `0-9` and `-`, at most
  64 characters.
- `disable-model-invocation: true` keeps the skill from the model: only you
  load it.

A skill that has a problem is skipped, and the server says why in its log
(`finn server logs`).

## Load one

- **The model** sees the name and description of each skill in its system
  prompt, and loads one with the `activate_skill` tool when it fits the task.
- **You** type `/name` in a message: `/release-notes 1.2.0`. The skill's
  content goes before your message.

A skill loads once per session. Its other files are listed for the model, which
reads them with `read_file`. When a compaction folds the message that loaded a
skill, the skill comes back after the summary.
