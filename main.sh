#!/usr/bin/env bash

SCRIPT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_ROOT_DIR
SCRIPT_LIB_DIR="$SCRIPT_ROOT_DIR/lib"
readonly SCRIPT_LIB_DIR

# shellcheck source=lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_LIB_DIR/backup.sh"
# shellcheck source=lib/cryptohome_action.sh
source "$SCRIPT_LIB_DIR/cryptohome_action.sh"
# shellcheck source=lib/restore.sh
source "$SCRIPT_LIB_DIR/restore.sh"

set -o errexit

ACTION_BACKUP="backup"
readonly ACTION_BACKUP
ACTION_RESTORE="restore"
readonly ACTION_RESTORE

RESTORE_MODE_MERGE="merge"
readonly RESTORE_MODE_MERGE
RESTORE_MODE_REPLACE="replace"
readonly RESTORE_MODE_REPLACE
DEFAULT_RESTORE_MODE="${RESTORE_MODE_MERGE}"
readonly DEFAULT_RESTORE_MODE

ACTION=""
RESTORE_MODE=""
BACKUP_FILE=""
WITH_MY_FILES="false"
CREATE_NEW_USER="false"
USER_EMAIL=""
PASSWORD=""

usage() {
  cat <<EOF
Usage: $0 [backup|restore] [OPTIONS]

Commands:
  backup                  Perform a backup of the data
  restore                 Restore the data from a backup file

Options for backup:
  --with-myfiles          Include 'My Files' in the backup
  --password <pass>       Specify the password to verify user identity and encrypt the backup file
                          Please note that it is not recommended to specify the password directly in the command line parameters. This script will prompt the user to enter the password when needed
  -d, --debug             Enable debug mode

Options for restore:
  -f, --file <file>       Specify the backup file to restore from
  --restore-mode <mode>   Specify the restore mode: ${RESTORE_MODE_MERGE} or ${RESTORE_MODE_REPLACE} (default: ${DEFAULT_RESTORE_MODE})
  -n, --new <email>       Create a new user with a given email and restore data for that user
  --password <pass>       Specify a password for new user's encrypted directory and decrypting backup file
                          Please note that it is not recommended to specify the password directly in the command line parameters. This script will prompt the user to enter the password when needed
  -d, --debug             Enable debug mode

-h, --help            Display this help message and exit
EOF
  exit "${1:-0}"
}

die_with_usage() {
  echo "$@"
  echo
  usage 1
}

prompt_info() {
  echo "${V_BOLD_GREEN}$*${V_VIDOFF}"
}

prompt_for_password() {
  if [[ -n "$PASSWORD" ]]; then
    warn "Setting password in command line arguments is not recommended. The script will prompt for your password."
    return
  fi
  local prompt="Enter Password:"
  if [[ "$ACTION" = "$ACTION_BACKUP" ]]; then
    prompt="The user is $USER_EMAIL, please enter the login password to verify your identity, and the password will be used to encrypt the backup file:"
  elif [[ "$ACTION" = "$ACTION_RESTORE" ]]; then
    prompt="Please enter the password for decrypting the backup file and create/verify encrypted directory for the user $USER_EMAIL:"
  fi
  while IFS= read -p "$(prompt_info "$prompt")" -r -s -n 1 char; do
    if [[ $char == $'\0' ]]; then
      break
    fi
    prompt='*'
    PASSWORD+="$char"
  done
  echo
}

prompt_for_email() {
  local action="$1"
  local prompt="Please enter the email of the account you want to $action. If you are already logged in, please enter the email you are currently logged in with: "
  while true; do
    read -p "$(prompt_info "$prompt")" -r email
    if [[ -z "$email" ]]; then
      error "Email cannot be empty"
    else
      break
    fi
  done
  USER_EMAIL="$email"
}

print_params() {
  debug "ACTION: $ACTION"
  debug "RESTORE_MODE: $RESTORE_MODE"
  debug "BACKUP_FILE: $BACKUP_FILE"
  debug "WITH_MY_FILES: $WITH_MY_FILES"
  debug "CREATE_NEW_USER: $CREATE_NEW_USER"
  debug "USER_EMAIL: $USER_EMAIL"
  debug "PASSWORD: $PASSWORD"
}

verify_params() {
  if [[ ! $ACTION = "$ACTION_RESTORE" ]] && [[ ! "$ACTION" = "$ACTION_BACKUP" ]]; then
    fatal "Invalid action: $ACTION"
  fi
  if [[ ! $ACTION = "$ACTION_RESTORE" ]] && [[ -n "$RESTORE_MODE" ]]; then
    info "Restore mode will be ignored for $ACTION action"
  fi
  if [[ "$ACTION" = "$ACTION_RESTORE" ]]; then
    if [[ -z "$RESTORE_MODE" ]]; then
      RESTORE_MODE="${DEFAULT_RESTORE_MODE}"
    fi
    if [[ "$RESTORE_MODE" != "${RESTORE_MODE_MERGE}" ]] && [[ "$RESTORE_MODE" != "$RESTORE_MODE_REPLACE" ]]; then
      fatal "Invalid restore mode: $RESTORE_MODE. Valid modes are ${RESTORE_MODE_MERGE} or ${RESTORE_MODE_REPLACE}."
    fi

    if [[ -z "$BACKUP_FILE" ]]; then
      fatal "Backup file is required for $ACTION action"
    fi
    if [[ "$CREATE_NEW_USER" = "true" ]] && [[ -z "$USER_EMAIL" ]]; then
      fatal "User email is required for creating new user and restore data"
    fi
  fi
}

