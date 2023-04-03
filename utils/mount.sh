#!/usr/bin/env bash

DBUS_SEND_BIN="dbus-send"
DBUS_DESTINATION="org.chromium.CrosDisks"
DBUS_INTERFACE="org.chromium.CrosDisks"
DBUS_OBJECT_PATH="/org/chromium/CrosDisks"
readonly DBUS_SEND_BIN DBUS_DESTINATION DBUS_INTERFACE DBUS_OBJECT_PATH

DBUS_ARGS="--system --dest=$DBUS_DESTINATION --print-reply --fixed --type=method_call $DBUS_OBJECT_PATH"

dbus_method() {
  local method="$1"
  shift
  sh -c "$DBUS_SEND_BIN $DBUS_ARGS $DBUS_INTERFACE.$method $*"
}


unmount_all() {
  dbus_method "UnmountAll"
}

enumerate_devices() {
  dbus_method "EnumerateDevices" | awk '{print $2}'
}

get_device_properties() {
  local device_path="$1"
  dbus_method "GetDeviceProperties" "string:\"$device_path\""
}

get_value_from_raw_string() {
  local raw="$1"
  local key="$2"
  echo -n "$raw" | grep "$key" | head -n1 | awk '{print $2}'
}

get_boolean_from_raw_string() {
  local raw="$1"
  local key="$2"
  local result=""
  result=$(get_value_from_raw_string "$raw" "$key")
  [[ "$result" = "true" ]]
}

check_is_hidden() {
  get_boolean_from_raw_string "$1" "DevicePresentationHide"
}

check_has_media() {
  get_boolean_from_raw_string "$1" "DeviceIsMediaAvailable"
}

check_is_mounted() {
  get_boolean_from_raw_string "$1" "DeviceIsMounted"
}

get_mount_path() {
  local raw="$1"
  get_value_from_raw_string "$raw" "DeviceMountPaths"
}

can_mount() {
  local properties_raw="$1"
  local is_hidden="false"
  local has_media="false"
  local mounted="false"
  local mount_path_empty="false"
  if check_is_hidden "$properties_raw"; then
    is_hidden="true"
  else
    is_hidden="false"
  fi
  if check_has_media "$properties_raw"; then
    has_media="true"
  else
    has_media="false"
  fi
  if check_is_mounted "$properties_raw"; then
    mounted="true"
  else
    mounted="false"
  fi
  if [[ -n "$(get_mount_path "$properties_raw")" ]]; then
    mount_path_empty="false"
  else
    mount_path_empty="true"
  fi

  # echo "device_path: $device_path"
  # echo "is_hidden: $is_hidden"
  # echo "has_media: $has_media"
  # echo "mounted: $mounted"
  # echo "mount_path_empty: $mount_path_empty"
  [[ "$mounted" = "false" ]] && [[ "$mount_path_empty" = "true" ]] && [[ "$is_hidden" = "false" ]] && [[ "$has_media" = "true" ]]
}

mount_device() {
  local device_path="$1"
  local label="$2"
  dbus_method "Mount" "string:\"$device_path\"" \
                      "string:\"\"" \
                      "array:string:\"ro\",\"mountlabel=$label\""
}

maybe_mount() {
  local device_path="$1"
  local properties_raw=""
  properties_raw=$(get_device_properties "$device_path")

  if can_mount "$properties_raw"; then
    echo "Mount $device_path"
    local label=""
    label=$(get_value_from_raw_string "$properties_raw" "IdLabel")

    mount_device "$device_path" "$label"
  else
    echo "Skip device $device_path"
  fi
}

main() {
  if [[ "$1" = "unmount" ]]; then
    unmount_all
    exit 0
  fi
  enumerate_devices | while read -r device; do
    maybe_mount "$device"
  done
}

main "$@"
