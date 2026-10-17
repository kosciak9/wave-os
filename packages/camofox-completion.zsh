#compdef camofox

local context state state_descr line
local -a commands=(
  'health:Check browser health'
  'tabs:List tabs'
  'open:Open a URL in a new tab'
  'navigate:Navigate the current tab'
  'snapshot:Read an accessibility snapshot'
  'click:Click a snapshot ref or selector'
  'type:Type text'
  'press:Press a key'
  'scroll:Scroll the current tab'
  'eval:Evaluate JavaScript'
  'screenshot:Capture a screenshot'
  'close:Close the current tab'
  'api:Call a browser API endpoint'
)

_arguments -C \
  '(-b --base-url)'{-b,--base-url}'[Browser server URL]:URL:_urls' \
  '(--user --user-id)'{--user,--user-id}'[User ID]:user:' \
  '(--session --session-key)'{--session,--session-key}'[Session key]:session:' \
  '--tab[Tab ID]:tab:' \
  '--timeout[Request timeout]:seconds:' \
  '(-o --output)'{-o,--output}'[Write response to a file]:file:_files' \
  '(-h --help)'{-h,--help}'[Show help]' \
  '1:command:->command' \
  '*::argument:->arguments'

case $state in
  command) _describe 'command' commands ;;
  arguments)
    case $words[1] in
      open|navigate) _arguments '--tab[Tab ID]:tab:' '1:URL:_urls' ;;
      click) _arguments '--tab[Tab ID]:tab:' '--selector[Use a CSS selector]' '1:target:' ;;
      type) _arguments '--tab[Tab ID]:tab:' '--ref[Snapshot ref]:ref:' '--selector[CSS selector]:selector:' '1:text:' ;;
      press) _arguments '--tab[Tab ID]:tab:' '1:key:' ;;
      scroll) _arguments '--tab[Tab ID]:tab:' '--amount[Scroll amount]:amount:' '1:direction:(up down left right)' ;;
      eval) _arguments '--tab[Tab ID]:tab:' '1:JavaScript expression:' ;;
      screenshot) _arguments '--tab[Tab ID]:tab:' '--full-page[Capture the full page]' ;;
      api) _arguments '--tab[Tab ID]:tab:' '1:method:(GET POST PUT PATCH DELETE HEAD OPTIONS)' '2:path:' '3:JSON body:' ;;
      *) _arguments '--tab[Tab ID]:tab:' ;;
    esac
    ;;
esac
