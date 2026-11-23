# PKG Prep Tool

PKG Prep Tool builds one macOS installer package from a source directory. The
wrapper includes the entire source tree so embedded packages or scripts can
use companion files and folders while they run.

## Requirements

- macOS
- The `pkgbuild` command-line tool
- Administrator privileges when installing the generated package

## Directions

1. Put the `.pkg` files (or shell scripts) and any companion files or folders
   they need in a source directory. The directory's full contents, including
   hidden files and nested folders, are included with their relative structure
   preserved.
2. From Terminal, run the script with the source directory for the default
   package mode:

   ```sh
   ./create-nested-pkg.sh /path/to/source-directory
   ```

   To run `.sh` and `.zsh` files instead, pass `--scripts` before the source
   directory:

   ```sh
   ./create-nested-pkg.sh --scripts /path/to/source-directory
   ```

3. Optionally, provide an output path for the generated package:

   ```sh
   ./create-nested-pkg.sh --scripts /path/to/source-directory /path/to/output.pkg
   ```

   The same optional output path works in default package mode. If omitted, the
   wrapper is created next to the source directory and named after it. For
   example, a source directory named `Software` produces `Software.pkg`.
4. Install the generated wrapper using Installer or `installer`. In default
   mode, embedded `.pkg` files are installed serially in alphabetical
   source-path order and target the startup disk (`/`). In `--scripts` mode,
   `.sh` files run with `/bin/bash` and `.zsh` files with `/bin/zsh`, also in
   alphabetical source-path order. In either mode, each item runs from its
   containing folder in the staged source tree, and processing continues if an
   item fails.

Scripts in `--scripts` mode run as root during package installation. Review
them and their companion files before building or installing the wrapper.

The builder refuses to proceed if no matching items are found or the output
already exists. If an embedded item fails, the remaining items are still
attempted, and the wrapper reports failure.

Before the embedded packages run, the source tree is staged at
`/Library/Application Support/PKGPrepTool/<package-id>/source/`. It is removed
after the installation attempts; the original source directory is not changed.

## Logs

When the generated package runs, it writes a log containing the installation
output to:

```text
/Library/Application Support/PKGPrepTool/<package-id>-<timestamp>-<pid>.log
```

The staged source tree is removed after the installation attempts; the log
remains.

## Changelog

- **2026-11-18** — Added the package-building script, recursive package
  discovery, deterministic installation order, and timestamped installation
  logs.
- **2026-11-18** — Updated the wrapper to include and stage the full source
  directory tree for companion files required by embedded packages.
- **2026-11-23** — Added optional `--scripts` mode to run `.sh` and `.zsh`
  scripts from the staged source tree.
