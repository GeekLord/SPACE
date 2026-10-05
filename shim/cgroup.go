package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var cgroupRoot = "/sys/fs/cgroup"

type joinedPodCgroup struct {
	scopePath         string
	childPath         string
	previousCgroupDir string
}

// joinPodCgroup creates a child cgroup "space-runtime" under the pod cgroup
// and moves the current process into it. This prevents systemd from GC'ing
// the pod cgroup (which would cause kubelet to kill the pod).
//
// This reuses the exact pattern from the POC shim (Bug 1 fix).
func joinPodCgroup(bundlePath string) (*joinedPodCgroup, error) {
	spec, err := readSpecFrom(bundlePath)
	if err != nil {
		return nil, fmt.Errorf("read OCI spec: %w", err)
	}
	if spec.Linux == nil || spec.Linux.CgroupsPath == "" {
		return nil, fmt.Errorf("no cgroups path in OCI spec")
	}

	previousCgroupDir := currentCgroupDir()
	cgroupPath := spec.Linux.CgroupsPath

	// Resolve the full cgroup path. systemd-style slice paths look like:
	//   kubepods-burstable-pod<uid>.slice:cri-containerd:<container-id>
	// or a simple relative path.
	var fullPath string
	if strings.HasPrefix(cgroupPath, "/") {
		fullPath = filepath.Join(cgroupRoot, cgroupPath)
	} else {
		fullPath = filepath.Join(cgroupRoot, expandSlice(cgroupPath))
	}

	// Create space-runtime child cgroup.
	childPath := filepath.Join(fullPath, "space-runtime")
	if err := os.MkdirAll(childPath, 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", childPath, err)
	}

	// Enable controllers on every ancestor between cgroupRoot and childPath.
	if err := enableControllersForPath(fullPath); err != nil {
		logShim("enableControllers (non-fatal): %v", err)
	}

	// Move the current process into the child cgroup.
	pid := os.Getpid()
	procsPath := filepath.Join(childPath, "cgroup.procs")
	if err := os.WriteFile(procsPath, []byte(fmt.Sprintf("%d", pid)), 0644); err != nil {
		return nil, fmt.Errorf("write %s: %w", procsPath, err)
	}

	logShim("joinPodCgroup: pid %d → %s", pid, childPath)
	return &joinedPodCgroup{
		scopePath:         fullPath,
		childPath:         childPath,
		previousCgroupDir: previousCgroupDir,
	}, nil
}

func (c *joinedPodCgroup) cleanupAfterFailedCreate() {
	if c == nil {
		return
	}
	if c.previousCgroupDir != "" {
		if err := moveSelfToCgroup(c.previousCgroupDir); err != nil {
			logShim("cleanupPodCgroup: move self back to %s failed: %v", c.previousCgroupDir, err)
		}
	}
	if err := os.Remove(c.childPath); err != nil && !os.IsNotExist(err) {
		logShim("cleanupPodCgroup: remove %s failed: %v", c.childPath, err)
	}
	if err := os.Remove(c.scopePath); err != nil && !os.IsNotExist(err) {
		logShim("cleanupPodCgroup: remove %s failed: %v", c.scopePath, err)
	}
}

func currentCgroupDir() string {
	data, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "0::") {
			return filepath.Join(cgroupRoot, strings.TrimPrefix(line, "0::"))
		}
	}
	return ""
}

func moveSelfToCgroup(cgroupDir string) error {
	if cgroupDir == "" {
		return nil
	}
	pid := os.Getpid()
	return os.WriteFile(filepath.Join(cgroupDir, "cgroup.procs"), []byte(fmt.Sprintf("%d", pid)), 0644)
}

// expandSlice converts a systemd cgroup path like
//
//	kubepods-burstable-pod<uid>.slice:cri-containerd:<id>
//
// into a filesystem path like
//
//	kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/cri-containerd-<id>.scope
func expandSlice(cgroupPath string) string {
	parts := strings.SplitN(cgroupPath, ":", 3)
	if len(parts) != 3 {
		return cgroupPath
	}

	slicePath := parts[0]
	scope := parts[1] + "-" + parts[2] + ".scope"

	// Expand the slice: "kubepods-burstable-podXYZ.slice" becomes
	// "kubepods.slice/kubepods-burstable.slice/kubepods-burstable-podXYZ.slice"
	expanded := expandSliceName(slicePath)
	return filepath.Join(expanded, scope)
}

func expandSliceName(slice string) string {
	// Remove .slice suffix to get the base name.
	base := strings.TrimSuffix(slice, ".slice")
	parts := strings.Split(base, "-")

	var result []string
	for i := range parts {
		prefix := strings.Join(parts[:i+1], "-")
		result = append(result, prefix+".slice")
	}
	return filepath.Join(result...)
}

// enableControllersForPath writes +cpu +cpuset +memory +pids to subtree_control
// at each ancestor cgroup, walking from the root down to the target.
func enableControllersForPath(targetPath string) error {
	controllers := "+cpu +cpuset +memory +pids"

	rel, err := filepath.Rel(cgroupRoot, targetPath)
	if err != nil {
		return err
	}

	parts := strings.Split(rel, string(filepath.Separator))
	current := cgroupRoot
	for _, part := range parts {
		subtreeControl := filepath.Join(current, "cgroup.subtree_control")
		// Best-effort: some ancestors may not allow writing.
		os.WriteFile(subtreeControl, []byte(controllers), 0644)
		current = filepath.Join(current, part)
	}

	return nil
}
