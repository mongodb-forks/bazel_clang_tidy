#!/usr/bin/env bash
echo "$(cat $1)" > "$3"
if [ "0" == "$(cat $1)" ]; then
  exit 0
else
  cat $2
  exit $(cat $1)
fi
