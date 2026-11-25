{ earshot, runCommand }:
runCommand "earshot-skills-${earshot.version}" { } ''
  mkdir -p "$out"
  cp -R ${earshot.src}/skills/earshot ${earshot.src}/skills/real-sound "$out/"
  chmod -R u+w "$out"
  mkdir -p "$out/earshot/agents" "$out/real-sound/agents"
  cat > "$out/earshot/agents/openai.yaml" <<'YAML'
  interface:
    display_name: "Earshot"
    short_description: "Make sound effects and judge audio by measuring it"
    default_prompt: "Use $earshot to make or judge the sounds for this."
  YAML
  cat > "$out/real-sound/agents/openai.yaml" <<'YAML'
  interface:
    display_name: "Real Sound"
    short_description: "Licensed music, foley, and SFX mixed to picture"
    default_prompt: "Use $real-sound to build the soundtrack for this video."
  YAML
  substituteInPlace "$out/earshot/SKILL.md" \
    --replace-fail 'pip install "earshot @ git+https://github.com/Leonxlnx/earshot"                 # makes sounds: no model, no GPU' \
      '# Nix-managed: earshot with every extra and ffmpeg are already installed; do not use pip.' \
    --replace-fail 'pip install "earshot[listen,mcp] @ git+https://github.com/Leonxlnx/earshot"     # adds listening and the MCP server' "" \
    --replace-fail '/path/to/earshot/.venv/bin/python' '${earshot.pythonEnvironment}/bin/python'
  substituteInPlace "$out/real-sound/SKILL.md" \
    --replace-fail '{{PY}}' '${earshot.pythonEnvironment}/bin/python'
''
