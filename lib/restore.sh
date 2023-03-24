#!/usr/bin/env bash

# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

BACKUP_FILE_CHROME_PROFILE_DIR_NAME="${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}/${CHROME_PROFILE_SUBDIR_NAME}"
readonly BACKUP_METADATA_FILE_NAME
BACKUP_FILE_ANDROID_DATA_DIR_NAME="${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}/${ANDROID_DATA_SUBDIR_NAME}"
readonly BACKUP_FILE_ANDROID_DATA_DIR_NAME
DISABLE_CHROME_RESTART_FILE="/run/disable_chrome_restart"
readonly DISABLE_CHROME_RESTART_FILE

RESTORE_DATA_BASE_PATH=""

assert_email_and_current_user_path() {
  local email="$1"
  local current_user_path=""
  local path_by_email=""
  current_user_path="$(get_current_user_base_path)"
  path_by_email=$(get_mount_path_by_email "$email")
  if [[ ! "$current_user_path" = "$path_by_email" ]]; then
    fatal "The email $email is not the current logged-in user"
  fi
}

assert_new_user_path_created() {
  local email="$1"
  local path=""
  path=$(get_mount_path_by_email "$email")
  if [[ ! -d "$path" ]]; then
    fatal "The path $path for new user does not exist, you may want to run cryptohome --action=remove --user=${email} to remove the user and try again"
  fi
}

clean_intermediate_files() {
  echo "Clean intermediate files"
  rm -fr "${BACKUP_FILE_CHROME_PROFILE_DIR_NAME}"
  rm -fr "${BACKUP_FILE_ANDROID_DATA_DIR_NAME}"
  clean_path "${INTERMEDIATE_BACKUP_RESTORE_FILE_PATH}"
}

decrypt_uncompress_backup_file() {
  local file="$1"
  local target_path="$2"
  local key="$3"

  echo "Uncompressing $file to $target_path"
  mkdir -p "$target_path"

  $GPG_BIN -d --passphrase "$key" "$file"  | tar --preserve-permissions -C "${target_path}" -xzvf -
}

prepare_backup_files() {
  local email="$1"
  local pass="$2"
  local backup_file="$3"

  local key=""
  key=$(generate_key_for_backup_file "$email" "$pass")
  debug "the key to decrypt backup file is $key"

  decrypt_uncompress_backup_file "$backup_file" "$INTERMEDIATE_BACKUP_RESTORE_FILE_PATH" "$key"
  if [[ ! -d "${BACKUP_FILE_CHROME_PROFILE_DIR_NAME}" ]]; then
    warn "No Chrome profile directory found in backup file"
  fi
  if [[ ! -d "${BACKUP_FILE_ANDROID_DATA_DIR_NAME}" ]]; then
    warn "No Android data directory found in backup file"
  fi
}

assert_backup_metadata() {
  local email="$1"
  local meta_file="$INTERMEDIATE_BACKUP_RESTORE_FILE_PATH/$BACKUP_METADATA_FILE_NAME"
  if [[ ! -f "$meta_file" ]]; then
    fatal "Backup metadata file $meta_file does not exist"
  fi
  local checksum_in_meta=""
  local datetime_in_meta=""
  checksum_in_meta=$(jq -r '.checksum' "$meta_file")
  datetime_in_meta=$(jq -r '.datetime' "$meta_file")
  if [[ -z "$checksum_in_meta" ]] || [[ -z "$datetime_in_meta" ]]; then
    fatal "Backup metadata file $meta_file is corrupted"
  fi
  local checksum=""
  checksum=$(generate_checksum_based_on_email_and_time "$email" "$datetime_in_meta")
  if [[ "$checksum" != "$checksum_in_meta" ]]; then
    fatal "Backup file does not match the email $email"
  fi
}

print_files_to_restore_disk_usage() {
  local backup_file="$1"
  local size=0
  size=$(du -k "$backup_file" | awk '{print $1}')
  local available_space=0
  available_space="$(get_available_space "/mnt/stateful_partition")"

  echo "Compressed backup file size: $(kb2gb "$size")GB"
  echo "Available space: $(kb2gb "$available_space")GB"
}

