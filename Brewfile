# One Brewfile for both Macs. brew bundle reads it as Ruby, so each role's
# block installs only on that role. Homebrew passes through only HOMEBREW_*
# variables, so the role arrives as HOMEBREW_TILDE_ROLE, which chezmoi's
# install script and the shell both set. With no role the file refuses to
# load rather than install everything.
#
# Nothing here is ever uninstalled automatically: leaving an entry out only
# stops new machines from getting it.

role = ENV.fetch("HOMEBREW_TILDE_ROLE")

# Both Macs ####################################################################

brew "age"
brew "bat"
brew "chezmoi"
brew "coreutils"
brew "eza"
brew "fzf"
brew "gh"
brew "git"
brew "git-lfs"
brew "jq"
brew "mas"
brew "node"
brew "sops"
brew "tmux"
brew "uv"
brew "zoxide"

cask "1password"
cask "1password-cli"
cask "dropbox"
cask "ghostty"
cask "font-libron"
cask "obsidian"
cask "tailscale-app"

# The laptop ###################################################################

if role == "laptop"
  tap "thedavidweng/tap"

  brew "btop"
  brew "bun"
  brew "ente-cli"
  brew "exiftool"
  brew "ffmpeg"
  brew "grep"
  brew "imagemagick"
  brew "mole"
  # The playbook's check of what each server answers on.
  brew "nmap"
  brew "p7zip"
  brew "pandoc"
  brew "poppler"
  # ai-job-search needs Python 3.10 or later, and macOS's own python3 is 3.9.
  brew "python@3.14"
  brew "rclone"
  brew "rmlint"
  brew "rsync"

  cask "adguard"
  cask "adobe-creative-cloud"
  cask "airbuddy"
  cask "aldente"
  cask "alt-tab"
  cask "bambu-studio"
  cask "beeper"
  cask "claude"
  cask "cleanshot"
  cask "devonthink"
  cask "ente-auth"
  cask "fantastical"
  cask "freedom"
  cask "google-chrome"
  cask "hazel"
  cask "iina"
  cask "latest"
  cask "logi-options+"
  cask "lunar"
  cask "mactex-no-gui"
  cask "raycast"
  cask "rectangle-pro"
  cask "slack"
  cask "t3-code"
  cask "thebrowsercompany-dia"
  cask "thedavidweng/tap/monarchmoney-cli", trusted: true
  cask "todoist-app"
  cask "visual-studio-code"
  cask "zoom"
  cask "zotero"

  cask "font-fira-code"
  cask "font-fira-code-nerd-font"
  cask "font-hack-nerd-font"
  cask "font-iosevka"
  cask "font-jetbrains-mono"
  cask "font-junction"
  cask "font-latin-modern"
  cask "font-open-sans"
  cask "font-raleway"
  cask "font-roboto"
  cask "font-source-code-pro"
  cask "font-source-code-pro-for-powerline"

  # Paid apps have to be bought in the App Store first; mas can't buy them.
  # Signed out of the App Store, mas opens the sign-in sheet and waits on it
  # for good, so the setup script leaves these out (HOMEBREW_TILDE_MAS=0)
  # until the App Store is signed in. `brew bundle` by hand includes them.
  unless ENV["HOMEBREW_TILDE_MAS"] == "0"
    mas "1Password for Safari", id: 1569813296
    mas "Actions", id: 1586435171
    mas "CardPointers", id: 1472875808
    mas "DaisyDisk", id: 411643860
    mas "Data Jar", id: 1453273600
    mas "Flighty", id: 1358823008
    mas "Foodnoms", id: 1479461686
    mas "GoodLinks", id: 1474335294
    mas "Infuse", id: 1136220934
    mas "Monarch Money Tweaks", id: 6753774259
    mas "No Youtube Shorts", id: 6502996298
    mas "Numbers", id: 361304891
    mas "OverPicture", id: 1188020834
    mas "Pages", id: 361309726
    mas "Parcel", id: 375589283
    mas "Play", id: 1596506190
    mas "Raycast Companion", id: 6738274497
    mas "Refined GitHub", id: 1519867270
    mas "Shortery", id: 1594183810
    mas "Sink It", id: 6449873635
    mas "Sleeve", id: 1606145041
    mas "SponsorBlock", id: 1573461917
    mas "Timery", id: 1425368544
  end

  vscode "james-yu.latex-workshop"
  vscode "ms-vscode-remote.remote-ssh"
  vscode "ms-vscode-remote.remote-ssh-edit"
  vscode "ms-vscode.remote-explorer"
  vscode "streetsidesoftware.code-spell-checker"
  vscode "supperchong.pretty-json"
  vscode "teabyii.ayu"
  vscode "vscodevim.vim"
  vscode "yzhang.markdown-all-in-one"
end

# The agent mini ###############################################################
#
# Where all development happens. No Docker Desktop and no Claude desktop app:
# it holds as little as the agents need. Its Dropbox syncs only the
# repositories folder (Selective Sync, set by hand).

if role == "agent-mini"
  tap "hudochenkov/sshpass"

  # Containers run in Colima's Linux VM; the docker CLI finds Compose and
  # Buildx through the links in ~/.docker/cli-plugins.
  brew "colima"
  brew "docker"
  brew "docker-buildx"
  brew "docker-compose"
  brew "git-flow"
  # This repo's pre-commit hook and tests. It is edited here, like every
  # other repo; the laptop only pulls.
  brew "gitleaks"
  brew "go"
  brew "herdr"
  brew "shellcheck"
  # Húrin's SSH helpers call it.
  brew "hudochenkov/sshpass/sshpass", trusted: true

  cask "openscad@snapshot"
end
