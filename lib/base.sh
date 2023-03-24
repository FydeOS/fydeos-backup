#!/usr/bin/env bash

[[ "${_BASE_SCRIPT_SOURCE:-""}" == "yes" ]] && return 0
_BASE_SCRIPT_SOURCE=yes

# shellcheck source=./lib/log.sh
source "$SCRIPT_LIB_DIR/log.sh"

set -o errexit
set -o pipefail
set -o nounset

CHROME_PROFILE_SUBDIR_NAME="user"
# shellcheck disable=SC2034
readonly CHROME_PROFILE_SUBDIR_NAME
ANDROID_DATA_SUBDIR_NAME="root/android-data"
# shellcheck disable=SC2034
readonly ANDROID_DATA_SUBDIR_NAME

INTERMEDIATE_BACKUP_RESTORE_FILE_PATH="/mnt/stateful_partition/encrypted/chronos/.fydeos_backup"
# shellcheck disable=SC2034
readonly INTERMEDIATE_BACKUP_RESTORE_FILE_PATH

BACKUP_METADATA_FILE_NAME="backup_metadata.json"
# shellcheck disable=SC2034
readonly BACKUP_METADATA_FILE_NAME

GPG_HOMEDIR="/tmp/fydeos_backup/gnupg"
readonly GPG_HOMEDIR
GPG_BIN="gpg --homedir $GPG_HOMEDIR"
readonly GPG_BIN

CURRENT_USER_BASE_PATH=""
CURRENT_USER_CHROME_DATA_DIR=""
CURRENT_USER_ANDROID_DATA_DIR=""

prepare_gpg() {
  mkdir -p "$GPG_HOMEDIR"
  chmod 700 "$GPG_HOMEDIR"
  $GPG_BIN -k > /dev/null 2>&1 || { fatal "Failed to prepare gpg"; }
}

get_hash_from_email() {
 local email="$1"
 cryptohome --action=obfuscate_user --user="$email" || echo ""
}

kb2gb() {
  local kb="$1"
  echo "scale=2; $kb / 1024 / 1024" | bc | awk '{printf "%.2f", $0}'
}

get_folder_size() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    echo "0"
    return
  fi
  du -sk "$d" | awk '{print $1}'
}

get_available_space() {
  local p="$1"
  df -lk "$p" | grep "$p" | awk '{print $4}'
}

generate_checksum_based_on_email_and_time() {
  local email="$1"
  local datetime="$2"
  echo -n "${email}:${datetime}" | sha256sum | awk '{print $1}'
}

parse_email_from_preference_file() {
 local file="$1"
 if [[ -f "$file" ]]; then
   jq -r '.account_info[0].email' "$file" || { error "Failed to parse email from preference file: $file"; echo ""; }
 else
   error "Unable to find email from preference file: $file"
   echo ""
 fi
}

get_mount_path_by_email() {
 local email="$1"
 local hash=""
 hash=$(get_hash_from_email "$email")
 echo "/home/.shadow/${hash}/mount"
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

clean_path() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    return
  fi
  find "$path" -depth -mindepth 1 \
    -not -path "${path}/${MY_FILES_PATH_NAME}/*" \
    -not -path "${path}/${DOWNLOADS_PATH_NAME}/*" \
    -not -type d -print0 | xargs -0 -r rm -f
  find "$path" -depth -mindepth 1 \
    -not -path "${path}/${MY_FILES_PATH_NAME}/*" \
    -not -path "${path}/${DOWNLOADS_PATH_NAME}/*" \
    -type d -print0 | xargs -0 -r rmdir --ignore-fail-on-non-empty
  sync
}

