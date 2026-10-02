# internal/fsops

The file browser's side of the core: list, read, write, create, rename and
delete, confined to the folders the user shares (`Config.Roots`).

Entry points: `Resolve(roots, path)` (absolute + symlinks followed, refuses
anything outside the roots), `List`, `Read`, `Write` (with an mtime check, so
a phone cannot overwrite a newer file), `Mkdir`, `Create`, `Rename`, `Delete`.
Errors are `*rpc.Error` with a code (`denied`, `isdir`, `conflict`, `exists`).

Called from: `cmd/uniai/rpc.go` (`fs.*`) and, as `plugin.Ctx.Resolve`, by
plugins.

Test: `./dev.sh go test ./internal/fsops`

Traps: every path from a phone goes through `Resolve` first. A root folder
itself cannot be deleted or renamed. Do not follow a symlink out of a root.