assert_root_user() {
  set +o nounset
  set +o errexit
  if [[ $EUID -ne 0 ]]; then
    die_with_usage "Please login as root to run this script"
  fi
  set -o errexit
  set -o nounset
}

assert_no_sudo_root() {
  set +o nounset
  set +o errexit
  if [[ $EUID -ne 0 ]] || [[ -n "$SUDO_USER" ]]; then
    die_with_usage "Please login as root to run this script, and no sudo"
  fi
  set -o errexit
  set -o nounset
}

is_running_in_crosh() {
  set +o nounset
  set +o errexit
  local pid=$$
  local name=""
  local found="false"
  while true; do
    pid=$(ps -h -o ppid -p "$pid" 2>/dev/null | tr -d ' ')
    name=$(ps -h -o comm -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$name" = "crosh" ]]; then
      found="true"
    fi
    [[ $pid -eq 1 ]] && break
  done
  set -o errexit
  set -o nounset
  [[ "$found" = "true" ]]
}

do_backup() {
  set_log_prefix "backup"
  USER_EMAIL=$(get_current_user_email)
  if [[ -z "$USER_EMAIL" ]]; then
    prompt_for_email "backup"
  fi
  prompt_for_password

  if ! is_current_login; then
    if is_cryptohome_mounted; then
      fatal "Please logout any session and run the script again"
    fi
    try_to_login_as_user "$USER_EMAIL" "$PASSWORD"
  else
    verify_cryptohome_password "$USER_EMAIL" "$PASSWORD"
  fi

  assert_email_and_current_user_path "$USER_EMAIL"

  print_files_to_backup_disk_usage

  tar_backup_files "$USER_EMAIL" "$PASSWORD"

  post_cryptohome_action
}

do_restore() {
  set_log_prefix "restore"
  assert_no_sudo_root
  if is_running_in_crosh; then
    die_with_usage "Please do not run the script inside crosh"
  fi
  if [[ "$CREATE_NEW_USER" = "true" ]]; then
    local path=""
    path=$(get_mount_path_by_email "$USER_EMAIL")
    restore_path="$path"
    if [[ -d "$restore_path" ]]; then
      warn "The path $restore_path already exists. The script will try to restore data to this path"
      CREATE_NEW_USER="false"
    fi
  else
    USER_EMAIL=$(get_current_user_email)
    if [[ -z "$USER_EMAIL" ]]; then
      prompt_for_email "restore"
    fi
  fi
  prompt_for_password
  if ! is_current_login; then
    if is_cryptohome_mounted; then
      fatal "Please logout any session or just reboot and run the script again"
    fi
    try_to_login_as_user "$USER_EMAIL" "$PASSWORD"
  else
    verify_cryptohome_password "$USER_EMAIL" "$PASSWORD"
  fi
  assert_email_and_current_user_path "$USER_EMAIL"
  restore_path=$(get_current_user_base_path)

  restore_backup_files "$USER_EMAIL" "$PASSWORD" "$BACKUP_FILE" "$restore_path" "$CREATE_NEW_USER"

  post_cryptohome_action
}

main() {
  assert_root_user
  set +o errexit
  set +o nounset
  while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
      backup)
        ACTION="backup"
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --with-myfiles)
              WITH_MY_FILES="true"
              shift
              ;;
            --password)
              PASSWORD="$2"
              shift
              shift
              ;;
            -d|--debug)
              LOG_LEVEL="debug"
              shift
              ;;
            *)
              usage 1
              ;;
          esac
        done
        ;;
      restore)
        ACTION="restore"
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --restore-mode)
              RESTORE_MODE="$2"
              shift
              shift
              ;;
            -f|--file)
              BACKUP_FILE="$2"
              shift
              shift
              ;;
            -n|--new)
              CREATE_NEW_USER="true"
              if [[ -n "$2" ]]; then
                USER_EMAIL="$2"
                shift
              fi
              shift
              ;;
            --password)
              PASSWORD="$2"
              shift
              shift
              ;;
            -d|--debug)
              LOG_LEVEL="debug"
              shift
              ;;
            *)
              usage 1
              ;;
          esac
        done
        ;;
      -h|--help)
        usage
        ;;
      *)
        usage 1
        ;;
    esac
  done
  set -o nounset
  set -o errexit
  print_params
  verify_params

  prepare_gpg

  assert_no_mount_and_not_login
  if [[ "$ACTION" = "$ACTION_BACKUP" ]]; then
    do_backup
  elif [[ "$ACTION" = "$ACTION_RESTORE" ]]; then
    do_restore
  fi
}

main "$@"
