{
  writeShellApplication,
  curl,
  jq,
}:
# Prints the free models OpenCode Zen currently serves, grouped by the wire
# protocol the gateway must use for each:
#   {"zen": {"chat": {"<id>": "<name>"}, "responses": {}, "messages": {}}}
# The live /models endpoint lists what is served; models.dev adds names and the
# protocol, falling back to the Go catalog when Zen lacks a model.
# Models absent from both default to chat completions, and
# Gemini models are skipped because the gateway has no Gemini upstream.
writeShellApplication {
  name = "opencode-models";
  runtimeInputs = [
    curl
    jq
  ];
  text = ''
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    fetch() {
      curl --fail --silent --show-error --location --max-time 20 --retry 2 \
        --output "$work/$1.json" "$2"
    }
    fetch zen https://opencode.ai/zen/v1/models
    fetch catalog https://models.dev/api.json
    jq --null-input \
      --slurpfile zen "$work/zen.json" \
      --slurpfile catalog "$work/catalog.json" '
      def protocol:
        if . == "@ai-sdk/openai" then "responses"
        elif . == "@ai-sdk/anthropic" then "messages"
        elif . == "@ai-sdk/google" then null
        else "chat" end;
      def group($live; $known; $other):
        reduce ($live.data[].id) as $id ({chat: {}, responses: {}, messages: {}};
          ($known[$id] // $other[$id] // {}) as $model |
          ($model.provider.npm // "" | protocol) as $protocol |
          if $protocol != null and (($id | endswith("-free")) or
            ($model.cost.input == 0 and $model.cost.output == 0)) then
            .[$protocol][$id] = ($model.name // $id)
          else . end);
      def ids: [.data[]?.id | strings] | length > 0;
      $zen[0] as $zen | $catalog[0] as $catalog |
      if ($zen | ids) and ($catalog.opencode.models | type == "object") then
        {zen: group($zen; $catalog.opencode.models; $catalog["opencode-go"].models // {})}
      else error("unexpected model list shape") end
    '
  '';
}
