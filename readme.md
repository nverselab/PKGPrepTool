# PKG Prep Tool

PKG Prep Tool builds one macOS installer package from a source directory. The
wrapper includes the entire source tree—not just `.pkg` files—so packages can
use companion files and folders while they install.

## Requirements

- macOS
- The `pkgbuild` command-line tool
- Administrator privileges when installing the generated package

## Directions

1. Put the `.pkg` files and any companion files or folders they need in a
   source directory. The directory's full contents, including hidden files and
   nested folders, are included with their relative structure preserved.
2. From Terminal, run the script with the source directory:

   ```sh
   ./create-nested-pkg.sh /path/to/source-directory
   ```

3. Optionally, provide an output path for the generated package:

   ```sh
   ./create-nested-pkg.sh /path/to/source-directory /path/to/output.pkg
   ```

   If no output path is supplied, the package is created next to the source
   directory and named after it. For example, a source directory named
   `Software` produces `Software.pkg`.
4. Install the generated package using Installer or `installer`. Its embedded
   packages are installed serially in alphabetical source-path order, targeting
   the startup disk (`/`). Each package is run from its containing folder in the
   staged source tree and installs its payload according to its own package
   configuration.

The script refuses to build if no `.pkg` files are found or the output already
exists. If an embedded package fails, the remaining packages are still
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
