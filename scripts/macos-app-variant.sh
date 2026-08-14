#!/usr/bin/env bash
# Shared reader for the canonical macOS Debug/Release identity xcconfig files.

SHOTPASTE_MACOS_VARIANT_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOTPASTE_MACOS_VARIANT_REPOSITORY_ROOT="$(cd "$SHOTPASTE_MACOS_VARIANT_HELPER_DIR/.." && pwd)"

macos_app_variant_config_path() {
  local configuration="$1"

  case "$configuration" in
    Debug)
      printf "%s/platforms/mac/ShotPaste/Config/AppVariant-Debug.xcconfig" \
        "$SHOTPASTE_MACOS_VARIANT_REPOSITORY_ROOT"
      ;;
    Release)
      printf "%s/platforms/mac/ShotPaste/Config/AppVariant-Release.xcconfig" \
        "$SHOTPASTE_MACOS_VARIANT_REPOSITORY_ROOT"
      ;;
    *)
      printf "error: Unsupported macOS app configuration '%s'.\n" "$configuration" >&2
      return 1
      ;;
  esac
}

macos_app_variant_setting() {
  local configuration="$1"
  local setting_name="$2"
  local config_path
  local setting_value

  config_path="$(macos_app_variant_config_path "$configuration")" || return 1
  [[ -f "$config_path" ]] || {
    printf "error: macOS app variant config not found: %s\n" "$config_path" >&2
    return 1
  }

  setting_value="$(/usr/bin/awk -v setting_name="$setting_name" '
    $0 ~ "^[[:space:]]*" setting_name "[[:space:]]*=" {
      line = $0
      sub("^[[:space:]]*" setting_name "[[:space:]]*=[[:space:]]*", "", line)
      sub("[[:space:]]*$", "", line)
      print line
      exit
    }
  ' "$config_path")"

  [[ -n "$setting_value" ]] || {
    printf "error: Missing %s in %s.\n" "$setting_name" "$config_path" >&2
    return 1
  }
  printf "%s" "$setting_value"
}

macos_app_variant_validate_configuration() {
  local configuration="$1"
  local expected_variant
  local configured_variant

  case "$configuration" in
    Debug) expected_variant="debug" ;;
    Release) expected_variant="release" ;;
    *)
      macos_app_variant_config_path "$configuration" >/dev/null
      return 1
      ;;
  esac

  configured_variant="$(macos_app_variant_setting "$configuration" SHOTPASTE_VARIANT)" || return 1
  [[ "$configured_variant" == "$expected_variant" ]] || {
    printf "error: %s configuration declares variant '%s'; expected '%s'.\n" \
      "$configuration" "$configured_variant" "$expected_variant" >&2
    return 1
  }
}
