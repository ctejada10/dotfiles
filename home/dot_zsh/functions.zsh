function dps() {
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' \
    | awk -F'\t' -v OFS='\t' '
        BEGIN { print "NAMES\tSTATUS\tPORTS" }
        { gsub(/ [0-9]+.*/, "", $2); gsub(/[0-9.]+:/, "", $3); gsub(/\/[a-z]+/, "", $3); print }
      ' \
    | column -t \
    | cut -c-59
}

function extract {
  echo Extracting $1 ...
  if [ -f $1 ] ; then
      case $1 in
          *.tar.bz2)   tar xjf $1  ;;
          *.tar.gz)    tar xzf $1  ;;
          *.bz2)       bunzip2 $1  ;;
          *.rar)       unrar x $1    ;;
          *.gz)        gunzip $1   ;;
          *.tar)       tar xf $1   ;;
          *.tbz2)      tar xjf $1  ;;
          *.tgz)       tar xzf $1  ;;
          *.zip)       unzip $1   ;;
          *.Z)         uncompress $1  ;;
          *.7z)        7z x $1  ;;
          *)        echo "'$1' cannot be extracted via extract()" ;;
      esac
  else
      echo "'$1' is not a valid file"
  fi
}

function trash () {
  # Not "path": in zsh that is PATH as an array, so a local one empties PATH.
  local file
  for file in "$@"; do
    # ignore any arguments
    if [[ "$file" = -* ]]; then :
    else
      # A trailing slash would leave no name, and the item would go to the
      # Trash as just the time.
      while [[ $file == ?*/ ]]; do file=${file%/}; done
      local dst=${file##*/}
      # append the time if necessary
      while [ -e ~/.Trash/"$dst" ]; do
        dst="$dst "$(date +%H-%M-%S)
      done
      /bin/mv "$file" ~/.Trash/"$dst"
    fi
  done
}
