#!/usr/bin/env bash

SCRIPT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_ROOT_DIR/common.sh"

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
    prompt="The current logged-in user is $USER_EMAIL, please enter the login password to verify your identity, and the password will be used to encrypt the backup file:"
  elif [[ "$ACTION" = "$ACTION_RESTORE" ]] && [[ "$CREATE_NEW_USER" = "true" ]]; then
    prompt="Please enter the password for decrypting the backup file and create encrypted directory for the new user:"
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
  local prompt="Please enter the email of current logged-in user, which is the email of the account you want to backup:"
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

do_backup() {
  USER_EMAIL=$(get_current_user_email)
  if [[ -z "$USER_EMAIL" ]]; then
    prompt_for_email
  fi
  prompt_for_password
  verify_cryptohome_password "$USER_EMAIL" "$PASSWORD"

  print_files_to_backup_disk_usage

  tar_backup_files "$USER_EMAIL" "$PASSWORD"
}

main() {
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
              USER_EMAIL="$2"
              shift
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
  print_params
  verify_params

  prepare_gpg
  if [[ "$ACTION" = "$ACTION_BACKUP" ]]; then
    do_backup
  fi
}

main "$@"
