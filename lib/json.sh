#!/usr/bin/env bash

# shellcheck source=./lib/base.sh
source "$SCRIPT_LIB_DIR/base.sh"

[[ "${_JSON_SCRIPT_SOURCE:-""}" == "yes" ]] && return 0
_JSON_SCRIPT_SOURCE=yes

SOURCE_JSON_FILE=""

LOCAL_STATE_JSON_FILE="/home/chronos/Local State"
readonly LOCAL_STATE_JSON_FILE

KEY_KNOWN_USERS="KnownUsers"
readonly KEY_KNOWN_USERS

KEY_LAST_ACTIVE_USER="LastActiveUser"
readonly KEY_LAST_ACTIVE_USER

KEY_LOGGED_IN_USERS="LoggedInUsers"
readonly KEY_LOGGED_IN_USERS

KEY_OAUTH_TOKEN_STATUS="OAuthTokenStatus"
readonly KEY_OAUTH_TOKEN_STATUS

KEY_USER_DISPLAY_EMAIL="UserDisplayEmail"
readonly KEY_USER_DISPLAY_EMAIL

KEY_USER_DISPLAY_NAME="UserDisplayName"
readonly KEY_USER_DISPLAY_NAME

KEY_USER_FORCE_ONLINE_SIGNIN="UserForceOnlineSignin"
readonly KEY_USER_FORCE_ONLINE_SIGNIN

KEY_USER_GIVEN_NAME="UserGivenName"
readonly KEY_USER_GIVEN_NAME

KEY_EASY_UNLOCK="easy_unlock"
readonly KEY_EASY_UNLOCK
KEY_EASY_UNLOCK_USER_PREFS="user_prefs"
readonly KEY_EASY_UNLOCK_USER_PREFS

KEY_PROFILE="profile"
readonly KEY_PROFILE
KEY_PROFILE_INFO_CACHE="info_cache"
readonly KEY_PROFILE_INFO_CACHE

KEY_USER_IMAGE_INFO="user_image_info"
readonly KEY_USER_IMAGE_INFO

KEY_USER_WALLPAPER_INFO="user_wallpaper_info"
readonly KEY_USER_WALLPAPER_INFO

KEY_OOBE_COMPLETE="OobeComplete"
readonly KEY_OOBE_COMPLETE

get_from_known_users() {
  local json="$1"
  local email="$2"
  echo "$json" | jq -r ".${KEY_KNOWN_USERS}[] | select(.email == \"${email}\")"
}

is_last_active_user() {
  local email="$1"
  local last=""
  last=$(jq -r ".${KEY_LAST_ACTIVE_USER}" "$SOURCE_JSON_FILE")
  [[ "$email" = "$last" ]]
}

is_logged_in_users() {
  local json="$1"
  local email="$2"
  if [[ -z $json ]]; then
    json=$(cat "$SOURCE_JSON_FILE")
  fi
  local result=""
  result=$(echo "$json" | jq -r ".${KEY_LOGGED_IN_USERS} | index(\"${email}\") != null")
  [[ "$result" = "true" ]]
}

get_oauth_token_status() {
  local email="$1"
  jq -r ".${KEY_OAUTH_TOKEN_STATUS}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_user_display_email() {
  local email="$1"
  jq -r ".${KEY_USER_DISPLAY_EMAIL}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_user_display_name() {
  local email="$1"
  jq -r ".${KEY_USER_DISPLAY_NAME}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_user_force_online_signin() {
  local email="$1"
  jq -r ".${KEY_USER_FORCE_ONLINE_SIGNIN}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_user_given_name() {
  local email="$1"
  jq -r ".${KEY_USER_GIVEN_NAME}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_from_easy_unlock() {
  local email="$1"
  jq -r ".${KEY_EASY_UNLOCK}.${KEY_EASY_UNLOCK_USER_PREFS}.\"${email}\"" "$SOURCE_JSON_FILE"
}

generate_user_hash() {
  local email="$1"
  local hash=""
  hash=$(get_hash_from_email "$email")
  if [[ -n "$hash" ]]; then
    echo "u-$hash"
  fi
}

