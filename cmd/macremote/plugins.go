package main

import (
	"macremote/internal/plugin"
	"macremote/internal/plugins/git"
)

// corePlugins are the plugins this core serves: RPC methods beyond the
// built-in switch in session.go, listed by `plugins.list`.
func corePlugins() *plugin.Registry {
	return plugin.New(git.Plugin())
}
