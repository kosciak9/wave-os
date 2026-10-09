# HexDocs

Fetch documentation for the version the project actually uses. Check `mix.lock`
first; hexdocs.pm serves the latest release unless the URL pins a version.

## Prefer Tidewave

If Tidewave MCP is available, prefer its `get_docs` tool: it returns docs for
the exact versions in `mix.lock`.

```
mcp__tidewave__get_docs(module: "Oban.Worker")
```

## HexDocs URLs

Use the runtime's web fetch tool with a focused extraction request.

```
# Library overview
https://hexdocs.pm/{library}
https://hexdocs.pm/{library}/{version}

# Module documentation
https://hexdocs.pm/{library}/{Module}.html
https://hexdocs.pm/{library}/{version}/{Module.Submodule}.html

# Guides and API reference
https://hexdocs.pm/{library}/{guide-name}.html
https://hexdocs.pm/{library}/api-reference.html
```

## Prompt Strategies

```
# For API docs
"Extract all public function docs with @spec and examples"

# For guides
"Extract the complete guide content preserving code examples"

# For troubleshooting
"Extract any troubleshooting sections, common errors, and FAQs"

# For configuration
"Extract configuration options and their defaults"
```

## Iron Laws

1. **NEVER fetch entire HexDocs sites** — always target specific modules or
   guides
2. **Use focused prompts** — generic fetches waste tokens; specify what to
   extract
3. **Prefer Tidewave when available** — exact version match beats generic
   hexdocs.pm
