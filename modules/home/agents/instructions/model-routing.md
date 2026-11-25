## Subagent model routing

- Choose the lowest class that fits the work. Within a class, take Morph's Ultra
  models (DeepSeek V4.1 Flash, Kimi K3.1 Pro) first: the plan serves them
  without a token charge. Then use the rest of the class; the classes are a
  menu, not a sequence to run every task through. Outside T3, choose from the
  native catalog.

  | Class   | Models                                                                                                                                      | Effort                  | Work                                                                                                                                                   |
  | ------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
  | Light   | DeepSeek V4.1 Flash on Morph first; then Grok 4.7 on x-ai; GPT-6 Luna, Haiku 5.5, and other cheap models T3 currently offers, such as Flint | low                     | Cheap, bounded verification; focused exploration, extraction, classification and log triage. Not final judgment about correctness, security or design. |
  | Worker  | Kimi K3.1 Pro on Morph first; Sonnet 5.5; GPT-6.1 Sol only for code review                                                                  | medium; high for review | Substantial implementation, technical investigation and code review.                                                                                   |
  | Main    | Opus 5.5                                                                                                                                    | high, no fast mode      | UI/visual/design critique, difficult architectural judgment and high-risk or subtle analysis.                                                          |
  | Hardest | Fable 5.2, GPT-6 Astra                                                                                                                      | high                    | Rarely: exceptionally difficult, open-ended or long-horizon work when Opus is demonstrably insufficient. Not a routine second opinion.                 |

- Morph's models run on T3's `opencode` provider: DeepSeek V4.1 Flash as
  `cliproxy/morph/dsv41flash`, Kimi K3.1 Pro as `cliproxy/morph/kimik31`; Grok
  4.7 runs there as `cliproxy/grok-4.7`, on x-ai's daily credits that are
  already paid.
- Ultra limits Kimi to about 24k uncached input tokens per minute. Run one Kimi
  delegate at a time, and give parallel or large-context Worker tasks to Sonnet,
  or reviews to Sol; treat a Kimi per-minute `429` as a capacity failure.
- Delegate code review to the Worker class, Kimi K3.1 Pro first (the `sol-loop`
  skill sets the order). Add an Opus pass for high-risk/architectural concerns,
  not as a routine replacement.
- Always use Opus for frontend visual and design critique, even when a Worker
  wrote or reviewed the code. Functional code review remains the Worker's job.
  Escalate to Fable when Opus cannot resolve a particularly difficult design
  problem.
- Escalate one class only for a concrete failure or unresolved risk.
