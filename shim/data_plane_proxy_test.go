package main

import (
	"errors"
	"os/exec"
	"slices"
	"strings"
	"testing"

	"github.com/containerd/containerd/v2/pkg/sys/reaper"
	"github.com/containerd/go-runc"
)

type fakeShellCommand struct {
	name string
	args []string
	run  func(string, []string) ([]byte, error)
}

func (c fakeShellCommand) Run() error {
	_, err := c.CombinedOutput()
	return err
}

func (c fakeShellCommand) CombinedOutput() ([]byte, error) {
	return c.run(c.name, c.args)
}

func withFakeCommands(t *testing.T, run func(string, []string) ([]byte, error)) *[]string {
	t.Helper()

	var commands []string
	previous := execShellCommand
	execShellCommand = func(name string, args ...string) shellCommand {
		argsCopy := slices.Clone(args)
		commands = append(commands, strings.Join(append([]string{name}, argsCopy...), " "))
		return fakeShellCommand{name: name, args: argsCopy, run: run}
	}
	t.Cleanup(func() {
		execShellCommand = previous
	})

	return &commands
}

func TestNftCommandUsesNamedNetns(t *testing.T) {
	commands := withFakeCommands(t, func(string, []string) ([]byte, error) {
		return nil, nil
	})

	if err := nftCommand("/var/run/netns/cni-test", "list", "table", "ip", nftTable).Run(); err != nil {
		t.Fatalf("nft command failed: %v", err)
	}

	want := "ip netns exec cni-test nft list table ip space_dataplane"
	if got := (*commands)[0]; got != want {
		t.Fatalf("command mismatch\nwant: %s\n got: %s", want, got)
	}
}

func TestReaperShellCommandUsesContainerdReaper(t *testing.T) {
	exitCh := make(chan runc.Exit, 1)
	var startedCommand *exec.Cmd
	var waitedCommand *exec.Cmd
	startReaperCommand = func(cmd *exec.Cmd) (chan runc.Exit, error) {
		startedCommand = cmd
		return exitCh, nil
	}
	waitReaperCommand = func(cmd *exec.Cmd, gotExitCh chan runc.Exit) (int, error) {
		waitedCommand = cmd
		if gotExitCh != exitCh {
			t.Fatalf("wait got unexpected exit channel")
		}
		_, _ = cmd.Stdout.Write([]byte("stdout\n"))
		_, _ = cmd.Stderr.Write([]byte("stderr\n"))
		return 0, nil
	}
	t.Cleanup(func() {
		startReaperCommand = reaper.Default.Start
		waitReaperCommand = reaper.Default.Wait
	})

	cmd := reaperShellCommand{cmd: exec.Command("ip", "netns", "exec", "cni-test", "nft", "list", "table")}
	output, err := cmd.CombinedOutput()

	if err != nil {
		t.Fatalf("CombinedOutput returned error: %v", err)
	}
	if startedCommand != cmd.cmd {
		t.Fatalf("start got unexpected command")
	}
	if waitedCommand != cmd.cmd {
		t.Fatalf("wait got unexpected command")
	}
	if got, want := string(output), "stdout\nstderr\n"; got != want {
		t.Fatalf("output mismatch\nwant: %q\n got: %q", want, got)
	}
}

func TestReaperShellCommandReturnsNonzeroStatusErrorWithOutput(t *testing.T) {
	exitCh := make(chan runc.Exit, 1)
	startReaperCommand = func(*exec.Cmd) (chan runc.Exit, error) {
		return exitCh, nil
	}
	waitReaperCommand = func(cmd *exec.Cmd, gotExitCh chan runc.Exit) (int, error) {
		if gotExitCh != exitCh {
			t.Fatalf("wait got unexpected exit channel")
		}
		_, _ = cmd.Stderr.Write([]byte("nft: bad rule\n"))
		return 1, nil
	}
	t.Cleanup(func() {
		startReaperCommand = reaper.Default.Start
		waitReaperCommand = reaper.Default.Wait
	})

	cmd := reaperShellCommand{cmd: exec.Command("ip", "netns", "exec", "cni-test", "nft", "add", "rule")}
	output, err := cmd.CombinedOutput()

	if err == nil {
		t.Fatal("expected nonzero status error")
	}
	if !strings.Contains(err.Error(), "exited with status 1") {
		t.Fatalf("error should include exit status, got %v", err)
	}
	if got, want := string(output), "nft: bad rule\n"; got != want {
		t.Fatalf("output mismatch\nwant: %q\n got: %q", want, got)
	}
}

func TestAddDataPlaneRedirectInstallsDNATAndSNAT(t *testing.T) {
	commands := withFakeCommands(t, func(name string, args []string) ([]byte, error) {
		command := strings.Join(append([]string{name}, args...), " ")
		switch {
		case command == "ip route get 192.0.2.10":
			return []byte("192.0.2.10 dev eni0 src 192.0.2.20 uid 0\n"), nil
		case strings.Contains(command, " nft list table "):
			return nil, errors.New("missing table")
		case strings.Contains(command, " nft list chain ") && !strings.Contains(command, " -a "):
			return nil, errors.New("missing chain")
		default:
			return nil, nil
		}
	})

	if err := addDataPlaneRedirect(
		"/var/run/netns/cni-test",
		"00000000-0000-0000-0000-000000000001",
		"192.0.2.10",
	); err != nil {
		t.Fatalf("addDataPlaneRedirect failed: %v", err)
	}

	assertCommand(t, *commands, "ip netns exec cni-test nft add chain ip space_dataplane prerouting { type nat hook prerouting priority dstnat ; }")
	assertCommand(t, *commands, "ip netns exec cni-test nft add chain ip space_dataplane postrouting { type nat hook postrouting priority srcnat ; }")
	assertCommand(t, *commands, "ip netns exec cni-test nft add rule ip space_dataplane prerouting ip daddr 192.0.2.10 tcp dport 9800 dnat to 192.0.2.20:9800 comment space-sbx-00000000-0000-0000-0000-000000000001")
	assertCommand(t, *commands, "ip netns exec cni-test nft add rule ip space_dataplane postrouting ip daddr 192.0.2.20 tcp dport 9800 snat to 192.0.2.10 comment space-sbx-00000000-0000-0000-0000-000000000001")
}

func TestRemoveDataPlaneRedirectDeletesBothChains(t *testing.T) {
	commands := withFakeCommands(t, func(name string, args []string) ([]byte, error) {
		command := strings.Join(append([]string{name}, args...), " ")
		switch {
		case strings.Contains(command, " -a list chain ip space_dataplane prerouting"):
			return []byte("ip daddr 192.0.2.10 comment \"space-sbx-sbx-1\" # handle 7\n"), nil
		case strings.Contains(command, " -a list chain ip space_dataplane postrouting"):
			return []byte("ip daddr 192.0.2.20 comment \"space-sbx-sbx-1\" # handle 8\n"), nil
		default:
			return nil, nil
		}
	})

	removeDataPlaneRedirect("/var/run/netns/cni-test", "sbx-1")

	assertCommand(t, *commands, "ip netns exec cni-test nft delete rule ip space_dataplane prerouting handle 7")
	assertCommand(t, *commands, "ip netns exec cni-test nft delete rule ip space_dataplane postrouting handle 8")
}

func assertCommand(t *testing.T, commands []string, want string) {
	t.Helper()
	if slices.Contains(commands, want) {
		return
	}
	t.Fatalf("missing command:\n%s\n\ncommands:\n%s", want, strings.Join(commands, "\n"))
}
