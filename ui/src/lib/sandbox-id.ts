const SANDBOX_LABEL_LEN = 8;
const PUBLIC_SANDBOX_ID_PREFIX = 'sbx_';

export function sandboxUuidPart(sandboxId: string): string {
  return sandboxId.startsWith(PUBLIC_SANDBOX_ID_PREFIX)
    ? sandboxId.slice(PUBLIC_SANDBOX_ID_PREFIX.length)
    : sandboxId;
}

export function publicSandboxIdFromAny(sandboxId: string): string {
  return sandboxId.startsWith(PUBLIC_SANDBOX_ID_PREFIX)
    ? sandboxId
    : `${PUBLIC_SANDBOX_ID_PREFIX}${sandboxId}`;
}

export function sandboxLabelOrId(sandboxId: string): string {
  const compact = sandboxUuidPart(sandboxId).replaceAll('-', '').toLowerCase();
  if (!compact || !/^[0-9a-f]+$/.test(compact)) {
    return sandboxId;
  }
  if (compact.length <= SANDBOX_LABEL_LEN) {
    return compact;
  }
  return compact.slice(-SANDBOX_LABEL_LEN);
}
