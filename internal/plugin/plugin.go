// Package plugin is the core's plugin registry. A plugin registers methods in
// its own namespace ("git.status"). Each method describes itself (a line of
// text, a JSON schema for its parameters, whether it changes anything), so the
// same registry serves the apps over RPC (`plugins.list` says what this core
// offers) and, later, the AI sessions as MCP tools. Plan: docs/native-app.md.
package plugin

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"uniai/internal/rpc"
)

// Error carries a machine-readable code to the app ("denied", "notfound", …).
// It is rpc.Error: one type for the core and its plugins.
type Error = rpc.Error

// Ctx is what a method gets from the core besides its parameters.
type Ctx struct {
	Device string // who called: a paired device's name
	// Resolve makes a caller-supplied path absolute and real (symlinks
	// followed), and refuses one outside the folders this core shares.
	Resolve func(path string) (string, error)
	Log     func(format string, a ...any)
}

// Method is one call a plugin offers.
type Method struct {
	Name   string          // "git.status": the plugin's name, a dot, the call
	Desc   string          // one line, for app UIs and AI tool lists
	Params json.RawMessage // JSON schema of the params object
	Write  bool            // changes something: an AI must ask before calling it
	Call   func(c *Ctx, p json.RawMessage) (any, error)
}

// Plugin is a named set of methods.
type Plugin struct {
	Name    string
	Desc    string
	Version int // bumped when methods are added, so an app can tell what a core has
	Methods []Method
}

// Registry holds the plugins one core serves.
type Registry struct {
	plugins []Plugin
	methods map[string]*Method
}

// New builds a registry. It panics on a duplicate method or a method outside
// its plugin's namespace: both are programming errors.
func New(ps ...Plugin) *Registry {
	r := &Registry{methods: map[string]*Method{}}
	for _, p := range ps {
		for i := range p.Methods {
			m := &p.Methods[i]
			if !strings.HasPrefix(m.Name, p.Name+".") {
				panic(fmt.Sprintf("plugin %s: method %s outside its namespace", p.Name, m.Name))
			}
			if r.methods[m.Name] != nil {
				panic("plugin: duplicate method " + m.Name)
			}
			r.methods[m.Name] = m
		}
		r.plugins = append(r.plugins, p)
	}
	sort.Slice(r.plugins, func(i, j int) bool { return r.plugins[i].Name < r.plugins[j].Name })
	return r
}

// Lookup returns the method by name, or nil.
func (r *Registry) Lookup(name string) *Method { return r.methods[name] }

// MethodInfo and Info are what `plugins.list` returns.
type MethodInfo struct {
	Name   string          `json:"name"`
	Desc   string          `json:"desc"`
	Params json.RawMessage `json:"params"`
	Write  bool            `json:"write,omitempty"`
}

type Info struct {
	Name    string       `json:"name"`
	Desc    string       `json:"desc"`
	Version int          `json:"version"`
	Methods []MethodInfo `json:"methods"`
}

func (r *Registry) List() []Info {
	out := make([]Info, 0, len(r.plugins))
	for _, p := range r.plugins {
		in := Info{Name: p.Name, Desc: p.Desc, Version: p.Version}
		for _, m := range p.Methods {
			in.Methods = append(in.Methods, MethodInfo{m.Name, m.Desc, m.Params, m.Write})
		}
		out = append(out, in)
	}
	return out
}

// Decode unmarshals params, treating none as an empty object.
func Decode(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return &Error{"bad", "bad parameters: " + err.Error()}
	}
	return nil
}
