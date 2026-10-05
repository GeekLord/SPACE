package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCleanupAfterFailedCreateRemovesJoinedCgroup(t *testing.T) {
	root := t.TempDir()

	// Arrange.
	podPath := filepath.Join(root, "kubepods.slice", "kubepods-besteffort.slice", "kubepods-besteffort-podabc.slice")
	scopePath := filepath.Join(podPath, "cri-containerd-deadbeef.scope")
	childPath := filepath.Join(scopePath, "space-runtime")
	if err := os.MkdirAll(childPath, 0755); err != nil {
		t.Fatal(err)
	}
	joined := &joinedPodCgroup{
		scopePath: scopePath,
		childPath: childPath,
	}

	// Act.
	joined.cleanupAfterFailedCreate()

	// Assert.
	if _, err := os.Stat(childPath); !os.IsNotExist(err) {
		t.Fatalf("space-runtime cgroup still exists: %v", err)
	}
	if _, err := os.Stat(scopePath); !os.IsNotExist(err) {
		t.Fatalf("container scope cgroup still exists: %v", err)
	}
	if _, err := os.Stat(podPath); err != nil {
		t.Fatalf("pod cgroup should remain for kubelet cleanup: %v", err)
	}
}

func TestCleanupAfterFailedCreateKeepsNonEmptyScope(t *testing.T) {
	root := t.TempDir()

	// Arrange.
	scopePath := filepath.Join(root, "kubepods.slice", "kubepods-besteffort.slice", "kubepods-besteffort-podabc.slice", "cri-containerd-deadbeef.scope")
	childPath := filepath.Join(scopePath, "space-runtime")
	otherChildPath := filepath.Join(scopePath, "other-child")
	if err := os.MkdirAll(childPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(otherChildPath, 0755); err != nil {
		t.Fatal(err)
	}
	joined := &joinedPodCgroup{
		scopePath: scopePath,
		childPath: childPath,
	}

	// Act.
	joined.cleanupAfterFailedCreate()

	// Assert.
	if _, err := os.Stat(childPath); !os.IsNotExist(err) {
		t.Fatalf("space-runtime cgroup still exists: %v", err)
	}
	if _, err := os.Stat(scopePath); err != nil {
		t.Fatalf("container scope cgroup should remain while non-empty: %v", err)
	}
}
