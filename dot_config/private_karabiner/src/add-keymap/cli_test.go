package main

import "testing"

func TestValidateCLIErrors(t *testing.T) {
	cases := []struct {
		name string
		o    cliOpts
	}{
		{"unknown layer", cliOpts{layer: "l9", key: "g", label: "x"}},
		{"missing key", cliOpts{layer: "l1", label: "x"}},
		{"missing label", cliOpts{layer: "l1", key: "g"}},
		{"pipe in label", cliOpts{layer: "l1", key: "g", label: "a|b"}},
		{"app needs action", cliOpts{layer: "app", key: "g", label: "x"}},
		{"workspace needs action", cliOpts{layer: "workspace", key: "g", label: "x"}},
		{"shift on non-workspace", cliOpts{layer: "l1", key: "g", label: "x", shift: true}},
		{"uppercase key on l1", cliOpts{layer: "l1", key: "G", label: "x"}},
		{"bad combo action", cliOpts{layer: "l1", key: "g", label: "x", action: "!Zfoo"}},
		{"empty open target", cliOpts{layer: "l1", key: "g", label: "x", action: "open:"}},
		{"empty open-id target", cliOpts{layer: "l1", key: "g", label: "x", action: "open-id:"}},
		{"pipe in action", cliOpts{layer: "app", key: "g", label: "x", action: "a|b"}},
		{"hyper needs action", cliOpts{layer: "hyper", key: "m", label: "x", mod: "cmd"}},
		{"hyper bad mod", cliOpts{layer: "hyper", key: "m", label: "x", action: "left_arrow", mod: "hyper"}},
		{"hyper bad combo", cliOpts{layer: "hyper", key: "m", label: "x", action: "!Zx", mod: "-"}},
	}
	for _, c := range cases {
		if _, _, _, err := validateCLI(c.o); err == nil {
			t.Errorf("%s: expected error, got nil", c.name)
		}
	}
}

func TestValidateCLIOK(t *testing.T) {
	// l1 pool entry (blank action allowed)
	layer, section, extra, err := validateCLI(cliOpts{layer: "l1", key: "g", label: "gemini"})
	if err != nil || layer.ID != "l1" || section != "l1" || extra != "" {
		t.Errorf("l1 pool: layer=%v section=%q extra=%q err=%v", layer.ID, section, extra, err)
	}

	// app with raw combo
	_, _, extra, err = validateCLI(cliOpts{layer: "app", key: "c", label: "switch", action: "!Cgrave_accent_and_tilde"})
	if err != nil || extra != "!Cgrave_accent_and_tilde" {
		t.Errorf("app combo: extra=%q err=%v", extra, err)
	}

	// app shift variant via uppercase key
	layer, _, _, err = validateCLI(cliOpts{layer: "app", key: "V", label: "arc", action: "Arc"})
	if err != nil || !layer.AllowUpper {
		t.Errorf("app uppercase: err=%v", err)
	}

	// workspace shift section
	_, section, _, err = validateCLI(cliOpts{layer: "workspace", key: "h", label: "mv left", action: "move left", shift: true})
	if err != nil || section != "workspace-shift" {
		t.Errorf("workspace shift: section=%q err=%v", section, err)
	}

	// l1 direct open
	_, _, extra, err = validateCLI(cliOpts{layer: "l1", key: "d", label: "dots", action: "open:Finder"})
	if err != nil || extra != "open:Finder" {
		t.Errorf("l1 open: extra=%q err=%v", extra, err)
	}

	// hyper with default mod and combo action
	_, _, extra, err = validateCLI(cliOpts{layer: "hyper", key: "m", label: "spot", action: "!Cspacebar", mod: "cmd"})
	if err != nil || extra != "!Cspacebar" {
		t.Errorf("hyper combo: extra=%q err=%v", extra, err)
	}
}

func TestParseCLIInteractiveWhenNoLayer(t *testing.T) {
	if _, isCLI := parseCLI([]string{}); isCLI {
		t.Errorf("no args should be interactive (isCLI=false)")
	}
	if _, isCLI := parseCLI([]string{"-layer", "l1", "-key", "g", "-label", "x"}); !isCLI {
		t.Errorf("-layer should select CLI mode")
	}
}
