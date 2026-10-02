# files

Browsing a session's folder and editing files on the Mac.

Entry points: `FilesPanel`, `Breadcrumbs` (files_panel.dart), `Files`
(files.dart, the controller), `EditorView` (editor.dart), `EditorFindBar`,
`languageFor` (editor_languages.dart).

RPC: `fs.list`, `fs.read`, `fs.write`, `fs.create`, `fs.mkdir`, `fs.rename`,
`fs.delete`.

Tests: none of its own yet.

Traps:
- Paths are the Mac's: join with `joinPath`, never with the phone's separator.
- Hidden files are a view setting, not a server one.
