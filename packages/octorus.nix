{
  octorus,
  installShellFiles,
  writeText,
}:

octorus.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh ${writeText "_or" ''
      #compdef or

      local context state state_descr line
      typeset -A opt_args
      local -a commands=(
        'init:Initialize configuration' 'clean:Remove AI Rally session data'
        'local-comments:Show saved local comments' 'update-local-comment:Resolve or reopen local comments'
        'update:Update octorus' 'migrate:Migrate configuration' 'help:Show command help'
      )

      _arguments -C \
        '(-r --repo)'{-r,--repo}'[GitHub repository]:owner/repository:' \
        '(--local -p --pr)'{-p,--pr}'[Open pull requests]::number:' \
        '(--pr -p --issue -i)--local[Show local changes]' \
        '(--local -i --issue)'{-i,--issue}'[Open issues]::number:' \
        '--ai-rally[Start AI Rally]' \
        '--review-only[Use AI review-only mode]::enabled:(true false)' \
        '--git-ops[Open Git operations]' \
        '--browse[Open repository browser]' \
        '--auto-focus[Follow changed files]' \
        '--working-dir[Working directory]:directory:_directories' \
        '--accept-local-overrides[Accept local AI configuration overrides]' \
        '--output[Write JSON results]:file:_files' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-V --version)'{-V,--version}'[Show version]' \
        '1:command:->command' \
        '*::argument:->argument'

      case $state in
        command) _describe 'command' commands ;;
        argument)
          case $line[1] in
            init)
              _arguments '--force[Overwrite existing files]' '--local[Use project-local configuration]'
              ;;
            migrate)
              _arguments '--force[Overwrite existing files]' '--local[Use project-local configuration]' \
                '--dry-run[Show migration changes without applying]'
              ;;
            local-comments)
              _arguments '(-r --repo)'{-r,--repo}'[GitHub repository]:owner/repository:' \
                '--working-dir[Working directory]:directory:_directories' \
                '(-l --limit)'{-l,--limit}'[Maximum number of comments]:limit:' \
                '--json[Print JSON]' '--all[Include resolved comments]' \
                '--resolved[Only resolved comments]' '--purge[Delete local comments]'
              ;;
            update-local-comment)
              _arguments '(-r --repo)'{-r,--repo}'[GitHub repository]:owner/repository:' \
                '--working-dir[Working directory]:directory:_directories' \
                '--resolve[Resolve comments]' '--reopen[Reopen comments]' '*:comment ID:'
              ;;
            help) _describe 'command' commands ;;
          esac
          ;;
      esac
    ''}
  '';
})
