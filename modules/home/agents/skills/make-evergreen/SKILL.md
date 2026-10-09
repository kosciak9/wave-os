---
name: make-evergreen
description:
  Refactors the codebase so it reads as if the current design had been there
  from the start, without leftover names, shims, or conversation-specific
  context. Use when making a change evergreen, cleaning up after an agent, or
  removing leftover versioned or compatibility structure.
disable-model-invocation: true
---

# Make evergreen

The objective is to make sure that the codebase is evergreen, i.e. it looks as
if it were written with the current logic/features in mind from the start. This
applies not only to the code, but also to tests, documentation, and anything
else the codebase contains. Remove all convoluted naming, roundabout logic and
pointless abstractions. Consider both the contents of files and their
structure - renaming files, splitting or joining them, changing the directory
structure etc. are all on the plate.

Your work should be a pure refactor - behaviour should not change, except for
fixing bugs or improving performance.

## The problem to address

Coding agents tend to produce minimal-diff changes with backward compatibility
in mind, but this is detrimental to the long-term maintainability of the
codebase. For example:

- An agent wanted to create a file called `gardening` where it would put
  cabbage-planting logic.
- The agent discovered that a file with that name already existed and contained
  irrigation and soil-prep logic.
- It decided to create a new file called `cabbage-planting` and put the
  cabbage-planting logic there.
- In that case, you should consider creating a `gardening` directory, place the
  original file into it while splitting it into `irrigation` and `soil-prep`,
  and move `cabbage-planting` in there too.

Coding agents also tend to add patches on top of existing content rather than
changing the underlying structure and possibly removing unneeded content when
that would be more appropriate. For example:

- An agent was told to ensure cabbages always have water.
- It decided to add logic which finds where cabbages grow and adds sprinklers
  there.
- It did not notice that, once this is done, sprinklers must simply be present
  in the entire garden, so the code stayed peppered with special cases when it
  could be much simplified.
- In this case, you should consider removing the special cases and simply
  ensuring that sprinklers are present in the entire garden.

One more thing which coding agents notoriously do, especially when writing
documentation but also when naming things, is to assume that future readers will
be familiar with their conversation context, which of course they won't. For
example:

- An agent was told to implement a more efficient sprinkler system.
- When drafting a plan for the implementation, it called the new system
  "sprinkler-system-v2".
- When implementing the plan, it kept referring to "v2" even though future
  readers won't need to know which iteration it is.
- In this case, you should consider removing the mentions of "v2".

Note that when this skill tells you to consider doing something, it does not
necessarily mean you should do it. It is your judgement call whether this is
actually beneficial to the overall maintainability of the codebase and
conformance to its coding standards. To help you in your decision, you may look
at the history of the codebase - what the direction seems to be, where bugs
appeared historically, what was easy/difficult to change, which pieces of it
seem coupled and which seem independent, etc.

## Scope

This skill will often be invoked without telling you which part of the codebase
it applies to. If so, here are some hints:

- If you have recently made some edits, the scope is what you edited, plus
  adjacent/related content.
- If this skill was invoked out of the blue entirely, the scope is the entire
  codebase.
