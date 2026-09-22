#!/usr/bin/env bash
# Configure Sublime Text as the desktop editor for text and source files.

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

readonly SUBLIME_BUNDLE_ID=com.sublimetext.4
readonly SUBLIME_NATIVE_DESKTOP=sublime_text.desktop
readonly SUBLIME_FLATPAK_DESKTOP=com.sublimetext.three.desktop
readonly SUBLIME_SETTINGS_SOURCE=${JSH_ROOT}/conf/sublime/Preferences.sublime-settings

install_preferences() {
  local target=$1 source_content target_content
  source_content=$(<"${SUBLIME_SETTINGS_SOURCE}")
  if [[ -r ${target} ]]; then
    target_content=$(<"${target}")
    [[ ${source_content} == "${target_content}" ]] && return 0
  fi
  mkdir -p -- "${target%/*}"
  install -m 0644 "${SUBLIME_SETTINGS_SOURCE}" "${target}"
  jsh::log_success "Sublime Text preferences installed."
}

configure_macos() {
  local content_type extension
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
  )
  local -a extensions=(
    txt text log md markdown mdown mkd rst adoc asciidoc org
    json jsonc json5 jsonl ndjson yaml yml toml ini cfg conf config properties
    env lock xml xsd xsl xslt
    sh bash zsh fish ps1 bat cmd
    c h cc cpp cxx hpp hxx m mm
    py pyi rb pl pm php lua go rs java kt kts scala swift
    js mjs cjs jsx ts mts cts tsx css scss sass less vue svelte
    sql graphql gql proto diff patch
    tf tfvars hcl nix ex exs erl hrl clj cljs edn hs lhs elm zig zon r jl dart
    tex bib
  )

  if ! command -v duti > /dev/null 2>&1; then
    jsh::log_note "Skipping Sublime Text file associations: duti is unavailable."
    return 0
  fi
  if [[ ! -d '/Applications/Sublime Text.app' && ! -d ${HOME}'/Applications/Sublime Text.app' ]]; then
    jsh::log_note "Skipping Sublime Text file associations: Sublime Text is not installed."
    return 0
  fi

  install_preferences "${HOME}/Library/Application Support/Sublime Text/Packages/User/Preferences.sublime-settings"

  local is_current=1 current_handler
  for content_type in "${content_types[@]}"; do
    current_handler=$(duti -d "${content_type}" 2> /dev/null || true)
    if [[ "${current_handler}" != "${SUBLIME_BUNDLE_ID}" ]]; then
      is_current=0
      break
    fi
  done
  if ((is_current)); then
    for extension in txt md py js ts c toml; do
      if ! duti -x "${extension}" 2> /dev/null | grep -Fxq "${SUBLIME_BUNDLE_ID}"; then
        is_current=0
        break
      fi
    done
  fi

  if ((is_current)); then
    jsh::log_note "Sublime Text is already the default macOS text and source editor."
    return 0
  fi

  for content_type in "${content_types[@]}"; do
    if ! duti -s "${SUBLIME_BUNDLE_ID}" "${content_type}" all > /dev/null 2>&1; then
      jsh::log_warn "Skipping unsupported macOS content type: ${content_type}."
    fi
  done
  for extension in "${extensions[@]}"; do
    duti -s "${SUBLIME_BUNDLE_ID}" ".${extension}" all > /dev/null 2>&1 || true
  done
  jsh::log_success "Sublime Text is the default macOS text and source editor."
}

configure_linux() {
  local desktop_id='' desktop_path='' candidate directory mime_type settings_target
  local -i changed=0
  local -a mime_types=(
    text/plain
    text/markdown
    text/x-markdown
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
    jsh::log_note "Skipping Sublime Text file associations: xdg-mime is unavailable."
    return 0
  fi
  for candidate in "${SUBLIME_NATIVE_DESKTOP}" "${SUBLIME_FLATPAK_DESKTOP}"; do
    for directory in \
      "${XDG_DATA_HOME:-${HOME}/.local/share}/applications" \
      "${HOME}/.local/share/flatpak/exports/share/applications" \
      /var/lib/flatpak/exports/share/applications \
      /usr/local/share/applications \
      /usr/share/applications; do
      if [[ -r ${directory}/${candidate} ]]; then
        desktop_id=${candidate}
        desktop_path=${directory}/${candidate}
        break 2
      fi
    done
  done
  if [[ -z ${desktop_path} ]]; then
    jsh::log_note "Skipping Sublime Text file associations: no desktop entry is available."
    return 0
  fi

  case ${desktop_id} in
    "${SUBLIME_FLATPAK_DESKTOP}") settings_target=${HOME}/.var/app/com.sublimetext.three/config/sublime-text/Packages/User/Preferences.sublime-settings ;;
    *) settings_target=${XDG_CONFIG_HOME:-${HOME}/.config}/sublime-text/Packages/User/Preferences.sublime-settings ;;
  esac
  install_preferences "${settings_target}"

  local current_mime_handler
  for mime_type in "${mime_types[@]}"; do
    current_mime_handler=$(xdg-mime query default "${mime_type}" 2> /dev/null || true)
    if [[ "${current_mime_handler}" != "${desktop_id}" ]]; then
      xdg-mime default "${desktop_id}" "${mime_type}"
      changed=1
    fi
  done
  if ((changed)); then
    jsh::log_success "Sublime Text is the default Linux text and source editor."
  else
    jsh::log_note "Sublime Text is already the default Linux text and source editor."
  fi
}

case $(uname -s) in
  Darwin) configure_macos ;;
  Linux) configure_linux ;;
  *) jsh::log_note "Skipping Sublime Text file associations: unsupported platform." ;;
esac
