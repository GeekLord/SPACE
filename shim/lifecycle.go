package main

import (
	pb "github.com/perplexityai/SPACE/shim/proto/sandbox/manager/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Missing or unknown observations cannot authorize destructive teardown.
func observedSandboxLifecycle(sandbox *pb.SandboxInfo) (pb.SandboxLifecycleState, error) {
	if sandbox == nil {
		return 0, status.Error(codes.FailedPrecondition, "sandbox lifecycle observation missing")
	}
	if sandbox.Lifecycle != nil {
		value := sandbox.GetLifecycle()
		if _, known := pb.SandboxLifecycleState_name[int32(value)]; known && value != pb.SandboxLifecycleState_SANDBOX_LIFECYCLE_STATE_UNSPECIFIED {
			return value, nil
		}
		return 0, status.Errorf(codes.FailedPrecondition, "unknown sandbox lifecycle value %d", value)
	}
	return 0, status.Error(codes.FailedPrecondition, "sandbox lifecycle observation missing")
}
