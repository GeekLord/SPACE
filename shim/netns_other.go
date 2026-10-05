//go:build !linux

package main

func podIPFromNetns(netnsPath string) string {
	return ""
}
