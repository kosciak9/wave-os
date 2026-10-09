// Prepends a model-family base prompt to our custom agents. OpenCode skips its
// built-in per-model prompts for agents that define their own system prompt.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const AGENTS = new Set(["⩀"]);

const FAMILIES = [{ matches: (id) => id.includes("gpt-6"), file: "gpt-6.md" }];

// Prompts live outside plugins/, where OpenCode loads every directory as a plugin.
const directory = join(
  process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"),
  "opencode",
  "model-prompts",
);

const prompts = new Map(
  FAMILIES.map(({ file }) => [file, readFileSync(join(directory, file), "utf8")]),
);

// Mirrors OpenCode's SessionSystemPrompt.render for the tool guidance slot.
function render(prompt, tools) {
  const guidance = [];
  if (tools.includes("shell")) {
    guidance.push(
      "- Prefer dedicated tools over shell commands; fall back to the shell when a tool cannot do what you need.",
      '- Do not chain shell commands with separators like `echo "====";` or `printf \'---\'`; the output becomes noisy in a way that makes the user\'s side of the conversation worse.',
    );
  }
  if (tools.includes("write")) {
    guidance.push(
      "- Use the write tool to create files or completely replace their content. Prefer using the edit tool for targeted changes.",
    );
  }
  if (tools.includes("edit")) {
    guidance.push(
      "- Use the edit tool for targeted changes to existing text files. It replaces the exact text in `oldString` with `newString`, and the values must differ. By default, `oldString` must occur exactly once. If it occurs multiple times, include more surrounding context to make it unique or set `replaceAll` to true to replace every occurrence.",
    );
  }
  return prompt.replace("${OPENCODE_TOOL_GUIDANCE}", guidance.join("\n"));
}

function prepend(event) {
  if (!AGENTS.has(event.agent)) return;
  const id = event.model.id.toLowerCase();
  const family = FAMILIES.find(({ matches }) => matches(id));
  const system = event.system[0];
  if (!family || !system) return;
  const base = render(prompts.get(family.file), Object.keys(event.tools));
  event.system[0] = { ...system, text: `${base}\n\n${system.text}` };
}

export default {
  id: "wave.model-prompts",
  async setup(ctx) {
    for (const name of ["context", "compaction", "generate"]) {
      await ctx.session.hook(name, prepend);
    }
  },
};
