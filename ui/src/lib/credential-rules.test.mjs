import assert from 'node:assert/strict';
import test from 'node:test';

import { credentialHostDecision } from './credential-rules.ts';

const OVERLAPPING_HOST = 'api.internal.example.com';
const WILDCARD_APEX = 'example.com';
const UNMATCHED_HOST = 'unmatched.test';

function policy({ defaultAction = 'deny', allow = [], deny = [] } = {}) {
  return {
    version: 'v1',
    egress: {
      default_action: defaultAction,
      allow,
      deny,
    },
    tls_interception: 'on',
  };
}

test('explicit deny wins when allow and deny both match a credential host', () => {
  const decision = credentialHostDecision(
    policy({
      defaultAction: 'allow',
      allow: [{ wildcard_domain: '*.example.com' }],
      deny: [{ domain: OVERLAPPING_HOST }],
    }),
    OVERLAPPING_HOST,
  );

  assert.deepEqual(decision, {
    action: 'deny',
    reason: 'explicit_deny',
    matched_destination: { domain: OVERLAPPING_HOST },
  });
});

test('wildcards match normalized subdomains but not the apex', () => {
  const wildcardPolicy = policy({ allow: [{ wildcard_domain: '*.example.com' }] });

  assert.equal(credentialHostDecision(wildcardPolicy, 'API.EXAMPLE.COM.').reason, 'explicit_allow');
  assert.equal(credentialHostDecision(wildcardPolicy, WILDCARD_APEX).reason, 'default_deny');
});

test('unmatched hosts follow the configured default action', () => {
  assert.equal(
    credentialHostDecision(policy({ defaultAction: 'allow' }), UNMATCHED_HOST).reason,
    'default_allow',
  );
  assert.equal(
    credentialHostDecision(policy({ defaultAction: 'deny' }), UNMATCHED_HOST).reason,
    'default_deny',
  );
});
