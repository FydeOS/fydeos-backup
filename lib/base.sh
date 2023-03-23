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

GPG_HOMEDIR="/tmp/fydeos_backup/gnupg"
readonly GPG_HOMEDIR
GPG_BIN="gpg --homedir $GPG_HOMEDIR"
readonly GPG_BIN

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
