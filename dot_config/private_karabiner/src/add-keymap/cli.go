package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// cliOpts holds the non-interactive flag inputs.
type cliOpts struct {
	layer, key, label, action, mod string
	shift, overwrite, deploy       bool
}

const cliUsage = `add-keymap — add a Karabiner/goku keymap to a layer.

Interactive:   add-keymap            (no flags → guided wizard)
One-liner:     add-keymap -layer <L> -key <K> -label <T> [-action <A>] [...]

Flags:
  -layer    app | workspace | l1 | l2 | l3 | hyper   (required for one-liner mode)
  -key      key to map: a letter/digit, or - = [ ] ; ' , . / \ ` + "`" + ` space
            (app/workspace: an UPPER-case letter = the shift variant)
  -label    short label shown in the help overlay (required)
  -action   target, by layer:
              app        app name (open -a), or a !gokuCombo
              workspace  aerospace command (e.g. "workspace 1")
              l1/l2/l3   omit → auto-assign an F-key combo; or open:App;
                         or open-id:bundle.id; or !gokuCombo
              hyper      goku key code, or comma-separated sequence (required)
  -mod      hyper only: - shift cmd opt ctrl opt+cmd ctrl+shift   (default "-")
  -shift    workspace only: write the opt+shift variant
  -overwrite  replace an existing mapping instead of erroring
  -deploy   run "chezmoi apply && goku" after building (default: build only)

Examples:
  add-keymap -layer l2 -key g -label gemini                 # F-key pool slot
  add-keymap -layer l1 -key d -label dots -action open:Finder
  add-keymap -layer app -key V -label arc -action Arc       # shift+V
  add-keymap -layer hyper -key m -mod cmd -label spot -action "!Cspace"
`

// parseCLI parses argv. Returns (opts, isCLI). isCLI is true when -layer was
// supplied (non-interactive mode); otherwise the interactive wizard runs.
// On a flag error or -h it prints usage and exits.
func parseCLI(args []string) (cliOpts, bool) {
	fs := flag.NewFlagSet("add-keymap", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, cliUsage) }
	var o cliOpts
	fs.StringVar(&o.layer, "layer", "", "layer to add to")
	fs.StringVar(&o.key, "key", "", "key to map")
	fs.StringVar(&o.label, "label", "", "help-overlay label")
	fs.StringVar(&o.action, "action", "", "target/action (see -h)")
	fs.StringVar(&o.mod, "mod", "-", "hyper modifier slot")
	fs.BoolVar(&o.shift, "shift", false, "workspace opt+shift variant")
	fs.BoolVar(&o.overwrite, "overwrite", false, "overwrite an existing mapping")
	fs.BoolVar(&o.deploy, "deploy", false, "deploy after building")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		os.Exit(2)
	}
	return o, o.layer != ""
}

// validateCLI performs all non-IO validation and resolves the target section
// (flat layers) and the effective extra/action string. It is the testable core
// of one-liner mode.
func validateCLI(o cliOpts) (layer Layer, section, extra string, err error) {
	var ok bool
	layer, ok = layerByID[o.layer]
	if !ok {
		err = fmt.Errorf("unknown layer %q (want app|workspace|l1|l2|l3|hyper)", o.layer)
		return
	}
	if o.key == "" {
		err = fmt.Errorf("-key is required")
		return
	}
	if o.label == "" {
		err = fmt.Errorf("-label is required")
		return
	}
	if strings.Contains(o.label, "|") {
		err = fmt.Errorf("-label cannot contain '|'")
		return
	}

	if layer.ID == "hyper" {
		if err = validateKey(o.key, false); err != nil {
			return
		}
		if o.action == "" {
			err = fmt.Errorf("hyper layer needs -action (a goku key code or comma-separated sequence)")
			return
		}
		valid := false
		for _, m := range hyperModSlots {
			if m == o.mod {
				valid = true
				break
			}
		}
		if !valid {
			err = fmt.Errorf("invalid -mod %q (want one of: %s)", o.mod, strings.Join(hyperModSlots, " "))
			return
		}
		if strings.HasPrefix(o.action, "!") || strings.HasPrefix(o.action, "#") {
			if err = validateGokuCombo(o.action); err != nil {
				return
			}
		}
		if strings.Contains(o.label, "#") {
			err = fmt.Errorf("-label cannot contain '#' (it delimits the hyper help comment)")
			return
		}
		extra = o.action
		return
	}

	// Flat layers: app / workspace / l1 / l2 / l3.
	if err = validateKey(o.key, layer.AllowUpper); err != nil {
		return
	}
	section = layer.Section
	if o.shift {
		if layer.ID != "workspace" {
			err = fmt.Errorf("-shift only applies to the workspace layer")
			return
		}
		section = "workspace-shift"
	}
	extra = o.action
	if strings.Contains(extra, "|") {
		err = fmt.Errorf("-action cannot contain '|'")
		return
	}
	switch layer.ID {
	case "app":
		if extra == "" {
			err = fmt.Errorf("app layer needs -action (an app name or a !gokuCombo)")
			return
		}
	case "workspace":
		if extra == "" {
			err = fmt.Errorf("workspace layer needs -action (an aerospace command)")
			return
		}
	}
	if strings.HasPrefix(extra, "!") || strings.HasPrefix(extra, "#") {
		if err = validateGokuCombo(extra); err != nil {
			return
		}
	}
	for _, prefix := range []string{"open:", "open-id:"} {
		if strings.HasPrefix(extra, prefix) && strings.TrimSpace(extra[len(prefix):]) == "" {
			err = fmt.Errorf("%s target is empty", prefix)
			return
		}
	}
	return
}

// runCLI executes one-liner mode: validate, edit YAML, build, report, deploy.
func runCLI(o cliOpts) error {
	// Resolve the source dir and load the shared lookup tables first: validateCLI
	// calls validateKey, which needs the tables (longNames) populated.
	srcDir, err := resolveSourceDir()
	if err != nil {
		return err
	}
	if err := loadTables(srcDir); err != nil {
		return err
	}
	layer, section, extra, err := validateCLI(o)
	if err != nil {
		return err
	}
	path := filepath.Join(srcDir, layer.File)
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	text := string(b)

	if layer.ID == "hyper" {
		if hyperModsForKey(text, o.key)[o.mod] && !o.overwrite {
			return fmt.Errorf("hyper %s already maps mod %q; pass -overwrite to replace", o.key, o.mod)
		}
		action := hyperAction(extra)
		updated, err := upsertHyperEntry(text, o.key, o.mod, action, o.label)
		if err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
			return err
		}
		if err := build(srcDir); err != nil {
			return err
		}
		fmt.Printf("\n✓ Mapped: CapsLock + %s + %s → %s (%s)\n", o.mod, o.key, action, o.label)
		return finishCLI(srcDir, o.deploy)
	}

	if sectionKeys(text, section)[o.key] && !o.overwrite {
		return fmt.Errorf("%q already mapped in %s [%s]; pass -overwrite to replace", o.key, layer.File, section)
	}
	line := buildFlatLine(o.key, o.label, extra)
	updated, err := upsertFlatEntry(text, section, o.key, line)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return err
	}
	if err := build(srcDir); err != nil {
		return err
	}
	reportFlat(srcDir, layer, section, o.key, extra)
	return finishCLI(srcDir, o.deploy)
}

// finishCLI deploys if requested, else prints the manual deploy hint.
func finishCLI(srcDir string, deployFlag bool) error {
	if deployFlag {
		return deploy(srcDir)
	}
	fmt.Println("\n(not deployed; pass -deploy, or run: chezmoi apply && goku)")
	return nil
}
