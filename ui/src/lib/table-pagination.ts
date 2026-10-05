import type { TablePaginationConfig } from 'antd/es/table/interface';

export function tablePagination(label: string, defaultPageSize = 25): TablePaginationConfig {
  return {
    defaultPageSize,
    showSizeChanger: true,
    pageSizeOptions: ['10', '25', '50', '100'],
    showTotal: (total, range) => `${range[0]}-${range[1]} of ${total} ${label}`,
  };
}
