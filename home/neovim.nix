{
  lib,
  pkgs,
  ...
}:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    initLua = builtins.readFile ./nvim/init.lua;
    plugins = with pkgs.vimPlugins; [
      kanagawa-nvim
      hardtime-nvim
      nui-nvim
      gitsigns-nvim
      diffview-plus-nvim
      neogit
      nvim-ts-context-commentstring
      vim-matchup
      nvim-surround
      mini-icons
      mini-starter
      plenary-nvim
      telescope-nvim
      telescope-fzf-native-nvim
      nvim-lspconfig
      conform-nvim
      tiny-inline-diagnostic-nvim
      copilot-lsp
      copilot-lua
      (nvim-treesitter.withPlugins (
        parsers: with parsers; [
          markdown
          markdown_inline
          tsx
          javascript
          typescript
          json
          graphql
          python
          yaml
          html
          scss
          lua
          elixir
          heex
        ]
      ))
      oil-nvim
    ];
    extraPackages =
      with pkgs;
      [
        git
        ripgrep
        fd
        nodejs
        curl

        lua-language-server
        harper
        vscode-langservers-extracted
        yaml-language-server
        beamPackages.expert
        typescript-go
        deno
        biome
        oxlint
        tailwindcss-language-server

        stylua
        ruff
        isort
        black
        oxfmt
        prettierd
        prettier
        markdownlint-cli
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wl-clipboard ];
  };

  xdg.configFile = {
    "nvim/lsp".source = ./nvim/lsp;
    "nvim/lua".source = ./nvim/lua;
    "nvim/queries".source = ./nvim/queries;
  };
}
