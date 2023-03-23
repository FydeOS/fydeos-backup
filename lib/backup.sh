#!/usr/bin/env bash

# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

PREFERENCE_JSON_FILE_NAME="Preferences"
readonly PREFERENCE_JSON_FILE_NAME

MY_FILES_PATH_NAME="MyFiles"
readonly MY_FILES_PATH_NAME
DOWNLOADS_PATH_NAME="Downloads" # same with "MyFiles/Downloads", do not clean it or backup it
readonly DOWNLOADS_PATH_NAME

CURRENT_USER_BASE_PATH=""
CURRENT_USER_CHROME_DATA_DIR=""
CURRENT_USER_ANDROID_DATA_DIR=""

parse_email_from_preference_file() {
 local file="$1"
 if [[ -f "$file" ]]; then
   jq -r '.account_info[0].email' "$file" || { error "Failed to parse email from preference file: $file"; echo ""; }
 else
   error "Unable to find email from preference file: $file"
   echo ""
 fi
}

get_current_user_hash_id() {
  findmnt -T /home/chronos/user -o SOURCE | grep shadow | awk -F/ '{print $6}'
}

get_current_user_base_path() {
  if [[ -z "$CURRENT_USER_BASE_PATH" ]]; then
    local id=""
    id=$(get_current_user_hash_id)
    CURRENT_USER_BASE_PATH="/home/.shadow/${id}/mount"
  fi
  echo "$CURRENT_USER_BASE_PATH"
}

get_current_user_chrome_profile_data_path() {
  if [[ -z "$CURRENT_USER_CHROME_DATA_DIR" ]]; then
    CURRENT_USER_CHROME_DATA_DIR="$(get_current_user_base_path)/${CHROME_PROFILE_SUBDIR_NAME}"
  fi
  echo "$CURRENT_USER_CHROME_DATA_DIR"
}

get_current_user_android_data_path() {
  if [[ -z "$CURRENT_USER_ANDROID_DATA_DIR" ]]; then
    CURRENT_USER_ANDROID_DATA_DIR="$(get_current_user_base_path)/${ANDROID_DATA_SUBDIR_NAME}"
  fi
  echo "$CURRENT_USER_ANDROID_DATA_DIR"
}

# get the email of current logged in user
get_current_user_email() {
  local path=""
  path=$(get_current_user_chrome_profile_data_path)
  local email=""
  email=$(parse_email_from_preference_file "$path/${PREFERENCE_JSON_FILE_NAME}")
  local hash_from_email=""
  debug "get current user email: $email"
  hash_from_email=$(get_hash_from_email "$email")
  local hash_from_findmnt=""
  hash_from_findmnt=$(get_current_user_hash_id)
  if [[ ! "$hash_from_findmnt" = "$hash_from_email" ]]; then
    debug "hash_from_findmnt: $hash_from_findmnt, hash_from_email: $hash_from_email"
    error "Unable to find the correct email of current logged in user"
    email=""
  fi
  echo "$email"
}

verify_cryptohome_password() {
  local u="$1"
  local p="$2"
  if ! cryptohome --action=check_key_ex --password="$p" --user="$u" > /dev/null; then
    fatal "Unable to verify cryptohome password"
  fi
  info "Verified cryptohome password"
}

generate_key_for_backup_file() {
  local u="$1"
  local p="$2"
  echo -n "$u:$p" | sha1sum | awk '{print $1}' | cut -c -16
}

assert_current_mount_status() {
  local mounted=""
  mounted=$(cryptohome --action=is_mounted)
  if [[ "$mounted" != "true" ]]; then
    fatal "cryptohome is not mounted, cannot backup or restore"
  fi
  if ! findmnt "/home/chronos/user" -o SOURCE | grep -q shadow; then
    fatal "No user mounted at /home/chronos/user, cannot backup or restore"
  fi
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

tar_with_metadata() {
  local key="$1"
  local target="$2"
  local meta_file_path="$3"
  local temp_meta_dir=""
  local meta_file=""
  local base_dir=""
  base_dir=$(get_current_user_base_path)
  if [[ -z "$base_dir" ]] || [[ ! -d "$base_dir" ]]; then
    fatal "Unable to get current user base path"
  fi
  echo "Tar backup files ${base_dir}/${CHROME_PROFILE_SUBDIR_NAME} and ${base_dir}/${ANDROID_DATA_SUBDIR_NAME}"
  temp_meta_dir=$(dirname "$meta_file_path")
  meta_file=$(basename "$meta_file_path")

  set +o pipefail
  if [[ "$WITH_MY_FILES" = "false" ]]; then
    tar --preserve-permissions \
      -czvf - \
      -C "${temp_meta_dir}" \
      "$meta_file" \
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
      -C "${temp_meta_dir}" \
      "$meta_file" \
      -C "${base_dir}" \
      --exclude "${CHROME_PROFILE_SUBDIR_NAME}/${DOWNLOADS_PATH_NAME}" \
      "${CHROME_PROFILE_SUBDIR_NAME}" \
      "${ANDROID_DATA_SUBDIR_NAME}" 2> /dev/null \
      | $GPG_BIN -v --passphrase "$key" -c -o "${target}"
  fi
  sync
  set -o pipefail
}

tar_backup_files() {
  local email="$1"
  local pass="$2"
  local filename=""
  local datetime=""
  datetime="$(date +%Y%m%d_%H%M%S)"
  filename="fydeos_backup_${datetime}.tar.gz.gpg"

  local dst="/home/chronos/user/Downloads"
  local final="$dst/${filename}"

  local tmp="${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}/${filename}"
  mkdir -p "${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}"
  echo "Backup the file to $final"
  local temp_meta_dir=""
  temp_meta_dir=$(mktemp -d "/tmp/fydeos_backup_XXXXXXXX") || fatal "Failed to create temporary directory"
  local meta_file="backup_meta.json"
  local meta_file_path="$temp_meta_dir/$meta_file"
  generate_metadata_for_backup_file "$email" "$datetime" "$meta_file_path"

  # shellcheck disable=SC2064
  trap "rm -f $tmp; rm -f $meta_file_path; rmdir $temp_meta_dir" SIGINT SIGTERM
  # tar might return non-zero exit code due to files changes or some other reasons
  local key=""
  key=$(generate_key_for_backup_file "$email" "$pass")
  debug "password for encryped backup file: $key"
  tar_with_metadata "$key" "$tmp" "$meta_file_path"
  if [[ ! -f "$tmp" ]]; then
    fatal "Faile to tar backup file"
  fi

  mv "${tmp}" "${final}"

  chown chronos:chronos "$final"

  info "Tar backup files done, find the file $filename in Downloads folder"
}
