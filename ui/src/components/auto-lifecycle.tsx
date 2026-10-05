'use client';

import type { AutoLifecycleActivitySource, AutoLifecycleConditionSet, AutoLifecycleConditionSetId, AutoLifecycleIdleAction, AutoLifecyclePolicy, AutoLifecycleStage, AutoLifecycleStatus, AutoLifecycleWakeSource } from '@/lib/types';
import { MinusCircleOutlined, PlusOutlined } from '@ant-design/icons';
import { Button, Card, Form, Input, Select, Space, Typography } from 'antd';
import type { NamePath } from 'antd/es/form/interface';

const { Text } = Typography;

type ConditionName = AutoLifecycleConditionSetId;

interface StageFormValue {
  at?: string;
  action?: AutoLifecycleIdleAction;
}

export interface AutoLifecycleFormValue {
  wake_on?: AutoLifecycleWakeSource[];
  access_idle?: StageFormValue[];
  command_idle?: StageFormValue[];
  guest_activity?: StageFormValue[];
}

const CONDITION_ORDER: ConditionName[] = ['access_idle', 'command_idle', 'guest_activity'];

const CONDITION_LABELS: Record<ConditionName, string> = {
  access_idle: 'Access idle',
  command_idle: 'Command idle',
  guest_activity: 'Guest activity idle',
};

const CONDITION_HELP: Record<ConditionName, string> = {
  access_idle: 'Reset on guest-facing access such as exec, file reads and file writes.',
  command_idle: 'Reset only when a new command or process is started.',
  guest_activity: 'Armed and delayed by guest-originated activity hints through HostControl.',
};

const DURATION_PATTERN = /^(\d+(?:\.\d+)?)([smhd])$/;

function withPrefix(prefix: NamePath | undefined, key: string): NamePath {
  const parts = Array.isArray(prefix) ? prefix : prefix ? [prefix] : [];
  return [...parts, key];
}

function normalizeWakeSources(values?: AutoLifecycleWakeSource[]): AutoLifecycleWakeSource[] {
  const unique = Array.from(new Set(values ?? []));
  return unique.sort((left, right) => {
    const rank = (value: AutoLifecycleWakeSource) => (value === 'access' ? 0 : 1);
    return rank(left) - rank(right);
  });
}

function stageCondition(conditionName: ConditionName): AutoLifecycleConditionSet {
  switch (conditionName) {
    case 'access_idle':
      return { kind: 'inactivity', activity_source: 'access' as AutoLifecycleActivitySource };
    case 'command_idle':
      return { kind: 'inactivity', activity_source: 'command' as AutoLifecycleActivitySource };
    case 'guest_activity':
      return { kind: 'guest_activity' };
  }
}

function stageActionRank(action: AutoLifecycleIdleAction): number {
  switch (action) {
    case 'none':
      return 0;
    case 'pause':
      return 1;
    case 'suspend':
      return 2;
    case 'stop':
      return 3;
    case 'delete':
      return 4;
  }
}

function parseDuration(value: string): number {
  const normalized = value.trim();
  const match = normalized.match(DURATION_PATTERN);
  if (!match) {
    return Number.NaN;
  }
  const amount = Number.parseFloat(match[1]);
  const unit = match[2];
  switch (unit) {
    case 's':
      return amount;
    case 'm':
      return amount * 60;
    case 'h':
      return amount * 60 * 60;
    case 'd':
      return amount * 60 * 60 * 24;
    default:
      return Number.NaN;
  }
}

function isValidStageDuration(value: string): boolean {
  const seconds = parseDuration(value);
  return Number.isFinite(seconds) && seconds > 0 && Number.isInteger(seconds);
}

function formatDuration(value: number): string {
  if (value > 0 && value % 86_400 === 0) return `${value / 86_400}d`;
  if (value > 0 && value % 3_600 === 0) return `${value / 3_600}h`;
  if (value > 0 && value % 60 === 0) return `${value / 60}m`;
  return `${value}s`;
}

export function disabledAutoLifecycle(): AutoLifecyclePolicy {
  return { wake: { on: [] }, condition_sets: {}, stages: [] };
}

export function policyToFormValue(policy?: AutoLifecyclePolicy | null): AutoLifecycleFormValue {
  const stages = policy?.stages ?? [];
  const forCondition = (conditionName: ConditionName): StageFormValue[] =>
    stages
      .filter((stage) => stage.condition_set === conditionName)
      .map((stage) => ({
        at: stage.at,
        action: stage.action,
      }));

  return {
    wake_on: normalizeWakeSources(policy?.wake?.on),
    access_idle: forCondition('access_idle'),
    command_idle: forCondition('command_idle'),
    guest_activity: forCondition('guest_activity'),
  };
}

