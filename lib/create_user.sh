#!/usr/bin/env bash

# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

start_auth_session() {
  local email="$1"
  AUTH_SESSION_ID=$(cryptohome --action=start_auth_session --user="$email" \
    | tee /dev/tty \
    | grep -oE 'auth_session_id: .*' | awk '{print $2}')
  if [[ -z "$AUTH_SESSION_ID" ]]; then
    echo "Failed to start auth session"
    exit 1
  fi
}

create_persistent_user() {
  cryptohome --action=create_persistent_user \
    --auth_session_id="$AUTH_SESSION_ID"
}

prepare_persistent_vault() {
  cryptohome --action=prepare_persistent_vault \
    --auth_session_id="$AUTH_SESSION_ID"
}

add_auth_factor() {
  local password="$1"
  cryptohome --action=add_auth_factor \
    --auth_session_id="$AUTH_SESSION_ID" \
    --key_label="gaia" \
    --password="$password"
}

invalidate_auth_session() {
  cryptohome --action=invalidate_auth_session \
    --auth_session_id="$AUTH_SESSION_ID"
}

cryptohome_unmount() {
  cryptohome --action=unmount
}

create_user() {
  local email="$1"
  local password="$2"

  start_auth_session "$email"
  create_persistent_user
  prepare_persistent_vault
  add_auth_factor "$password"
}

remove_user_description() {
  local email="$1"
  echo "You may want to remove the user created by this script, please run the commands below:"
  echo "$ cryptohome --action=unmount"
  echo "$ cryptohome --action=remove --user=${email}"
}
