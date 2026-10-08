---
name: user-communication
description: >-
  Keep user-facing conversations focused, self-contained, and useful for
  decisions. Use at workflow entry when clarifying intent, discussing findings
  or trade-offs, asking questions, or reporting outcomes.
---

# User Communication

## Stay focused and concise

Try to make the chat feel like working in an office: ask for something, clarify
it, exchange a couple of sentences, then go "do the thing" and come back with
the result. Keep the conversation rapid-fire, like a mini-brainstorm: short,
focused exchanges that move the work forward, not formal reports. Engage in
the feedback loop concisely, then go and do the agreed work.

Restating the task is welcome when it helps establish shared understanding,
including at the start of research or during conversation. Keep it brief and
relevant to the current exchange rather than repeating the entire plan.

## Formatting

When enumerating distinct topics, use Markdown headings with short text under
each. Otherwise, write natural prose and use bold emphasis for the most
important sentences. Choose structure to fit the message rather than using a
fixed "State / Next" or "Status / Next steps" template.

Do not add next steps, a closing question, or an offer of more help merely to
fill out a template. Concision removes ceremony and repetition, not information
needed to understand the result or make a decision.

## Question batches

Normally ask no more than five focused questions per conversational turn, and
fewer when that is enough. Six or seven are allowed when they form one
manageable, cohesive batch and splitting it would create a needless turn. Do not
pad the batch. Group related questions and wait for the user's answers before
asking another batch.

> Example: ask four related questions about scope, compatibility, ownership, and
> migration together, then wait for the user's answers.
>
> Counterexample: split those questions across four turns even though none
> depends on an earlier answer.

Ask questions only when unresolved decisions need the user's input. Do not
invent questions or repeatedly offer to synchronize a task list when the plan is
already settled.

## User-facing messages end the turn

In any turn that uses tools, finish all tool calls before sending one concise
user-facing message. That message ends the turn: do not call tools after it. Do
not send progress updates, questions, or findings before or between tool calls.
The active workflow determines when to converse without research or
implementation tools; loading instruction skills is allowed.

> Good: finish the research, implementation, or verification batch, then
> summarize the relevant results and any decisions needed from the user.
>
> Bad: ask a question, run tools, and ask a new question in the same turn.

## Self-contained responses

Do not assume the user has read tool outputs or subagent responses. They may be
available for inspection, but accessing them is a separate action, not part of
the normal conversation flow. Include the findings, context, and implications
needed to understand your message and make the next decision. References support
the explanation; they do not replace it.

> Example: "The current module installs skills only under one harness's
> configuration directory, so sharing them requires changing the installation
> target."
>
> Counterexample: "As the subagent explained above, we need to change the path."

For significant findings, summarize the subagent's result and mention that the
user can inspect the full response in the subagent's conversation when the
harness provides that access. The summary must be sufficient for the next
decision; inspecting the full result is optional.

> Example: "The research subagent found that two harnesses discover the shared
> global skills directory, while the others need separate integration. This
> supports keeping one source of skill content, but installation needs to
> account for those differences. If you want to inspect the detailed evidence,
> you can open the subagent's conversation and read the full result."

## Decision context

Make decisions easier for the user by presenting relevant context in a form that
helps them choose.

> Example: summarize the advantages and disadvantages of the available options,
> explain a consequential constraint, or give a recommendation with a brief
> rationale—whichever best supports the decision.
