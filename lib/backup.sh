#!/usr/bin/env bash

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

email_to_filename_with_underscore() {
  local email="$1"
  echo "${email//[^[:alnum:]]/_}"
}

tar_backup_files() {
  local email="$1"
  local pass="$2"
  local filename=""
  local datetime=""
  datetime="$(date +%Y%m%d_%H%M%S)"
  local email_in_filename=""
  email_in_filename=$(email_to_filename_with_underscore "$email")
  filename="fydeos_backup_${email_in_filename}_${datetime}.tar.gz.gpg"

  local dst="/home/chronos/user/Downloads"
  local final="$dst/${filename}"

  local tmp="${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}/${filename}"
  mkdir -p "${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}"
  echo "Backup the file to $final"
  local temp_dir=""
  temp_dir=$(mktemp -d "/tmp/fydeos_backup_XXXXXXXX") || fatal "Failed to create temporary directory"
  debug "temp dir for extra data: $temp_dir"
  local meta_file="$BACKUP_METADATA_FILE_NAME"
  local meta_file_path="$temp_dir/$meta_file"
  generate_metadata_for_backup_file "$email" "$datetime" "$meta_file_path"

  backup_local_state_file "$email" "$temp_dir"

  # shellcheck disable=SC2064
  trap "rm -f $tmp; clean_path $temp_dir" SIGINT SIGTERM
  # tar might return non-zero exit code due to files changes or some other reasons
  local key=""
  key=$(generate_key_for_backup_file "$email" "$pass")
  debug "password for encryped backup file: $key"
  tar_with_extra "$key" "$tmp" "$temp_dir"
  if [[ ! -f "$tmp" ]]; then
    fatal "Faile to tar backup file"
  fi

  mv "${tmp}" "${final}"

  chown chronos:chronos "$final"

  clean_path "${temp_dir}"
  rmdir "${temp_dir}" || true

  info "Tar backup files done, find the file $filename in Downloads folder of user $email"
}
