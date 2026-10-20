#!/usr/bin/env bash

# Source local development overrides without replacing values explicitly
# exported by the calling process. This file is intentionally a shared helper:
# callers choose their repository-local env file and keep parsing in one place.
load_local_env() {
  local env_file="${1:?env file path is required}"
  [[ -f "$env_file" ]] || return 0

  local had_allexport=0
  local index
  local name
  local declaration
  local -a inherited_names=()
  local -a inherited_values=()

  [[ "$-" == *a* ]] && had_allexport=1
  while IFS= read -r name; do
    declaration="$(declare -p "$name" 2>/dev/null || true)"
    [[ "$declaration" == 'declare -r'* || "$declaration" == 'declare -rx'* ]] && continue
    inherited_names+=("$name")
    inherited_values+=("${!name}")
  done < <(compgen -e)

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  ((had_allexport)) || set +a

  for ((index = 0; index < ${#inherited_names[@]}; index++)); do
    export "${inherited_names[$index]}=${inherited_values[$index]}"
  done
}
