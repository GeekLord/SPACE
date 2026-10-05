# Introduction

[Documentation](../README.md)

SPACE runs code in isolated Firecracker microVMs. Use its HTTP API to create Linux environments, run commands, collect output, and manage sandbox lifecycles.

A **template** supplies the starting environment. A **sandbox** is an instance with its own VM and writable filesystem. Multiple commands can run in the same sandbox.

## Use the API

Follow [Your first sandbox](first-sandbox.md) to create a sandbox, run a command, read its output, and delete it. The [API reference](api/index.md) describes endpoints, fields, and examples.

## Run SPACE locally

[Install and configure locally](installation.md) covers host prerequisites, Kind deployment, and authentication. See [Troubleshooting](troubleshooting.md) for setup and runtime problems.

## Work on SPACE

Read [Architecture](architecture.md) to understand the components and execution flow. The repository documents the [development workflow](../README.md#development) and [contribution process](../CONTRIBUTING.md).
