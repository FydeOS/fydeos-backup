#!/usr/bin/env bash

SCRIPT_ROOT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_ROOT_DIR
SCRIPT_LIB_DIR="$SCRIPT_ROOT_DIR/lib"
readonly SCRIPT_LIB_DIR

LIST_BACKUP_FILE_LIST_BIN="$SCRIPT_ROOT_DIR/utils/list.sh"
AUTO_MOUNT_BIN="$SCRIPT_ROOT_DIR/utils/mount.sh"

# shellcheck source=lib/version.sh
source "$SCRIPT_LIB_DIR/version.sh"
# shellcheck source=lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"
# shellcheck source=lib/json.sh
source "$SCRIPT_LIB_DIR/json.sh"
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
WITH_MY_FILES="true"
CREATE_NEW_USER="false"
USER_EMAIL=""
PASSWORD=""
KEYPHRASE=""
TARGET_BACKUP_FILE_PATH=""

usage() {
  cat <<EOF
Usage: $0 [backup|restore] [OPTIONS]

Commands:
  backup                  Perform a backup of the data
  restore                 Restore the data from a backup file
  list                    List the backup files in the root directory of the the removable disks

Options for backup:
  --no-with-myfiles       Exclude 'My Files' in the backup
  --email <email>         Specify the email of the user to be backed up
  --password <pass>       Specify the password to verify user identity and encrypt the backup file
                          Please note that it is not recommended to specify the password directly in the command line parameters. This script will prompt the user to enter the password when needed
  --keyphrase <pass>      Specify the keyphrase to encrypt the backup file, if not specified, the script will generate a keyphrase automatically
  --target <filepath>     Specify the file path to store backup file
  -d, --debug             Enable debug mode

Options for restore:
  -f, --file <file>       Specify the backup file to restore from
  --restore-mode <mode>   Specify the restore mode: ${RESTORE_MODE_MERGE} or ${RESTORE_MODE_REPLACE} (default: ${DEFAULT_RESTORE_MODE})
  -n, --new               Indicate that the user to be restored is a new user
  --email <email>         Specify the email of the user to restore data, if -n/--new is specified, the script will create new user with the given email
  --password <pass>       Specify a password for new user's encrypted directory and decrypting backup file
                          Please note that it is not recommended to specify the password directly in the command line parameters. This script will prompt the user to enter the password when needed
  --special-key <key>     Specify the special key to encrypt the backup file, the script will try to decode the key to get the password
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
  if [[ -n "$PASSWORD" ]] && [[ "$COLOR" = "true" ]]; then
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
  debug "TARGET_BACKUP_FILE_PATH: $TARGET_BACKUP_FILE_PATH"
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
  if [[ "$ACTION" = "$ACTION_BACKUP" ]] && [[ -z "$TARGET_BACKUP_FILE_PATH" ]]; then
      fatal "The target backup file path is required for $ACTION action"
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

set_user_email_from_user_data() {
  local current_email=""
  current_email=$(get_current_user_email)
  if [[ -n "$current_email" ]] && [[ -n "$USER_EMAIL" ]] && [[ ! "$current_email" = "$USER_EMAIL" ]]; then
    fatal "The email of current user is different from the one specified in the command line arguments"
  fi
  if [[ -z "$USER_EMAIL" ]] && [[ -n "$current_email" ]]; then
    USER_EMAIL="$current_email"
  fi
}

do_backup() {
  set_log_prefix "backup"
  set_user_email_from_user_data
  if [[ -z "$USER_EMAIL" ]]; then
    prompt_for_email "backup"
  fi

  if ! is_current_login; then
    if is_cryptohome_mounted; then
      fatal "Please logout any session and run the script again"
    fi
    prompt_for_password
    trap "post_cryptohome_action" SIGINT SIGTERM ERR
    try_to_login_as_user "$USER_EMAIL" "$PASSWORD"
    assert_email_and_current_user_path "$USER_EMAIL"
  else
    assert_email_and_current_user_path "$USER_EMAIL"
    if [[ -z "$KEYPHRASE" ]]; then
      prompt_for_password
      verify_cryptohome_password "$USER_EMAIL" "$PASSWORD"
    fi
  fi


  print_files_to_backup_disk_usage

  tar_backup_files "$USER_EMAIL" "$PASSWORD" "$TARGET_BACKUP_FILE_PATH" "$KEYPHRASE"

  post_cryptohome_action
}

decode_keyphrase_for_password() {
  # the format is `B:base64(salt+password)`
  local key="$1"
  if [[ ! "$key" = "B:"* ]]; then
    echo ""
    return
  fi
  local content=""
  content=$(echo "$key" | cut -d ':' -f 2)
  if [[ -z "$content" ]]; then
    echo ""
    return
  fi
  local decoded=""
  decoded=$(echo "$content" | base64 -d)
  if [[ -z "$decoded" ]]; then
    echo ""
    return
  fi
  local salt=""
  salt=$(get_system_salt)
  if [[ -z "$salt" ]]; then
    echo ""
    return
  fi
  echo "${decoded#"$salt"}"
}

do_restore() {
  set_log_prefix "restore"
  assert_no_sudo_root
  if is_running_in_crosh; then
    die_with_usage "Please do not run the script inside crosh"
  fi
  if [[ -z "$PASSWORD" ]] && [[ -n "$KEYPHRASE" ]]; then
    PASSWORD=$(decode_keyphrase_for_password "$KEYPHRASE")
  fi
  local restore_path=""
  if [[ "$CREATE_NEW_USER" = "true" ]]; then
    local path=""
    path=$(get_mount_path_by_email "$USER_EMAIL")
    restore_path="$path"
    if [[ -d "$restore_path" ]]; then
      warn "The path $restore_path already exists. The script will try to restore data to this path"
      CREATE_NEW_USER="false"
    fi
  else
    set_user_email_from_user_data
    if [[ -z "$USER_EMAIL" ]]; then
      prompt_for_email "restore"
    fi
  fi
  if ! is_current_login; then
    if is_cryptohome_mounted; then
      fatal "Please logout any session or just reboot and run the script again"
    fi
    prompt_for_password
    DELAY_STOPPING_PROCESSES="true"
    if [[ ! "$CREATE_NEW_USER" = "true" ]]; then
      trap "post_cryptohome_action" SIGINT SIGTERM ERR
      try_to_login_as_user "$USER_EMAIL" "$PASSWORD"
      assert_email_and_current_user_path "$USER_EMAIL"
      restore_path=$(get_current_user_base_path)
    fi
  else
    assert_email_and_current_user_path "$USER_EMAIL"
    prompt_for_password
    verify_cryptohome_password "$USER_EMAIL" "$PASSWORD"
    restore_path=$(get_current_user_base_path)
  fi

  restore_backup_files "$USER_EMAIL" "$PASSWORD" "$BACKUP_FILE" "$restore_path" "$CREATE_NEW_USER"

  post_cryptohome_action
}

peek() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  tail -c "$BACKUP_FILE_TAIL_SIZE" "$file" | tr -d '\0'
}

