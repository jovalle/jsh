#!/usr/bin/env bash
# Install the verified macOS DSD decoder for foobar2000.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages apps
jsh::activity 'Checking foobar2000 decoder'
[[ $(uname -s) == Darwin ]] || exit 0
components=${HOME}/Library/foobar2000-v2/user-components
target=${components}/foo_input_udsd.component
if [[ -e ${target} || -e ${components}/foo_input_udsd ]]; then
  jsh::current
  exit 0
fi
if [[ ! -d /Applications/foobar2000.app && ! -d ${components%/*} ]]; then exit 0; fi
APP_LAUNCH=(open -a foobar2000)
install_component() {
  if [[ ${JSH_DRY_RUN:-0} != 1 ]]; then
    mkdir -p -- "${components}"
    mv -- "${APP_TMP}/component" "${target}"
  fi
  jsh::added 'foobar2000 DSD decoder'
}
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  app::with_closed foobar2000 foobar2000 install_component
  exit
fi
url=https://downloads.sourceforge.net/project/sacddecoder/macOS%20%2BWindows/foo_input_udsd/foo_input_udsd-2.0.24.zip
app::download "${url}" "${APP_TMP}/decoder.zip" 6dca1ebc7148cbdded9bfc10f8a1c31ebb13b8942be4884a9af539dbf617b7bf
unzip -p "${APP_TMP}/decoder.zip" foo_input_udsd.fb2k-component >"${APP_TMP}/component.zip"
prefix=mac/foo_input_udsd.component/
jsh::activity 'Validating foobar2000 decoder archive'
unzip -Z1 "${APP_TMP}/component.zip" >"${APP_TMP}/entries"
grep -Fx "${prefix}Contents/Info.plist" "${APP_TMP}/entries" >/dev/null
grep -Fx "${prefix}Contents/MacOS/foo_input_udsd" "${APP_TMP}/entries" >/dev/null
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
chmod 755 "${APP_TMP}/component/Contents/MacOS/foo_input_udsd"
app::with_closed foobar2000 foobar2000 install_component
