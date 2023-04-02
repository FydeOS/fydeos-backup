#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

FILE_ELEMENT_JSON_FORMAT=$(cat <<EOF
{
  "name": "",
  "path": ""
}
EOF
)
readonly FILE_ELEMENT_JSON_FORMAT

PARTITION_ELEMENT_JSON_FORMAT=$(cat <<EOF
{
	"dir": "",
	"list": []
}
EOF
)
readonly PARTITION_ELEMENT_JSON_FORMAT


MEDIA_REMOVABLE_DIR_NAME="/media/removable/"
readonly MEDIA_REMOVABLE_DIR_NAME

BACKUP_FILE_FORMAT="fydeos_backup_*.tar.gz.gpg"
readonly BACKUP_FILE_FORMAT

main() {
  local json_output="[]"
  local dir=""
  local filename=""
  local filepath=
  for d in $(findmnt -o TARGET -r | grep "${MEDIA_REMOVABLE_DIR_NAME}"); do
    if [[ ! -d "$d" ]]; then
      continue
    fi
    dir="${d#"$MEDIA_REMOVABLE_DIR_NAME"}"

    ele=$(echo "$PARTITION_ELEMENT_JSON_FORMAT" | jq ".dir = \"${dir}\"")
    for f in "${d}"/${BACKUP_FILE_FORMAT}; do
      local content=""
      filepath="$f"
      filename="${f#"${MEDIA_REMOVABLE_DIR_NAME}${dir}"/}"
      content="$(echo "$FILE_ELEMENT_JSON_FORMAT" | jq ". | .name = \"${filename}\" | .path = \"${filepath}\"")"
      ele=$(echo "$ele" | jq ".list |= .+ [${content}]")
    done
    json_output=$(echo "$json_output" | jq ". += [$ele]")
  done

  echo "$json_output"
}

main