parse_file_path() {
  local text="$1"
  if [[ "$text" = "/"* ]]; then
    echo "$text"
    return
  fi
  local result=""
  result=$(echo "$text" | base64 -d 2>/dev/null || echo "")
  echo "$result"
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
            --no-with-myfiles)
              WITH_MY_FILES="false"
              shift
              ;;
            --password)
              PASSWORD="$2"
              shift
              shift
              ;;
            --email)
              USER_EMAIL="$2"
              shift
              shift
              ;;
            --key)
              KEYPHRASE="$2"
              shift
              shift
              ;;
            --target)
              TARGET_BACKUP_FILE_PATH=$(parse_file_path "$2")
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
              BACKUP_FILE=$(parse_file_path "$2")
              shift
              shift
              ;;
            --email)
              USER_EMAIL="$2"
              shift
              shift
              ;;
            -n|--new)
              CREATE_NEW_USER="true"
              shift
              ;;
            --password)
              PASSWORD="$2"
              shift
              shift
              ;;
            --special-key)
              KEYPHRASE="$2"
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
      list)
        $LIST_BACKUP_FILE_LIST_BIN
        exit 0
        ;;
      auto-mount)
        $AUTO_MOUNT_BIN "unmount"
        sleep 1
        $AUTO_MOUNT_BIN
        exit 0
        ;;
      unmount)
        $AUTO_MOUNT_BIN "unmount"
        exit 0
        ;;
      peek)
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --file)
              BACKUP_FILE=$(parse_file_path "$2")
              shift
              shift
              ;;
            *)
              usage 1
              ;;
          esac
        done
        peek "$BACKUP_FILE"
        exit $?
        ;;
      -h|--help)
        usage
        ;;
      -v|--version)
        version
        exit 0
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

  version

  prepare_gpg

  assert_no_mount_and_not_login
  if [[ "$ACTION" = "$ACTION_BACKUP" ]]; then
    do_backup
  elif [[ "$ACTION" = "$ACTION_RESTORE" ]]; then
    do_restore
  fi
}

main "$@"
