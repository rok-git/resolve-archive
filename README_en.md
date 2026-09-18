# resolve-archive

A macOS CLI that archives folders as ZIP files, resolving symbolic links and Finder aliases to their actual contents. Original files are left unchanged.

Filenames are stored as UTF-8, with the UTF-8 flag explicitly set in both local headers and the central directory. This prevents extraction tools from interpreting Japanese filenames using a different encoding. No additional option is needed. ZIP files created by earlier versions are not updated automatically; recreate them as needed.

## Build and run

Requires macOS and Xcode Command Line Tools (`xcrun swiftc`).

```sh
make
./build/resolve-archive -- '/path/to/source-folder'
./build/resolve-archive --output '/path/to/archive.zip' -- '/path/to/source-folder'
```

By default, the archive is created next to the input as `source-folder.zip`. The ZIP contains a top-level folder with the input folder's name. On success, the destination path is printed to standard output. On failure, the reason is printed to standard error and the command exits with status 1. Existing output paths, including broken symbolic links, are never overwritten. The destination's parent folder must already exist. The output cannot be placed inside the input folder.

## Links to folders

When a link points to a folder, **its contents are archived recursively as a regular folder retaining the link's name**. For example, `source/documents-link → /external/documents` becomes `source/documents-link/(contents of documents)` in the ZIP. Links and aliases inside the target folder are also resolved.

- Targets outside the source folder are included. Before sharing or sending an archive, check which external data it includes.
- If multiple links point to the same target, a separate copy is included at each location. Contents are not deduplicated.
- Cycles, broken links, unresolvable aliases, read failures, and special files such as FIFOs, sockets, and devices cause the entire operation to fail. They are not silently skipped.
- Alias resolution does not display UI or automatically mount volumes. Connect any required disks or network shares beforehand.
- Hidden files, empty folders, and package contents are included. Because links inside packages are also expanded, this tool is not suitable for backups that must preserve application signatures or behavior.
- Regular files are copied using Foundation, and `ditto` includes macOS resource forks and related metadata in the ZIP. Directories are created anew, preserving ordinary permission bits and modification times. Full preservation of directory extended attributes, ACLs, and hard-link identity is outside the scope of this tool.
- The ZIP may contain a `__MACOSX` folder for macOS-specific metadata, as well as `.DS_Store` files containing Finder display settings if they were present in the source folders. On Windows or other non-macOS systems, you can safely ignore these items.
- Temporary storage must have enough space for all resolved contents. The destination volume must have space for the ZIP, or up to two copies of it when using the copy method: the temporary ZIP and the output ZIP. Temporary data is removed on normal completion or handled errors. Forced termination or power loss may leave temporary folders behind.
- Do not modify source data while the command is running. The tool does not create a filesystem snapshot.
- To finalize the ZIP, the tool first attempts to create a hard link on the destination volume. If this fails with an unsupported-operation error (`ENOTSUP`, `EOPNOTSUPP`, or `ENOSYS`) or `EXDEV`, it automatically falls back to copying into a file created exclusively at the destination. This allows direct output to NAS/SMB shares, exFAT volumes, and other destinations without hard-link support. Existing files and symbolic links are never overwritten, including those created by another process during the operation. Permission errors, connection errors, and other failures are reported without this fallback.

## Saving to a NAS or similar destination

Normally, automatic fallback works without additional options.

```sh
./build/resolve-archive --output '/Volumes/NAS/archive.zip' -- '/path/to/source-folder'
```

Use `--copy-output` to select the copy method from the start. This can also help when a destination reports lack of hard-link support using an error other than those listed above. It does not bypass write permissions or connection problems.

```sh
./build/resolve-archive --copy-output --output '/Volumes/NAS/archive.zip' -- '/path/to/source-folder'
```

The copy method creates the ZIP under its final name before writing its contents, so **other applications can see the ZIP while it is still being written**. Wait for the CLI to finish successfully before using it. Incomplete output is removed after a handled copy failure, but it may remain if cleanup is prevented by forced termination, power loss, a disconnected share, or similar conditions. If a file remains, inspect and remove it, or retry with a different output name.

## Finder Quick Action

1. Run `make install` to install the CLI at `~/.local/bin/resolve-archive`. To use a different location, run `make install PREFIX=/your/preferred/location`.
2. Create a **Quick Action** in Automator.
3. Set the workflow to receive **folders** in **Finder**.
4. Add **Run Shell Script**, select `/bin/zsh` as the shell, and set **Pass input** to **as arguments**.
5. Paste the contents of `scripts/finder-quick-action.zsh` and save the workflow. If you changed the installation location, update the `archiver` variable accordingly.

A ZIP is created next to each folder selected in Finder. Multiple selections are processed in order, stopping at the first failure. ZIP files completed before that failure are kept. Quick Action registration and CLI installation are not performed automatically.

## Testing

```sh
make test
```

Requires Python 3.11 or later. The tests create actual macOS aliases and cover external files and folders, mixed symbolic links and aliases, cycles, broken links, overwrite prevention, Japanese filenames, hidden files, empty folders, and executable permissions.

Publication tests simulate unavailable hard-link support and check automatic fallback, forced copying, competing creation of the same output filename, and cleanup after a failure during writing. They do not include connection tests against an actual NAS or SMB server.

Encoding tests extract filenames containing Japanese, Korean, emoji, and combining characters using Python's `zipfile` without an encoding override and macOS `ditto`. They also verify UTF-8 flags in both headers, ZIP64 support, preservation of all data other than the flags, and rejection of invalid input. They do not include extraction tests on an actual Windows machine.
