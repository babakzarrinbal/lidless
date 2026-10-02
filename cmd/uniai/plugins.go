package main

import (
	"uniai/internal/plugin"
	"uniai/internal/plugins/git"
)

// corePlugins are the plugins this core serves: RPC methods beyond the
// built-in switch in rpc.go, listed by `plugins.list`.
func corePlugins() *plugin.Registry {
	return plugin.New(git.Plugin())
}
