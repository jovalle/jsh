#!/usr/bin/env bash
# Configure Zed as the desktop editor for text and source files.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

readonly ZED_BUNDLE_ID=dev.zed.Zed
readonly ZED_DESKTOP=dev.zed.Zed.desktop

configure_macos() {
  local content_type extension
  local -a failed_extensions=()
  local -a content_types=(
    public.text
    public.plain-text
    public.source-code
    public.script
    public.shell-script
    net.daringfireball.markdown
    public.json
    public.yaml
    public.xml
    com.apple.ical.ics
  )
  local -a extensions=(
    txt text log md markdown mdown mkd rst adoc asciidoc org
    json jsonc json5 jsonl ndjson yaml yml toml ini cfg conf config properties
    env lock ics xml xsd xsl xslt
    sh bash zsh fish ps1 bat cmd
    c h cc cpp cxx hpp hxx m mm
    py pyi rb pl pm php lua go rs java kt kts scala swift
    js mjs cjs jsx ts mts cts tsx css scss sass less vue svelte
    sql graphql gql proto diff patch
    tf tfvars hcl nix ex exs erl hrl clj cljs edn hs lhs elm zig zon r jl dart
    tex bib
  )

  if ! command -v duti > /dev/null 2>&1; then
    jsh_note "Skipping Zed file associations: duti is unavailable."
    return 0
  fi
  if [[ ! -d /Applications/Zed.app && ! -d ${HOME}/Applications/Zed.app ]]; then
    jsh_note "Skipping Zed file associations: Zed is not installed."
    return 0
  fi

  for content_type in "${content_types[@]}"; do
    duti -s "${ZED_BUNDLE_ID}" "${content_type}" all
  done
  for extension in "${extensions[@]}"; do
    duti -s "${ZED_BUNDLE_ID}" ".${extension}" all 2> /dev/null ||
      failed_extensions+=("${extension}")
  done
  ((${#failed_extensions[@]} == 0)) ||
    jsh_note "LaunchServices skipped ${#failed_extensions[@]} extensions Zed does not declare."
  jsh_success "Zed is the default macOS text and source editor."
}

configure_linux() {
  local desktop_path='' directory mime_type
  local -a mime_types=(
    text/plain
    text/markdown
    text/x-markdown
    text/calendar
    application/json
    application/ld+json
    application/toml
    application/x-toml
    application/x-yaml
    text/yaml
    application/xml
    text/xml
    text/x-shellscript
    application/x-shellscript
    text/x-csrc
    text/x-chdr
    text/x-c++src
    text/x-c++hdr
    text/x-python
    text/x-ruby
    text/x-perl
    text/x-php
    text/javascript
    application/javascript
    text/css
    text/x-scss
    text/x-sass
    text/x-less
    text/x-java
    text/x-kotlin
    text/x-go
    text/x-rust
    text/x-lua
    text/x-sql
    text/x-diff
    text/x-patch
  )

  if ! command -v xdg-mime > /dev/null 2>&1; then
    jsh_note "Skipping Zed file associations: xdg-mime is unavailable."
    return 0
  fi
  for directory in \
    "${XDG_DATA_HOME:-${HOME}/.local/share}/applications" \
    "${HOME}/.local/share/flatpak/exports/share/applications" \
    /var/lib/flatpak/exports/share/applications \
    /usr/local/share/applications \
    /usr/share/applications; do
    if [[ -r ${directory}/${ZED_DESKTOP} ]]; then
      desktop_path=${directory}/${ZED_DESKTOP}
      break
    fi
  done
  if [[ -z ${desktop_path} ]]; then
    jsh_note "Skipping Zed file associations: ${ZED_DESKTOP} is unavailable."
    return 0
  fi

  for mime_type in "${mime_types[@]}"; do
    xdg-mime default "${ZED_DESKTOP}" "${mime_type}"
  done
  jsh_success "Zed is the default Linux text and source editor."
}

case $(uname -s) in
  Darwin) configure_macos ;;
  Linux) configure_linux ;;
  *) jsh_note "Skipping Zed file associations: unsupported platform." ;;
esac
