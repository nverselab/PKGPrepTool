#!/bin/bash

# Stop on command errors, unset variables, and failures inside pipelines.
set -euo pipefail

# Show the command syntax or report a clear input error.
usage() {
  printf 'Usage: %s <source-directory> [output.pkg]\n' "${0##*/}" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

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

# Find regular .pkg files recursively; NUL separators safely handle unusual names.
packages=()
while IFS= read -r -d '' package; do
  packages+=("$package")
done < <(find "$source_dir" -type f -name '*.pkg' -print0)

[[ ${#packages[@]} -gt 0 ]] || fail "No .pkg files found in: $source_dir"

# Sort paths alphabetically so every wrapper installs packages in a predictable order.
for ((i = 1; i < ${#packages[@]}; i++)); do
  current=${packages[i]}
  j=$((i - 1))
  while ((j >= 0)) && [[ "$current" < "${packages[j]}" ]]; do
    packages[j + 1]=${packages[j]}
    j=$((j - 1))
  done
  packages[j + 1]=$current
done

# Build in a temporary workspace and remove it whether the build succeeds or fails.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pkgprep.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# Stage the entire source tree so packages can access sibling files and folders.
# ditto preserves the source tree structure and macOS file metadata.
package_base="$work_dir/payload/Library/Application Support/PKGPrepTool/$package_identifier"
source_stage="$package_base/source"
package_manifest="$package_base/packages.list"
mkdir -p "$package_base" "$work_dir/scripts"
ditto "$source_dir" "$source_stage"

# Record sorted package paths relative to the source root using NUL separators.
# The manifest stays outside the copied source tree so its contents remain unchanged.
for package in "${packages[@]}"; do
  printf '%s\0' "${package#"$source_dir"/}" >> "$package_manifest"
done

# This script runs after the wrapper's payload is installed. It installs each staged
# package on the startup disk, records failures, and removes the temporary payload.
cat > "$work_dir/scripts/postinstall" <<'POSTINSTALL'
#!/bin/bash

set -u

# The builder replaces this token with the wrapper's package identifier.
payload_root="/Library/Application Support/PKGPrepTool/@PACKAGE_IDENTIFIER@"
source_dir="$payload_root/source"
package_manifest="$payload_root/packages.list"
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
if [[ ! -d "$source_dir" || ! -f "$package_manifest" ]]; then
  printf 'Error: embedded source tree or package manifest is missing.\n' >&2
  exit 1
fi

# Install packages in the sorted order recorded by the builder. Run Installer from
# each package's containing folder so adjacent source files remain available.
while IFS= read -r -d '' relative_package; do
  package="$source_dir/$relative_package"
  if [[ ! -f "$package" ]]; then
    printf 'Error: embedded package is missing: %s\n' "$relative_package" >&2
    failures=$((failures + 1))
    continue
  fi
  printf 'Installing %s\n' "$relative_package"
  if (cd "${package%/*}" && /usr/sbin/installer -pkg "$package" -target /); then
    :
  else
    printf 'Error: failed to install %s\n' "$relative_package" >&2
    failures=$((failures + 1))
  fi
done < "$package_manifest"

printf 'Finished at %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')"

# Return a failure status to Installer if any nested package could not be installed.
if ((failures > 0)); then
  printf 'Error: %d embedded package(s) failed to install.\n' "$failures" >&2
  exit 1
fi

printf 'All embedded packages installed successfully.\n'
exit 0
POSTINSTALL

# Fill in the package-specific payload path and mark the script executable for Installer.
sed "s/@PACKAGE_IDENTIFIER@/$package_identifier/g" \
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
printf 'Embedded packages: %d (alphabetical by source path)\n' "${#packages[@]}"
