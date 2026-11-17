#!/usr/bin/env bash
# Open Markdown in MacDown 3000 and install the macOS SACD/DSD decoder for foobar2000.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh" "$@"
jsh::packages apps
[[ $(uname -s) == Darwin ]] || jsh::skip "app configuration: macOS only"
if [[ -d /Applications/MacDown\ 3000.app ]]; then
  jsh::step check "MacDown 3000 document handlers"
  # Setting a default app through LaunchServices asks the user to confirm each type, so
  # write the handlers to its preferences and restart the per-user lsd, which reads them.
  domain=com.apple.LaunchServices/com.apple.launchservices.secure
  defaults export "${domain}" "${APP_TMP}/handlers.plist"
  handlers=$(plutil -extract LSHandlers json -o - "${APP_TMP}/handlers.plist" 2>/dev/null) || handlers='[]'
  # .md and .markdown share a declared type; other extensions only have dynamic types,
  # which LaunchServices records by extension.
  handlers=$(jq -c --arg bundle app.macdown.macdown3000 '
    def key: .LSHandlerContentType //
      if .LSHandlerContentTagClass == "public.filename-extension" then "." + .LSHandlerContentTag else null end;
    def mine: .LSHandlerRoleAll == $bundle and ([keys[] | select(startswith("LSHandlerRole"))] == ["LSHandlerRoleAll"]);
    . as $handlers
    | [$ARGS.positional[] | . as $target
        | select([$handlers[] | select(key == $target)] | length == 0 or any(.[]; mine | not))] as $stale
    | {stale: $stale,
       handlers: (map(select(key as $key | $stale | index([$key]) | not)) + [$stale[]
         | {LSHandlerRoleAll: $bundle, LSHandlerPreferredVersions: {LSHandlerRoleAll: "-"}}
           + if startswith(".") then {LSHandlerContentTag: .[1:], LSHandlerContentTagClass: "public.filename-extension"}
             else {LSHandlerContentType: .} end])}' \
    --args net.daringfireball.markdown .mdx .mdown .mkd .mkdn .mdwn .mdtext .mdtxt <<<"${handlers}")
  stale=$(jq -r '.stale | join(" ")' <<<"${handlers}")
  if [[ -z ${stale} ]]; then
    jsh::ok "MacDown 3000 opens .md .markdown .mdx .mdown .mkd .mkdn .mdwn .mdtext .mdtxt"
  else
    plutil -replace LSHandlers -json "$(jq -c .handlers <<<"${handlers}")" "${APP_TMP}/handlers.plist"
    jsh::run defaults import "${domain}" "${APP_TMP}/handlers.plist"
    # launchd restarts lsd on demand; kickstart is refused under System Integrity Protection.
    lsd=$(launchctl list | awk '$3 == "com.apple.lsd" { print $1 }')
    [[ ! ${lsd} =~ ^[0-9]+$ ]] || jsh::run kill "${lsd}"
    formats=${stale/net.daringfireball.markdown/.md .markdown}
    jsh::changed "MacDown 3000 opens ${formats}" "${formats} do not open in MacDown 3000"
  fi
fi
components=${HOME}/Library/foobar2000-v2/user-components
name=foo_input_sacd
target=${components}/${name}.component
state=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/foobar2000/decoder
# The SACD decoder replaced the standalone DSD decoder; both register the same formats.
retired=("${components}/foo_input_udsd.component" "${components}/foo_input_udsd")
jsh::step check "foobar2000 SACD decoder"
if [[ ! -d /Applications/foobar2000.app && ! -d ${components%/*} ]]; then
  jsh::skip "foobar2000 decoder: foobar2000 is not installed"
fi
existing=0
for path in "${target}" "${retired[@]}"; do [[ ! -e ${path} ]] || existing=1; done
if ((existing)) && [[ ${JSH_UPDATE:-0} != 1 ]]; then
  jsh::ok "foobar2000 decoder is installed"
  exit 0
fi
((existing)) || [[ ${JSH_UPDATE:-0} != 1 ]] ||
  jsh::skip "foobar2000 decoder update: no decoder is installed"
installed=''
[[ ! -e ${target} || ! -f ${state} ]] || installed=$(<"${state}")
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  if ((existing)); then
    jsh::info "foobar2000 decoder update is unchecked in preview"
  else
    jsh::added "foobar2000 SACD decoder installed" "foobar2000 SACD decoder is missing"
  fi
  exit 0
fi
jsh::download "https://sourceforge.net/projects/sacddecoder/rss?path=/${name}" "${APP_TMP}/releases.xml"
release=$(awk -v name="${name}" '
  /<title>/ {
    file = ""
    if (match($0, name "-[0-9]+(\\.[0-9]+)+\\.zip")) file = substr($0, RSTART, RLENGTH)
  }
  file != "" && match($0, /<media:hash algo="md5">[0-9a-f]+</) {
    print file, substr($0, RSTART + 23, RLENGTH - 24)
    file = ""
  }' "${APP_TMP}/releases.xml" | sort -V | tail -n 1)
version=${release%% *}
version=${version#"${name}-"}
version=${version%.zip}
digest=${release##* }
[[ ${version} =~ ^[0-9]+(\.[0-9]+)+$ && ${digest} =~ ^[0-9a-f]{32}$ ]] || {
  jsh::notice 'No foobar2000 decoder release found'
  exit 1
}
if [[ ${installed} == "${version}" ]]; then
  jsh::ok "foobar2000 SACD decoder is ${version}"
  exit 0
fi
jsh::download "https://downloads.sourceforge.net/project/sacddecoder/${name}/${name}-${version}.zip" "${APP_TMP}/decoder.zip"
# SourceForge publishes only MD5 digests, served over HTTPS in its release feed.
[[ $(md5 -q "${APP_TMP}/decoder.zip") == "${digest}" ]] || {
  jsh::notice "checksum mismatch: ${name}-${version}.zip"
  exit 1
}
unzip -p "${APP_TMP}/decoder.zip" "${name}.fb2k-component" >"${APP_TMP}/component.zip"
prefix=mac/${name}.component/
jsh::status "decoder archive"
unzip -Z1 "${APP_TMP}/component.zip" >"${APP_TMP}/entries"
grep -Fx "${prefix}Contents/Info.plist" "${APP_TMP}/entries" >/dev/null
grep -Fx "${prefix}Contents/MacOS/${name}" "${APP_TMP}/entries" >/dev/null
while IFS= read -r entry; do
  [[ ${entry} == "${prefix}"* && ${entry} != */ ]] || continue
  relative=${entry#"${prefix}"}
  case /${relative}/ in *'/../'* | *'/./'* | *'//'*)
    jsh::notice 'invalid decoder archive path'
    exit 1
    ;;
  esac
  mkdir -p -- "${APP_TMP}/component/${relative%/*}"
  unzip -p "${APP_TMP}/component.zip" "${entry}" >"${APP_TMP}/component/${relative}"
  chmod 644 "${APP_TMP}/component/${relative}"
done <"${APP_TMP}/entries"
chmod 755 "${APP_TMP}/component/Contents/MacOS/${name}"
APP_LAUNCH=(open -a foobar2000)
APP_LIVE=1
install_component() {
  local path backup
  backup=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$/foobar2000
  mkdir -p -- "${components}"
  for path in "${retired[@]}" "${target}"; do
    [[ -e ${path} ]] || continue
    mkdir -p -- "${backup}"
    mv -- "${path}" "${backup}/"
    [[ ${path} == "${target}" ]] ||
      jsh::removed "${path##*/} removed" \
        "${path##*/} is replaced by the SACD decoder"
  done
  mv -- "${APP_TMP}/component" "${target}"
  mkdir -p -- "${state%/*}"
  printf '%s\n' "${version}" >"${state}"
  if [[ -n ${installed} ]]; then
    jsh::changed "foobar2000 SACD decoder set ${version}" "foobar2000 SACD decoder is ${installed}"
  else
    jsh::added "foobar2000 SACD decoder ${version} installed" "foobar2000 SACD decoder is missing"
  fi
}
app::with_closed foobar2000 foobar2000 install_component
