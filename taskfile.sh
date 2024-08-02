#!/bin/bash

if [ ! -x /usr/local/bin/task ]; then
  sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b .
  sudo install -o root -g root -m 0755 task /usr/local/bin/task
fi
[ -f ./task ] && rm -f ./task