export function formValueToPolicy(value?: AutoLifecycleFormValue | null): AutoLifecyclePolicy {
  const wakeOn = normalizeWakeSources(value?.wake_on);
  const conditionSets: Partial<Record<ConditionName, AutoLifecycleConditionSet>> = {};
  const stages: AutoLifecycleStage[] = [];

  for (const conditionName of CONDITION_ORDER) {
    const entries = (value?.[conditionName] ?? []).filter(
      (entry): entry is Required<StageFormValue> =>
        !!entry?.at && !!entry?.action && isValidStageDuration(entry.at),
    );
    if (entries.length === 0) {
      continue;
    }
    conditionSets[conditionName] = stageCondition(conditionName);
    for (const entry of entries) {
      stages.push({
        condition_set: conditionName,
        at: entry.at.trim(),
        action: entry.action,
      });
    }
  }

  stages.sort((left, right) => {
    const leftCondition = CONDITION_ORDER.indexOf(left.condition_set as ConditionName);
    const rightCondition = CONDITION_ORDER.indexOf(right.condition_set as ConditionName);
    return leftCondition - rightCondition
      || parseDuration(left.at) - parseDuration(right.at)
      || stageActionRank(left.action) - stageActionRank(right.action);
  });

  if (wakeOn.length === 0 && stages.length === 0) {
    return disabledAutoLifecycle();
  }

  return {
    wake: { on: wakeOn },
    condition_sets: conditionSets,
    stages,
  };
}

export function summarizeAutoLifecycle(policy?: AutoLifecyclePolicy | null): string {
  const normalized = policy ?? disabledAutoLifecycle();
  const wakeOn = normalizeWakeSources(normalized.wake?.on);
  const parts: string[] = [];

  if (wakeOn.length > 0) {
    parts.push(`wake:${wakeOn.join('+')}`);
  }

  for (const conditionName of CONDITION_ORDER) {
    const stages = (normalized.stages ?? [])
      .filter((stage) => stage.condition_set === conditionName)
      .map((stage) => `${stage.action}@${stage.at}`);
    if (stages.length > 0) {
      parts.push(`${conditionName}:${stages.join('->')}`);
    }
  }

  return parts.length > 0 ? parts.join(' | ') : 'off';
}

export function formatNextAutoEvent(status?: AutoLifecycleStatus | null): string {
  const seconds = status?.next_auto_event_at;
  if (!seconds) return '—';
  const now = Math.floor(Date.now() / 1000);
  const delta = seconds - now;
  if (delta === 0) return 'now';
  const formatted = formatDuration(Math.abs(delta));
  return delta > 0 ? `in ${formatted}` : `${formatted} ago`;
}

function StageList({ conditionName, disabled, prefix }: {
  conditionName: ConditionName;
  disabled?: boolean;
  prefix?: NamePath;
}) {
  return (
    <Card size="small" title={CONDITION_LABELS[conditionName]}>
      <Text type="secondary" style={{ display: 'block', marginBottom: 12 }}>
        {CONDITION_HELP[conditionName]}
      </Text>
      <Form.List name={withPrefix(prefix, conditionName)}>
        {(fields, { add, remove }) => (
          <Space orientation="vertical" size={8} style={{ width: '100%' }}>
            {fields.map((field) => (
              <Space key={field.key} align="baseline" wrap>
                <Form.Item
                  label={field.name === 0 ? 'After' : undefined}
                  name={[field.name, 'at']}
                  rules={[
                    { required: true, message: 'Delay required' },
                    {
                      validator: async (_, current) => {
                        if (!current || isValidStageDuration(current)) {
                          return;
                        }
                        throw new Error('Use positive whole-second durations like 30s, 1.5m, 2h, 1d');
                      },
                    },
                  ]}
                >
                  <Input placeholder="5m" style={{ width: 112 }} disabled={disabled} />
                </Form.Item>
                <Form.Item
                  label={field.name === 0 ? 'Action' : undefined}
                  name={[field.name, 'action']}
                  initialValue="pause"
                  rules={[{ required: true, message: 'Action required' }]}
                >
                    <Select style={{ width: 132 }} disabled={disabled}>
                      <Select.Option value="pause">Pause</Select.Option>
                      <Select.Option value="suspend">Suspend</Select.Option>
                      <Select.Option value="stop">Stop</Select.Option>
                      <Select.Option value="delete">Delete</Select.Option>
                    </Select>
                </Form.Item>
                <Button
                  type="text"
                  danger
                  icon={<MinusCircleOutlined />}
                  onClick={() => remove(field.name)}
                  disabled={disabled}
                />
              </Space>
            ))}
            <Button
              type="dashed"
              block
              icon={<PlusOutlined />}
              onClick={() => add({ at: '5m', action: 'pause' })}
              disabled={disabled}
            >
              Add Stage
            </Button>
          </Space>
        )}
      </Form.List>
    </Card>
  );
}

export function AutoLifecycleEditor({ prefix, disabled }: { prefix?: NamePath; disabled?: boolean }) {
  return (
    <Space orientation="vertical" size={12} style={{ width: '100%' }}>
      <Form.Item
        label="Wake on"
        name={withPrefix(prefix, 'wake_on')}
        tooltip="Which external access should revive a dormant sandbox."
      >
        <Select
          mode="multiple"
          allowClear
          placeholder="Select wake sources"
          disabled={disabled}
          options={[
            { value: 'access', label: 'Access' },
            { value: 'command', label: 'Command' },
          ]}
        />
      </Form.Item>
      <StageList conditionName="access_idle" prefix={prefix} disabled={disabled} />
      <StageList conditionName="command_idle" prefix={prefix} disabled={disabled} />
      <StageList conditionName="guest_activity" prefix={prefix} disabled={disabled} />
      <Text type="secondary">
        Stage delays are cumulative from the last activity or idle epoch. Use values like
        {' '}
        <code>5m</code>
        , <code>15m</code>, and <code>2h</code>.
      </Text>
    </Space>
  );
}
