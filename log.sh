#!/usr/bin/env bash

LOG_LEVEL=${LOG_LEVEL:-"info"}

COLOR=${COLOR:-"true"}

V_BOLD_RED=$'\e[1;31m'
V_BOLD_GREEN=$'\e[1;32m'
V_BOLD_YELLOW=$'\e[1;33m'
V_VIDOFF=$'\e[m'
if [[ "$COLOR" = "false" ]]; then
  unset V_BOLD_RED
  unset V_BOLD_GREEN
  unset V_BOLD_YELLOW
  unset V_VIDOFF
fi

LOG_RUNTIME_PREFIX=${LOG_RUNTIME_PREFIX:-"fydeos_backup"}

_message() {
  local level="$1"
  local prefix=""
  prefix="$(date +"%Y-%m-%d %H:%M:%S") $level [${LOG_RUNTIME_PREFIX}]"
  shift

  if [[ $# -eq 0 ]]; then
    return
  fi

  (

    IFS="
"
    set +f
    # shellcheck disable=SC2048,SC2086
    set -- $*
    IFS=' '
    if [[ $# -eq 0 ]]; then
      set -- ''
    fi
    for line in "$@"; do
      echo -e "${prefix} ${line}${V_VIDOFF}" >&2
    done
  )
}

info() {
  if [[ $LOG_LEVEL =~ debug|info ]]; then
    _message "${V_BOLD_GREEN}- INFO  -" "$*"
  fi
}

warn() {
 if [[ $LOG_LEVEL =~ debug|info|warn ]]; then
   _message "${V_BOLD_YELLOW}- WARN  -" "$*"
 fi
}

error() {
  if [[ $LOG_LEVEL =~ debug|info|warn|error ]]; then
    _message "${V_BOLD_RED}- ERROR -" "$*"
  fi
}

debug() {
  if [[ $LOG_LEVEL =~ debug ]]; then
    _message "- DEBUG -" "$*"
  fi
}

fatal() {
  if [[ ! $LOG_LEVEL =~ none ]]; then
    _message "${V_BOLD_RED}- FATAL -" "$*"
  fi
  exit 1
}

set_log_prefix() {
  local prefix="$1"
  LOG_RUNTIME_PREFIX="$prefix"
}
