#!/usr/bin/env bash

# shellcheck source=lib/version.sh
source "$SCRIPT_LIB_DIR/version.sh"
# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

PREFERENCE_JSON_FILE_NAME="Preferences"
readonly PREFERENCE_JSON_FILE_NAME

MY_FILES_PATH_NAME="MyFiles"
readonly MY_FILES_PATH_NAME
DOWNLOADS_PATH_NAME="Downloads" # same with "MyFiles/Downloads", do not clean it or backup it
readonly DOWNLOADS_PATH_NAME

verify_cryptohome_password() {
  local u="$1"
  local p="$2"
  if ! cryptohome --action=check_key_ex --password="$p" --user="$u" > /dev/null; then
    fatal "Unable to verify cryptohome password"
  fi
  info "Verified cryptohome password"
}

print_files_to_backup_disk_usage() {
  local chrome_profile_size=0
  local android_data_size=0
  local available_space=0
  chrome_profile_size="$(get_folder_size "$(get_current_user_chrome_profile_data_path)")"
  android_data_size="$(get_folder_size "$(get_current_user_android_data_path)")"
  local total_backup_size=0

  total_backup_size=$(echo "$chrome_profile_size + $android_data_size" | bc)

  available_space="$(get_available_space "/mnt/stateful_partition")"

  echo "Total backup size: $(kb2gb "$total_backup_size")GB (Chrome profile size: $(kb2gb "$chrome_profile_size")GB, Android data size: $(kb2gb "$android_data_size")GB)"

  echo "Available space: $(kb2gb "$available_space")GB"
}

generate_metadata_for_backup_file() {
  local email="$1"
  local datetime="$2"
  local file="$3"
  local content=""
  local checksum=""
  checksum=$(generate_checksum_based_on_email_and_time "$email" "$datetime")
  content="$(cat << EOF
{
  "checksum": "$checksum",
  "datetime": "$datetime"
}
EOF
)"
  echo "$content" > "${file}"
}

save_avatar_for_user() {
  local email="$1"
  local dir="$2"
  local path=""
  path="$(get_user_image_info_path "$email")"
  debug "get user avatar path $path"
  if [[ "$path" = "/home/chronos/"* ]] && [[ -f "$path" ]]; then
    mkdir -p "$dir"
    cp -af "$path" "$dir"
  fi
}

backup_local_state_file() {
  local email="$1"
  local dir="$2"
  local json_file="$dir/$USER_LOCAL_STATE_JSON_FILE_NAME"
  local avatar_dir="$dir/$USER_AVATAR_SUBDIR_NAME"
  save_local_state_for_user "$email" "$json_file"
  save_avatar_for_user "$email" "$avatar_dir"
}

tar_with_extra() {
  local key="$1"
  local target="$2"
  local extra_dir="$3"
  local base_dir=""
  base_dir=$(get_current_user_base_path)
  if [[ -z "$base_dir" ]] || [[ ! -d "$base_dir" ]]; then
    fatal "Unable to get current user base path"
  fi
  echo "Tar backup files ${base_dir}/${CHROME_PROFILE_SUBDIR_NAME} and ${base_dir}/${ANDROID_DATA_SUBDIR_NAME}"

  set +o pipefail
  if [[ "$WITH_MY_FILES" = "false" ]]; then
    tar --preserve-permissions \
      -czvf - \
      -C "${extra_dir}" \
      . \
      -C "${base_dir}" \
      --exclude "${CHROME_PROFILE_SUBDIR_NAME}/${MY_FILES_PATH_NAME}" \
      --exclude "${CHROME_PROFILE_SUBDIR_NAME}/${DOWNLOADS_PATH_NAME}" \
      "${CHROME_PROFILE_SUBDIR_NAME}" \
      "${ANDROID_DATA_SUBDIR_NAME}" 2> /dev/null \
      | $GPG_BIN -v --passphrase "$key" -c -o "${target}"
  else
    #always exclude DOWNLOADS_PATH_NAME(Downloads) folder, even if myfiles is enabled, since downloads folder are the same with MyFiles/Downloads
    tar --preserve-permissions \
      -czvf - \
      -C "${extra_dir}" \
      . \
      -C "${base_dir}" \
      --exclude "${CHROME_PROFILE_SUBDIR_NAME}/${DOWNLOADS_PATH_NAME}" \
      "${CHROME_PROFILE_SUBDIR_NAME}" \
      "${ANDROID_DATA_SUBDIR_NAME}" 2> /dev/null \
      | $GPG_BIN -v --passphrase "$key" -c -o "${target}"
  fi
  sync
  set -o pipefail
}

