#!/bin/bash

# Stop on command errors, unset variables, and failures inside pipelines.
set -euo pipefail

# Show the command syntax or report a clear input error.
usage() {
  printf 'Usage: %s [--scripts] <source-directory> [output.pkg]\n' "${0##*/}" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# Package files are the default; --scripts switches to shell-script mode.
item_mode=packages
if [[ ${1-} == --scripts ]]; then
  item_mode=scripts
  shift
fi

# Accept a source folder and an optional output package path.
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

# pkgbuild is part of macOS; fail early if this is not a suitable build host.
command -v pkgbuild >/dev/null 2>&1 || fail "pkgbuild is required; run this script on macOS."

# Resolve the source path and reject the filesystem root as an unsafe input.
source_input=$1
[[ -d "$source_input" ]] || fail "Source directory does not exist: $source_input"
source_dir=$(cd "$source_input" && pwd -P)
[[ "$source_dir" != "/" ]] || fail "The filesystem root cannot be used as the source directory."

# Derive a stable package identifier from the source folder name.
source_name=${source_dir##*/}
safe_name=$(printf '%s' "$source_name" |
  tr '[:upper:]' '[:lower:]' |
  sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//')
[[ -n "$safe_name" ]] || safe_name=source
package_identifier="com.pkgpreptool.$safe_name"

# Use the requested output path, or default to a sibling named after the source.
if [[ $# -eq 2 ]]; then
  output_input=$2
else
  output_input="$(dirname "$source_dir")/$source_name.pkg"
fi

# Normalize and validate the output location so it cannot overwrite input files.
output_name=${output_input##*/}
[[ "$output_name" == *.pkg ]] || fail "Output filename must end in .pkg: $output_input"
output_parent=${output_input%/*}
[[ "$output_parent" != "$output_input" ]] || output_parent=.
[[ -d "$output_parent" ]] || fail "Output directory does not exist: $output_parent"
output_parent=$(cd "$output_parent" && pwd -P)
output_path="$output_parent/$output_name"
[[ ! -e "$output_path" && ! -L "$output_path" ]] ||
  fail "Output already exists; move or remove it first: $output_path"
if [[ "$output_path" == "$source_dir" || "$output_path" == "$source_dir/"* ]]; then
  fail "Output package must be outside the source directory."
fi

# Find the selected items recursively; NUL separators safely handle unusual names.
items=()
if [[ "$item_mode" == scripts ]]; then
  while IFS= read -r -d '' item; do
    items+=("$item")
  done < <(find "$source_dir" -type f \( -name '*.sh' -o -name '*.zsh' \) -print0)
  item_description="shell scripts (.sh and .zsh)"
else
  while IFS= read -r -d '' item; do
    items+=("$item")
  done < <(find "$source_dir" -type f -name '*.pkg' -print0)
  item_description=".pkg files"
fi

[[ ${#items[@]} -gt 0 ]] || fail "No $item_description found in: $source_dir"

# Sort paths alphabetically so every wrapper processes items predictably.
for ((i = 1; i < ${#items[@]}; i++)); do
  current=${items[i]}
  j=$((i - 1))
  while ((j >= 0)) && [[ "$current" < "${items[j]}" ]]; do
    items[j + 1]=${items[j]}
    j=$((j - 1))
  done
  items[j + 1]=$current
done

# Build in a temporary workspace and remove it whether the build succeeds or fails.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pkgprep.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# Stage the entire source tree so packages can access sibling files and folders.
# ditto preserves the source tree structure and macOS file metadata.
package_base="$work_dir/payload/Library/Application Support/PKGPrepTool/$package_identifier"
source_stage="$package_base/source"
item_manifest="$package_base/items.list"
mkdir -p "$package_base" "$work_dir/scripts"
ditto "$source_dir" "$source_stage"

# Record sorted item paths relative to the source root using NUL separators.
# The manifest stays outside the copied source tree so its contents remain unchanged.
for item in "${items[@]}"; do
  printf '%s\0' "${item#"$source_dir"/}" >> "$item_manifest"
done

# This script runs after the wrapper's payload is installed. It installs each staged
# package on the startup disk, records failures, and removes the temporary payload.
cat > "$work_dir/scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash

set -u

# The builder replaces this token with the wrapper's package identifier.
payload_root="/Library/Application Support/PKGPrepTool/@PACKAGE_IDENTIFIER@"
source_dir="$payload_root/source"
item_manifest="$payload_root/items.list"
item_mode="@ITEM_MODE@"
log_dir="/Library/Application Support/PKGPrepTool"
failures=0

# Always remove the embedded packages after attempting installation.
cleanup() {
  /bin/rm -rf "$payload_root"
}
trap cleanup EXIT

# Create a unique, timestamped log and duplicate all output to it and Installer.
if ! /bin/mkdir -p "$log_dir"; then
  printf 'Error: could not create log directory: %s\n' "$log_dir" >&2
  exit 1
fi
log_timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
log_file="$log_dir/@PACKAGE_IDENTIFIER@-$log_timestamp-$$.log"
if ! (umask 022; set -o noclobber; : > "$log_file"); then
  printf 'Error: could not create log file: %s\n' "$log_file" >&2
  exit 1
fi
exec > >(/usr/bin/tee -a "$log_file") 2>&1
printf 'Started at %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')"
printf 'Log file: %s\n' "$log_file"

# A missing source tree or manifest means the wrapper payload is incomplete.
if [[ ! -d "$source_dir" || ! -f "$item_manifest" ]]; then
  printf 'Error: embedded source tree or package manifest is missing.\n' >&2
  exit 1
fi

# Process items in the sorted order recorded by the builder. Run each from its
# containing folder so companion files remain available through relative paths.
while IFS= read -r -d '' relative_item; do
  item="$source_dir/$relative_item"
  if [[ ! -f "$item" ]]; then
    printf 'Error: embedded item is missing: %s\n' "$relative_item" >&2
    failures=$((failures + 1))
    continue
  fi
  printf 'Processing %s\n' "$relative_item"
  if [[ "$item_mode" == scripts ]]; then
    case "${item##*.}" in
      sh) interpreter=/bin/bash ;;
      zsh) interpreter=/bin/zsh ;;
      *)
        printf 'Error: unsupported script type: %s\n' "$relative_item" >&2
        failures=$((failures + 1))
        continue
        ;;
    esac
    if (cd "${item%/*}" && "$interpreter" "$item"); then
      :
    else
      printf 'Error: failed to run %s\n' "$relative_item" >&2
      failures=$((failures + 1))
    fi
  elif (cd "${item%/*}" && /usr/sbin/installer -pkg "$item" -target /); then
    :
  else
    printf 'Error: failed to install %s\n' "$relative_item" >&2
    failures=$((failures + 1))
  fi
done < "$item_manifest"

printf 'Finished at %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')"

# Return a failure status to Installer if any item failed.
if ((failures > 0)); then
  printf 'Error: %d embedded item(s) failed.\n' "$failures" >&2
  exit 1
fi

if [[ "$item_mode" == scripts ]]; then
  printf 'All embedded scripts ran successfully.\n'
else
  printf 'All embedded packages installed successfully.\n'
fi
exit 0
POSTINSTALL

# Fill in package-specific values and mark the script executable for Installer.
sed -e "s/@PACKAGE_IDENTIFIER@/$package_identifier/g" \
  -e "s/@ITEM_MODE@/$item_mode/g" \
  "$work_dir/scripts/postinstall" > "$work_dir/scripts/postinstall.tmp"
mv "$work_dir/scripts/postinstall.tmp" "$work_dir/scripts/postinstall"
chmod 755 "$work_dir/scripts/postinstall"

# Create the single outer package containing the staged packages and postinstall script.
pkgbuild \
  --root "$work_dir/payload" \
  --scripts "$work_dir/scripts" \
  --identifier "$package_identifier" \
  --version "1.0" \
  --install-location / \
  "$output_path"

# Report where the wrapper was written and how many packages it contains.
printf 'Created package: %s\n' "$output_path"
printf 'Embedded %s: %d (alphabetical by source path)\n' "$item_description" "${#items[@]}"
