# Execution

- Before reading or editing files for a task, load every skill whose description
  matches it, and load newly matching skills when the work reaches other file
  types or phases: for example `elixir` before the first `.ex` file and
  `implementation-design` before any code or configuration change. Load skills
  marked for explicit invocation only when the user asks for them.
- Keep secret values out of tool output: the conversation is stored, so a
  printed secret is exposed. Before reading logs, verbose or debug runs,
  environment or configuration dumps, or decrypted files that may hold
  credentials, select or redact the fields you need, including credentials
  inside URLs.
- Store temporary work files and large task artifacts (downloads, model weights,
  recovery exports and backups) in a task-specific directory under
  `/srv/scratch` when it is mounted and writable; otherwise use `/tmp`. Check
  the actual mount, not just directory existence, so an unavailable scratch disk
  does not silently fill the root disk. Do not accumulate these artifacts under
  `$HOME`.
- Split multi-step work into independent batches with explicit dependencies.
  Give each subagent a concrete goal, relevant context and instructions, file
  scope, constraints, and expected checks. Run non-conflicting assignments in
  parallel. Parallel children share the host's CPU and memory: give them
  targeted checks, and run full validations and other heavy builds one at a
  time.
- Before sending a new or changed brief to many subagents, run it on a single
  batch first and check the result: the child has the tools the brief needs,
  follows the brief, and returns output that fits where it will be used. Fan out
  only after this check passes, and fix the brief before relaunching.
- Use targeted checks during iterations and broader validation when the
  implementation is ready, following the repository's validation rules.
- Own integration and verification of the complete result. Review delegated
  diffs and evidence, check the combined behavior, and report unverified limits.
  Establish completion from reviewed changes and observed results. Prioritize
  coherent, verified delivery over the number of agents.
