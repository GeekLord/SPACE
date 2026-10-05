export const RESTORE_SANDBOX_REQUEST = {
  blocking: true,
  ready_timeout_secs: 60,
} as const;

export function sandboxLifecycleActionBody(action: string): unknown | undefined {
  if (action !== 'restore') {
    return undefined;
  }
  return RESTORE_SANDBOX_REQUEST;
}
