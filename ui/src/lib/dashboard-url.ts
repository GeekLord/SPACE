export function parseDashboardUrl(value: string | undefined): string | null {
  const configuredUrl = value?.trim();
  if (!configuredUrl || !URL.canParse(configuredUrl)) return null;

  const url = new URL(configuredUrl);
  if (url.protocol !== 'https:' || url.username || url.password) return null;
  return url.href;
}