get_from_profile_info_cache() {
  local email="$1"
  local hash=""
  hash=$(generate_user_hash "$email")
  if [[ -n "$hash" ]]; then
    jq -r ".${KEY_PROFILE}.${KEY_PROFILE_INFO_CACHE}.\"${hash}\"" "$SOURCE_JSON_FILE"
  fi
}

get_user_image_info() {
  local email="$1"
  jq -r ".${KEY_USER_IMAGE_INFO}.\"${email}\"" "$SOURCE_JSON_FILE"
}

get_user_image_info_path() {
  local email="$1"
  jq -r ".${KEY_USER_IMAGE_INFO}.\"${email}\".path" "$SOURCE_JSON_FILE"
}

get_user_wallpaper_info() {
  local email="$1"
  jq -r ".${KEY_USER_WALLPAPER_INFO}.\"${email}\"" "$SOURCE_JSON_FILE"
}

JSON_TEMPLATE="$(cat <<EOF
{
  "${KEY_KNOWN_USERS}": [],
  "${KEY_LAST_ACTIVE_USER}": "",
  "${KEY_LOGGED_IN_USERS}": [],
  "${KEY_OAUTH_TOKEN_STATUS}": {},
  "${KEY_USER_DISPLAY_EMAIL}": {},
  "${KEY_USER_DISPLAY_NAME}": {},
  "${KEY_USER_FORCE_ONLINE_SIGNIN}": {},
  "${KEY_USER_GIVEN_NAME}": {},
  "${KEY_EASY_UNLOCK}": {
    "${KEY_EASY_UNLOCK_USER_PREFS}": {}
  },
  "$KEY_USER_IMAGE_INFO": {},
  "$KEY_USER_WALLPAPER_INFO": {}
}
EOF
)"

insert_into_known_users() {
  local json="$1"
  local email="$2"
  local content="$3"
  local find=""
  find=$(get_from_known_users "$json" "$email")
  if is_empty_content "$find"; then
    echo "$json" | jq ".${KEY_KNOWN_USERS} |= .+ [$content]"
  fi
}

set_last_active_user() {
 local json="$1"
 local email="$2"
 echo "$json" | jq ".${KEY_LAST_ACTIVE_USER} = \"${email}\""
}

append_logged_in_users() {
  local json="$1"
  local email="$2"
  if ! is_logged_in_users "$json" "$email"; then
    echo "$json" | jq ".${KEY_LOGGED_IN_USERS} |= .+ [\"${email}\"]"
  fi
}

insert_into_oauth_token_status() {
  local json="$1"
  local status="$2"
  echo "$json" | jq ".${KEY_OAUTH_TOKEN_STATUS}.\"${email}\" = ${status}"
}

insert_into_user_display_email() {
  local json="$1"
  local email="$2"
  local display="$3"
  echo "$json" | jq ".${KEY_USER_DISPLAY_EMAIL}.\"${email}\" = \"${display}\""
}

insert_into_user_display_name() {
  local json="$1"
  local email="$2"
  local name="$3"
  echo "$json" | jq ".${KEY_USER_DISPLAY_NAME}.\"${email}\" = \"${name}\""
}

insert_into_user_force_online_signin() {
  local json="$1"
  local email="$2"
  local value="$3"
  # ignore the value not true or false
  if [[ "$value" = "true" ]]; then
    echo "$json" | jq ".${KEY_USER_FORCE_ONLINE_SIGNIN}.\"${email}\" = true"
  elif [[ "$value" = "false" ]]; then
    echo "$json" | jq ".${KEY_USER_FORCE_ONLINE_SIGNIN}.\"${email}\" = false"
  fi
}

insert_into_user_given_name() {
  local json="$1"
  local email="$2"
  local name="$3"
  echo "$json" | jq ".${KEY_USER_GIVEN_NAME}.\"${email}\" = \"${name}\""
}

insert_into_easy_unlock_user_prefs() {
  local json="$1"
  local email="$2"
  local pref="$3"
  echo "$json" | jq ".${KEY_EASY_UNLOCK}.${KEY_EASY_UNLOCK_USER_PREFS}.\"${email}\" = ${pref}"
}

insert_into_profile_info_cache() {
  local json="$1"
  local email="$2"
  local content="$3"
  local hash=""
  hash=$(generate_user_hash "$email")
  echo "$json" | jq ".${KEY_PROFILE}.${KEY_PROFILE_INFO_CACHE}.\"${hash}\" = ${content}"
}

