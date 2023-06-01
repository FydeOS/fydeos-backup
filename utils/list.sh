#!/bin/bash

set -o nounset
set -o pipefail

FILE_ELEMENT_JSON_FORMAT=$(cat <<EOF
{
  "name": "",
  "path": "",
  "size": "",
  "timestamp": ""
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

BACKUP_FILE_FORMAT="fydeos_*.bak"
readonly BACKUP_FILE_FORMAT

get_file_size() {
  local file_path="$1"
  stat -c "%s" "$file_path" | numfmt --to=iec --suffix=B
}

get_file_timestamp() {
  local file_path="$1"
  stat -c "%Z" "$file_path"
}

main() {
  local json_output="[]"
  local dir=""
  local filename=""
  local filepath=
  local filesize=
  local timestamp=
  shopt -s nullglob
  while read -r d; do
    if [[ ! -d "$d" ]]; then
      continue
    fi
    dir="${d#"$MEDIA_REMOVABLE_DIR_NAME"}"

    ele=$(echo "$PARTITION_ELEMENT_JSON_FORMAT" | jq ".dir = \"${dir}\"")
    for f in "${d}"/${BACKUP_FILE_FORMAT}; do
      local content=""
      filepath="$f"
      filename="${f#"${MEDIA_REMOVABLE_DIR_NAME}${dir}"/}"
      filesize="$(get_file_size "$filepath" || echo "0")"
      timestamp="$(get_file_timestamp "$filepath" || echo "0")"
      content="$(echo "$FILE_ELEMENT_JSON_FORMAT" | jq ". | .name = \"${filename}\" | .path = \"${filepath}\" | .size = \"${filesize}\" | .timestamp = \"${timestamp}\"")"
      ele=$(echo "$ele" | jq ".list |= .+ [${content}]")
    done
    json_output=$(echo "$json_output" | jq ". += [$ele]")
  done < <(findmnt -o TARGET -l | grep "${MEDIA_REMOVABLE_DIR_NAME}")

  echo "$json_output"
}

main
