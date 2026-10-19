#compdef earshot

local -a common
common=(
  '--json[Print the full result as JSON]'
  '--out[Also write the JSON result to this file]:file:_files'
  '--threads[CPU threads]:threads:'
  '(-h --help)'{-h,--help}'[Show help]'
)

_arguments -C \
  '--threads[CPU threads]:threads:' \
  '(-h --help)'{-h,--help}'[Show help]' \
  '1:command:(describe match rank find compare ab realness timeline sheet critique profile forge fit gallery measure llm mcp doctor)' \
  '*::arg:->args'

case $state in
  args)
    case $words[1] in
      fit)
        _arguments \
          $common \
          '(-o --output)'{-o,--output}'[Recipe path]:recipe:_files -g "*.py"' \
          '--dir[Output folder when -o is not given]:dir:_directories' \
          '--kind[Model kind]:kind:(auto modal spectral sines hybrid)' \
          '--layers[Hybrid layers]:layers:' \
          '--render[Resynthesis WAV path]:wav:_files' \
          '--report[Also write a quality report]' \
          '--clap[Let CLAP cosine take part in choosing the fit]' \
          '--describe[Describe the original and the resynthesis]' \
          '--target[Critic description for the recipe]:description:' \
          '--seed[Random seed]:seed:' \
          '--fast[Cheaper fitter settings]' \
          '--morph[Fit two recordings and write a morph recipe]:a:_files:b:_files' \
          '--amount[Morph amount from 0 (A) to 1 (B)]:amount:' \
          '--forge[Search variations of a fitted recipe]:recipe:_files -g "*.py"' \
          '--budget[Candidates the critic scores]:budget:' \
          '--pop[Population per generation]:pop:' \
          '--variants[Diverse sounds to keep]:variants:' \
          '--refset[Critic refset category]:category:' \
          '--quiet[Do not print the candidates while fitting]' \
          '1:file:_files'
        ;;
      gallery)
        _arguments \
          '-o[Output HTML file]:html:_files -g "*.html"' \
          '--results[Result JSON files]:json:_files' \
          '--refs[Reference sounds]:refs:_directories' \
          '--compare[Versions as rows]:label glob:' \
          '--sub[Subfolder per category]:sub:' \
          '--alias[Show category OLD as NEW]:alias:' \
          '--embed[Embed audio and images as base64]' \
          '--embed-compressed[Embed small lossy previews]' \
          '--embed-codec[Codec for embedded previews]:codec:(flac wav mp3 opus vorbis)' \
          '--kbps[Bit rate of lossy previews]:kbps:' \
          '--max-mb[Note when an embedded page is larger]:mb:' \
          '--title[Page title]:title:' \
          '--max-refs[A/B references per category]:count:' \
          '(-h --help)'{-h,--help}'[Show help]' \
          '1:folder:_directories'
        ;;
      *)
        _arguments $common '*:file:_files'
        ;;
    esac
    ;;
esac