insert_into_user_image_info() {
  local json="$1"
  local content="$2"
  echo "$json" | jq ".${KEY_USER_IMAGE_INFO}.\"${email}\" = ${content}"
}

insert_into_user_wallpaper_info() {
  local json="$1"
  local content="$2"
  echo "$json" | jq ".${KEY_USER_WALLPAPER_INFO}.\"${email}\" = ${content}"
}

is_empty_content() {
  local content="$1"
  [[ -z "$content" ]] || [[ "$content" = "null" ]]
}

read_and_merge_json() {
  local email="$1"
  local target_file="$2"
  SOURCE_JSON_FILE="$3"

  local known_user=""
  local last_active_user="false"
  local logged_in_user="false"
  local oauth_token_status=""
  local display_email=""
  local display_name=""
  local user_force_online_signin="false"
  local given_name=""
  local easy_unlock_user_pref=""
  local profile_info_cache=""
  local image_info=""
  local wallpaper_info=""
  known_user=$(get_from_known_users "$(cat "$SOURCE_JSON_FILE")" "$email")
  if is_last_active_user "$email"; then
    last_active_user="true"
  fi
  if is_logged_in_users "$(cat "$SOURCE_JSON_FILE")" "$email"; then
    logged_in_user="true"
  fi
  oauth_token_status=$(get_oauth_token_status "$email")
  display_email=$(get_user_display_email "$email")
  display_name=$(get_user_display_name "$email")
  user_force_online_signin=$(get_user_force_online_signin "$email")
  given_name=$(get_user_given_name "$email")
  easy_unlock_user_pref=$(get_from_easy_unlock "$email")
  profile_info_cache=$(get_from_profile_info_cache "$email")
  image_info=$(get_user_image_info "$email")
  wallpaper_info=$(get_user_wallpaper_info "$email")

  local json=""
  json=$(cat "$target_file")

  json=$(insert_into_known_users "$json" "$email" "$known_user")

  if [[ "$last_active_user" = "true" ]]; then
    json=$(set_last_active_user "$json" "$email")
  fi

  if [[ "$logged_in_user" = "true" ]]; then
    json=$(append_logged_in_users "$json" "$email")
  fi

  if ! is_empty_content "$oauth_token_status"; then
    json=$(insert_into_oauth_token_status "$json" "$oauth_token_status")
  fi

  if ! is_empty_content "$display_email"; then
    json=$(insert_into_user_display_email "$json" "$email" "$display_email")
  fi

  if ! is_empty_content "$display_name"; then
    json=$(insert_into_user_display_name "$json" "$email" "$display_name")
  fi

  if ! is_empty_content "$user_force_online_signin"; then
    json=$(insert_into_user_force_online_signin "$json" "$email" "$user_force_online_signin")
  fi

  if ! is_empty_content "$given_name"; then
    json=$(insert_into_user_given_name "$json" "$email" "$given_name")
  fi

  if ! is_empty_content "$easy_unlock_user_pref"; then
    json=$(insert_into_easy_unlock_user_prefs "$json" "$email" "$easy_unlock_user_pref")
  fi

  if ! is_empty_content "$profile_info_cache"; then
    json=$(insert_into_profile_info_cache "$json" "$email" "$profile_info_cache")
  fi

  if ! is_empty_content "$image_info"; then
    json=$(insert_into_user_image_info "$json" "$image_info")
  fi

  if ! is_empty_content "$wallpaper_info"; then
    json=$(insert_into_user_wallpaper_info "$json" "$wallpaper_info")
  fi

  echo "$json" > "$target_file"
}

save_local_state_for_user() {
  local email="$1"
  local target_file="$2"
  local json="$JSON_TEMPLATE"
  echo "$json" > "$target_file"

  read_and_merge_json "$email" "$target_file" "$LOCAL_STATE_JSON_FILE"
}

set_oobe_complete() {
  local json=""
  json="$(cat "$LOCAL_STATE_JSON_FILE")"
  echo "$json" | jq ".${KEY_OOBE_COMPLETE} = true" > "$LOCAL_STATE_JSON_FILE"

  set_oobe_complete_mark
}
