#!/usr/bin/env bash

# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

AUTH_SESSION_ID=""

start_auth_session() {
  local email="$1"
  AUTH_SESSION_ID=$(cryptohome --action=start_auth_session --user="$email" \
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


remove_user_description() {
  local email="$1"
  echo "If you want to remove the user created by this script, please run the commands below:"
  echo "$ cryptohome --action=unmount"
  echo "$ cryptohome --action=remove --user=${email}"
}

post_cryptohome_action() {
  debug "AUTH_SESSION_ID: $AUTH_SESSION_ID"
  if [[ -n "$AUTH_SESSION_ID" ]]; then
    invalidate_auth_session > /dev/null 2>&1 || true
    cryptohome_unmount > /dev/null 2>&1 || true
  fi
}

create_user() {
  AUTH_SESSION_ID=""
  local email="$1"
  local password="$2"
  info "Creating user ${email}"

  start_auth_session "$email"
  create_persistent_user
  prepare_persistent_vault
  add_auth_factor "$password"
}

authenticate_auth_factor() {
  local password="$1"

  cryptohome --action=authenticate_auth_factor \
    --auth_session_id="$AUTH_SESSION_ID" \
    --key_label="gaia" \
    --password="$password"
}

try_to_login_as_user() {
  AUTH_SESSION_ID=""
  local email="$1"
  local password="$2"
  info "Trying to login user $email"
  start_auth_session "$email"
  authenticate_auth_factor "$password"
  prepare_persistent_vault
}

