#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
  printf 'Usage: %s HEADER...\n' "${0##*/}" >&2
  exit 2
fi

header=$*

printf '\n'
JSH_BANNER_HEADER=${header} awk '
  function spaces(width, result) {
    result = ""
    while (length(result) < width) result = result " "
    return result
  }

  NR > 1 { print previous }
  { previous = $0 }

  END {
    line_width = length(previous)
    gap_start = 0
    gap_width = 0
    run_start = 0

    for (column = 1; column <= line_width; column++) {
      if (substr(previous, column, 1) == " ") {
        if (run_start == 0) run_start = column
      } else {
        run_width = column - run_start
        if (run_start > 1 && run_width > gap_width) {
          gap_start = run_start
          gap_width = run_width
        }
        run_start = 0
      }
    }

    text = ENVIRON["JSH_BANNER_HEADER"]
    text_width = gap_width - 2
    if (length(text) > text_width) {
      text = substr(text, 1, text_width - 3) "..."
    }

    left_width = int((gap_width - length(text)) / 2)
    right_width = gap_width - length(text) - left_width
    print substr(previous, 1, gap_start - 1) spaces(left_width) text \
      spaces(right_width) substr(previous, gap_start + gap_width)
  }
' <<'BANNER'
   :%@@@@@@@@@#*#@%-              +-:##
  :#    -#%%+=#:@#                :@@%:
   %@@     +@++@@-            *-   @@%:
          *@%:%@@:    :%@@@@*%+  *@@@%::*@@#
     -###%@@+:%@@:  :%@#:--=%:    -@@@#: #@@=
       :#@@@+:%@@:  :%@#  -#-     -@@%   *@@=
      *#:#@@+:%@@:  :%@@@@@@@@*   -@@%   *@@=
       -#@@@+:%@%:     *%  -@@*   -@@%   *@@=
         :@@+:%@*     -*   -@@*   -@@%   *@@=
          +@+:%*     *@@@@@%@%-   #@@@+  *@@-
   :==--::*#:#-     -:   -*:        +   =@@=
 :@@@@@@@@#@-                         +@#:
 =   :-=-:                          -:
BANNER
printf '\n'