dar_with_extra() {
  local key="$1"
  local target="$2"
  local extra_dir="$3"
  local base_dir=""
  base_dir=$(get_current_user_base_path)
  if [[ -z "$base_dir" ]] || [[ ! -d "$base_dir" ]]; then
    fatal "Unable to get current user base path"
  fi
  echo "Backing up files ${base_dir}/${CHROME_PROFILE_SUBDIR_NAME} and ${base_dir}/${ANDROID_DATA_SUBDIR_NAME}"
  base_dir="${base_dir#*/}" #remove leading slash

  local fixed_temp_extra_path="${base_dir}/$FIXED_TEMP_EXTRA_DATA_PATH_USED_BY_DAR"
  rm -rf "$fixed_temp_extra_path"
  mv "$extra_dir" "$fixed_temp_extra_path"

  local temp_dar_target=""

  # shellcheck disable=SC2064
  trap "rm -fr $fixed_temp_extra_path" SIGINT SIGTERM ERR

  temp_dar_target="${target}_$(date +%s)"
  # "${target}_$(date +%s).1.dar" is expected
  if [[ "$WITH_MY_FILES" = "false" ]]; then
    dar -c "$temp_dar_target" -z -K "$key" \
        -R "${base_dir}" \
        -g "${FIXED_TEMP_EXTRA_DATA_PATH_USED_BY_DAR}" \
        -g "${CHROME_PROFILE_SUBDIR_NAME}" \
        -g "${ANDROID_DATA_SUBDIR_NAME}" \
        -P "${CHROME_PROFILE_SUBDIR_NAME}/${MY_FILES_PATH_NAME}" \
        -P "${CHROME_PROFILE_SUBDIR_NAME}/${DOWNLOADS_PATH_NAME}" \
        --retry-on-change 5
  else
    dar -c "$temp_dar_target" -z -K "$key" \
        -R "${base_dir}" \
        -g "${FIXED_TEMP_EXTRA_DATA_PATH_USED_BY_DAR}" \
        -g "${CHROME_PROFILE_SUBDIR_NAME}" \
        -g "${ANDROID_DATA_SUBDIR_NAME}" \
        -P "${CHROME_PROFILE_SUBDIR_NAME}/${DOWNLOADS_PATH_NAME}" \
        --retry-on-change 5
  fi
  sync
  rm -rf "$fixed_temp_extra_path"
  local expect="${temp_dar_target}.1.dar"
  if [[ -f "$expect" ]]; then
    mv "$expect" "$target"
  else
    fatal "Unable to find expected dar file $expect"
  fi
}

email_to_filename_with_underscore() {
  local email="$1"
  local name=""
  name=$(echo "$email" | cut -d '@' -f 1)
  echo "${name//[^[:alnum:]]/_}"
}

generate_extra_plain_metadata_for_backup_file() {
  local email="$1"
  local result=""
  local board=""
  local chromiumos_version=""
  local fydeos_version=""
  local script_version=""
  board=$(get_board_name)
  chromiumos_version=$(get_chromiumos_version)
  fydeos_version=$(get_fydeos_version)
  script_version=$(version)
  if [[ "$chromiumos_version" = "15183."* ]]; then
    result="$email"
  else
    result="$(cat << EOF
{
  "email": "$email",
  "board": "$board",
  "chromiumos_version": "$chromiumos_version",
  "fydeos_version": "$fydeos_version",
  "tool": "dar",
  "script_version": "$script_version"
}
EOF
)"
  fi
  echo "$result"
}

append_plain_metadata_to_file() {
  local file="$1"
  local email="$2"

  local temp=""
  temp=$(mktemp /tmp/XXXXXXXXX)
  local content=""
  content=$(generate_extra_plain_metadata_for_backup_file "$email")
  echo -n "$content" | base64 > "$temp"
  truncate -s "$BACKUP_FILE_TAIL_SIZE" "$temp"
  cat "$temp" >> "$file"
  rm -f "$temp"
}

tar_backup_files() {
  local email="$1"
  local pass="$2"
  local target_path="$3"
  local key_phrase="$4"
  local default_filename=""
  local datetime=""
  datetime="$(date +%Y%m%d_%H%M)"
  local email_in_filename=""
  email_in_filename=$(email_to_filename_with_underscore "$email")
  default_filename="fydeos_${email_in_filename}_${datetime}.bak"
  local intermediate_dir=""

  local dst=""
  local final=""
  local target_dir=""
  if [[ -n "$target_path" ]]; then
    target_dir="$(dirname "$target_path" || true)"
  fi
  if [[ -n "$target_dir" ]] && [[ -d "$target_dir" ]]; then
    dst="$target_dir"
    intermediate_dir="$dst/.fydeos_backup_temp"
    final="$target_path"
  else
    warn "Invalid target path, using default /home/chronos/user/Downloads as target"
    dst="/home/chronos/user/Downloads"
    intermediate_dir="$INTERMEDIATE_BACKUP_RESTORE_FILE_PATH"
    final="$dst/${default_filename}"
  fi

  local tmp="${intermediate_dir}/${default_filename}"
  mkdir -p "${intermediate_dir}"
  echo "Backup the file to $final"
  local temp_dir=""
  temp_dir=$(mktemp -d "/tmp/fydeos_backup_XXXXXXXX") || fatal "Failed to create temporary directory"
  debug "temp dir for extra data: $temp_dir"
  local meta_file="$BACKUP_METADATA_FILE_NAME"
  local meta_file_path="$temp_dir/$meta_file"
  generate_metadata_for_backup_file "$email" "$datetime" "$meta_file_path"

  backup_local_state_file "$email" "$temp_dir"

  # shellcheck disable=SC2064
  trap "rm -f $tmp; clean_path $temp_dir; clean_path $intermediate_dir" SIGINT SIGTERM
  # tar might return non-zero exit code due to files changes or some other reasons
  local key=""
  if [[ -z "$KEYPHRASE" ]]; then
    if [[ -z "$pass" ]]; then
      fatal "Should not reach here, passphrase is empty"
    fi
    key=$(generate_key_for_backup_file "$email" "$pass")
  else
    key="$key_phrase"
  fi
  debug "password for encryped backup file: $key"
  if is_dar_exists; then
    dar_with_extra "$key" "$tmp" "$temp_dir"
  else
    tar_with_extra "$key" "$tmp" "$temp_dir"
  fi
  if [[ ! -f "$tmp" ]]; then
    fatal "Fail to tar backup file"
  fi

  append_plain_metadata_to_file "$tmp" "$email"

  mv "${tmp}" "${final}"

  chown chronos:chronos-access "$final"

  clean_path "${temp_dir}"
  rmdir "${temp_dir}" || true
  rmdir "${intermediate_dir}" || true

  info "Tar backup files done, $final"
}
