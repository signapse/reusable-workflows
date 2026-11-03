#!/usr/bin/env bash
# pipeline-config.sh <key> [file]
#
# Prints a top-level scalar from .signapse/pipeline.yml (flat `key: value`,
# per the pipeline.yml contract). Strips a trailing comment and quotes.
# Prints nothing (exit 0) when the file or key is absent.

key="${1:?usage: pipeline-config.sh <key> [file]}"
file="${2:-${PIPELINE_CONFIG:-.signapse/pipeline.yml}}"
[ -f "$file" ] || exit 0
sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -1 \
  | sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//"
