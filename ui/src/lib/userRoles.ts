import { Cluster, User, UserRole } from './types';

export const roleLabels: Record<UserRole, string> = {
  organization_admin: 'Organization Admin',
  member: 'Member',
};

export const roleColors: Record<UserRole, string> = {
  organization_admin: 'blue',
  member: 'default',
};

const roleOptions: Array<{ value: UserRole; label: string }> = [
  { value: 'member', label: roleLabels.member },
  { value: 'organization_admin', label: roleLabels.organization_admin },
];

export function isManagingOrgAdmin(actor: User | null, cluster: Cluster | null): boolean {
  return actor?.role === 'organization_admin' && actor.org_id === cluster?.managing_org_id;
}

export function assignableRoleOptions(
  actor: User | null,
  cluster: Cluster | null,
): Array<{ value: UserRole; label: string }> {
  if (isManagingOrgAdmin(actor, cluster)) return roleOptions;
  if (actor?.role === 'organization_admin') return roleOptions;
  return [];
}

export function canManageUserRole(
  actor: User | null,
  target: User,
  cluster: Cluster | null,
  visibleOrgIds: string[] = [],
): boolean {
  if (!actor || actor.role === 'member') return false;
  if (actor.id === target.id) return false;
  if (isManagingOrgAdmin(actor, cluster)) return true;
  return actor.role === 'organization_admin' && visibleOrgIds.includes(target.org_id);
}

export function canDeleteUser(
  actor: User | null,
  target: User,
  cluster: Cluster | null,
  visibleOrgIds: string[] = [],
): boolean {
  return canManageUserRole(actor, target, cluster, visibleOrgIds);
}
