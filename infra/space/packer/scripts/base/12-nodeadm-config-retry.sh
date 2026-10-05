#!/usr/bin/env bash
# Drop-in to make nodeadm-config.service tolerate transient IMDS failures.
# Runs as root during Packer build of AL2023 EKS-based AMIs.
#
# nodeadm-config.service ships in Amazon's AL2023 EKS-optimized AMI and runs
# at ~9s after kernel start to fetch NodeConfig from imds://user-data. The
# upstream unit has no Restart=, so a single transient IMDS race on early
# boot leaves the unit failed permanently — kubelet never starts, the node
# never joins EKS, and the ASG keeps the instance Healthy forever.
#
# This drop-in retries on failure with a 5s delay (well above the IMDS
# settling window), capped at 5 attempts so a genuinely-malformed user-data
# still surfaces as a failed unit.
set -euxo pipefail

install -d -m 0755 /etc/systemd/system/nodeadm-config.service.d
tee /etc/systemd/system/nodeadm-config.service.d/retry.conf > /dev/null <<'UNIT'
[Unit]
StartLimitBurst=5
StartLimitIntervalSec=120

[Service]
Restart=on-failure
RestartSec=5s
UNIT
chmod 0644 /etc/systemd/system/nodeadm-config.service.d/retry.conf

systemctl daemon-reload
