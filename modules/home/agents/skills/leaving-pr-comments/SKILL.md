---
name: leaving-pr-comments
description:
  Format and post a comment on a pull request on the user's behalf, with agent
  attribution and the repository's comment language. Use whenever leaving a PR
  comment, review reply, or resolution rationale.
when_to_use:
  any comment or review reply posted on a forge for the user, including GitHub
  and GitLab.
---

# Leaving PR Comments

Prefix every agent-authored comment left on the user's behalf with this note
callout:

```md
<!-- prettier-ignore -->
> [!NOTE]
> 🤖 **<model> responding on behalf of <user>**

Actual comment starts here.
```

Use the verified public name of the model that wrote the comment, and the user's
name or forge login. If the harness does not expose a model name, use the
harness name. Do not guess.

Before posting, check the entire comment, including quoted text and attachments,
for secrets and private details.

Keep the attribution inside the note and the actual reply outside it. The
context line must start with the robot emoji. Do not add a horizontal rule,
Setext underline, heading, signature footer, or a second attribution.

Apply this to top-level PR comments, inline review comments, replies to bots or
reviewers, and the written reason given before resolving or dismissing feedback.
Do not add it to PR descriptions, commit messages, or text the user explicitly
asked to post verbatim.

## Writing the comment

- Write in the language the repository and the user use for PR discussion. Check
  recent comments and PR descriptions; when that is unclear, use the language
  the user writes to you in. Keep code, identifiers, check names, and quoted
  output verbatim.
- Lead with the conclusion. Then the evidence: the code, the behavior, the
  check, or the reproduction.
- Be concise. No filler, no canned thanks, no status narration.
- Distinguish verified facts from judgment.

Preview the rendered Markdown before posting so quoting and blank lines appear
as intended. After posting, verify that the forge returned the comment or review
URL. Resolve a review thread only after the reply was posted successfully.
