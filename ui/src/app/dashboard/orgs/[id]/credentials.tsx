'use client';

import { useEffect, useState } from 'react';
import { Button, Form, Input, Popconfirm, Table, Typography, message } from 'antd';
import { DeleteOutlined, PlusOutlined } from '@ant-design/icons';
import { adminApi } from '@/lib/api';
import type { Credential } from '@/lib/types';

const { Text } = Typography;

export default function OrgCredentialsTable({ orgId }: { orgId: string }) {
  const [credentials, setCredentials] = useState<Credential[]>([]);
  const [loading, setLoading] = useState(true);
  const [form] = Form.useForm();

  const load = async () => {
    setLoading(true);
    try {
      setCredentials(await adminApi.get<Credential[]>(`/v1/orgs/${orgId}/credentials`));
    } catch (err: any) {
      message.error(err.message || 'failed to load credentials');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, [orgId]);

  const handleCreate = async (values: { key: string; value: string }) => {
    try {
      await adminApi.post(`/v1/orgs/${orgId}/credentials`, {
        key: values.key.trim(),
        value: values.value,
      });
      form.resetFields();
      await load();
      message.success('Credential added');
    } catch (err: any) {
      message.error(err.message || 'failed to add credential');
    }
  };

  const handleDelete = async (id: string) => {
    try {
      await adminApi.delete(`/v1/orgs/${orgId}/credentials/${id}`);
      await load();
      message.success('Credential deleted');
    } catch (err: any) {
      message.error(err.message || 'failed to delete credential');
    }
  };

  const columns = [
    { title: 'Key', dataIndex: 'key', key: 'key' },
    {
      title: 'Value',
      key: 'value',
      render: () => <Text type="secondary">write-only</Text>,
    },
    { title: 'Updated', dataIndex: 'updated_at', key: 'updated_at' },
    {
      title: 'Action',
      key: 'action',
      render: (_: unknown, record: Credential) => (
        <Popconfirm title="Delete this credential?" onConfirm={() => handleDelete(record.id)}>
          <Button type="text" danger icon={<DeleteOutlined />} />
        </Popconfirm>
      ),
    },
  ];

  return (
    <>
      <Form form={form} layout="inline" onFinish={handleCreate} style={{ marginBottom: 16 }}>
        <Form.Item name="key" rules={[{ required: true, message: 'Key required' }]}>
          <Input placeholder="Key (e.g. ANTHROPIC_API_KEY)" />
        </Form.Item>
        <Form.Item name="value" rules={[{ required: true, message: 'Value required' }]}>
          <Input.Password placeholder="Value" />
        </Form.Item>
        <Form.Item>
          <Button type="primary" htmlType="submit" icon={<PlusOutlined />}>
            Add
          </Button>
        </Form.Item>
      </Form>
      <Table
        dataSource={credentials}
        columns={columns}
        rowKey="id"
        loading={loading}
        pagination={false}
        size="small"
      />
    </>
  );
}