stop_chronos_processes() {
  echo "Stopping all processes of user chronos"
  touch "$DISABLE_CHROME_RESTART_FILE"
  if sudo -u chronos pgrep session_manager >/dev/null 2>&1; then
    while ! sudo -u chronos kill -9 -- -1; do
      sleep .1
    done
  fi
  sleep 1
  sync
}

restart_ui() {
  echo "Restarting"
  rm -f "$DISABLE_CHROME_RESTART_FILE"
  restart ui
}

assert_chrome_backup_folder_permission() {
  local perm=""
  perm=$(stat -c "%A.%U.%G" "$BACKUP_FILE_CHROME_PROFILE_DIR_NAME")
  [[ "$perm" = "drwxr-x---.chronos.chronos-access" ]]
}

restore_chrome_profile() {
  local target_path=""
  target_path="$RESTORE_DATA_BASE_PATH/$CHROME_PROFILE_SUBDIR_NAME"
  if [[ -z "$target_path" ]]; then
    error "Should not reach here"
    return
  fi
  if [[ ! -d "$BACKUP_FILE_CHROME_PROFILE_DIR_NAME" ]]; then
    warn "no Chrome profile backup files found, skip restore"
    return
  fi

  if ! assert_chrome_backup_folder_permission; then
    warn "Permission of chrome backup folder seems to be wrong, skip restore"
    return
  fi

  info "Restoring Chrome profile to ${target_path}"
  if [[ "${RESTORE_MODE}" = "${RESTORE_MODE_REPLACE}" ]]; then
    clean_path "${target_path}"
  fi
  cp "${BACKUP_FILE_CHROME_PROFILE_DIR_NAME}"/. "${target_path}" -a
  sync
}

assert_android_backup_folder_permission() {
  local perm=""
  perm=$(stat -c "%A.%U.%G" "$BACKUP_FILE_ANDROID_DATA_DIR_NAME")
  [[ "$perm" = "drwx------.android-root.android-root" ]]
}

restore_android_data() {
  local target_path=""
  target_path="$RESTORE_DATA_BASE_PATH/$ANDROID_DATA_SUBDIR_NAME"
  if [[ -z "$target_path" ]]; then
    error "Should not reach here"
    return
  fi
  if [[ ! -d "$BACKUP_FILE_ANDROID_DATA_DIR_NAME" ]]; then
    warn "no Android data backup files found, skip restore"
    return
  fi
  if ! assert_android_backup_folder_permission; then
    warn "Permission of android data backup folder seems to be wrong, skip restore"
    return
  fi
  info "Restoring Android data to ${target_path}"
  local parent_path=""
  parent_path=$(dirname "${target_path}")
  if [[ ! -d "$target_path" ]] && [[ -d "$parent_path" ]]; then
    cp "$BACKUP_FILE_ANDROID_DATA_DIR_NAME" "$parent_path" -a
  else
    if [[ "${RESTORE_MODE}" = "${RESTORE_MODE_REPLACE}" ]]; then
      clean_path "${target_path}"
    fi
    cp "$BACKUP_FILE_ANDROID_DATA_DIR_NAME"/. "$target_path" -a
  fi
  sync
}

restore_backup_files() {
  local email="$1"
  local pass="$2"
  local backup_file="$3"
  local restore_path="$4"
  RESTORE_DATA_BASE_PATH="$restore_path"

  if [[ ! -f "$backup_file" ]]; then
    fatal "Cannot find backup file: $backup_file"
  fi

  print_files_to_restore_disk_usage "$backup_file"

  trap clean_intermediate_files EXIT
  prepare_backup_files "$email" "$pass" "$backup_file"

  assert_backup_metadata "$email"

  stop_chronos_processes || { error "Failed to stop chronos processes, abort"; restart_ui; exit 1; }
  set +o errexit # disable exit on error, we need to restart ui anyway
  restore_chrome_profile
  restore_android_data
  set -o errexit

  restart_ui
  info "Restore completed."
}
