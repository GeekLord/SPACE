import type { NetworkPolicyDestinationV1, NetworkPolicyV1 } from './types';

export type CredentialHostDecisionReason =
  | 'explicit_deny'
  | 'explicit_allow'
  | 'default_deny'
  | 'default_allow';

export interface CredentialHostDecision {
  action: 'allow' | 'deny';
  reason: CredentialHostDecisionReason;
  matched_destination: NetworkPolicyDestinationV1 | null;
}

function normalizeDomain(value: string): string {
  return value.toLowerCase().replace(/\.$/, '');
}

function destinationMatchesHost(
  destination: NetworkPolicyDestinationV1,
  exactHost: string,
): boolean {
  const host = normalizeDomain(exactHost);
  if ('domain' in destination) {
    return normalizeDomain(destination.domain) === host;
  }
  if ('wildcard_domain' in destination) {
    const suffix = normalizeDomain(destination.wildcard_domain).replace(/^\*\./, '');
    return host !== suffix && host.endsWith(`.${suffix}`);
  }
  return false;
}

/**
 * Explain the domain-rule portion of egress authorization for an exact credential host.
 * Address rules and platform guardrails are evaluated separately once DNS resolves the host.
 */
export function credentialHostDecision(
  policy: NetworkPolicyV1,
  exactHost: string,
): CredentialHostDecision {
  const deniedBy = policy.egress.deny?.find((rule) => destinationMatchesHost(rule, exactHost));
  if (deniedBy) {
    return { action: 'deny', reason: 'explicit_deny', matched_destination: deniedBy };
  }

  const allowedBy = policy.egress.allow?.find((rule) => destinationMatchesHost(rule, exactHost));
  if (allowedBy) {
    return { action: 'allow', reason: 'explicit_allow', matched_destination: allowedBy };
  }

  return policy.egress.default_action === 'allow'
    ? { action: 'allow', reason: 'default_allow', matched_destination: null }
    : { action: 'deny', reason: 'default_deny', matched_destination: null };
}

export function formatPolicyDestination(destination: NetworkPolicyDestinationV1): string {
  if ('domain' in destination) return destination.domain;
  if ('wildcard_domain' in destination) return destination.wildcard_domain;
  if ('ip' in destination) return destination.ip;
  return destination.cidr;
}
