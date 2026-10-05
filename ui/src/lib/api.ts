const API_BASE = '/api/v1';
const AUTH_BASE = '/auth/v1';
const ADMIN_BASE = '/admin/api';

type RequestMode = 'same-origin' | 'prefer-direct';

class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function directApiBase(base: string): string | null {
  if (typeof window === 'undefined') {
    return null;
  }
  if (window.location.protocol !== 'http:' || window.location.port !== '3000') {
    return null;
  }
  const host = window.location.hostname;
  if (!host || host === 'localhost' || host === '127.0.0.1' || host === '[::1]') {
    return null;
  }
  return `http://${host}:8080${base}`;
}

async function responseOnce(base: string, path: string, options: RequestInit = {}): Promise<Response> {
  const token = typeof window !== 'undefined' ? localStorage.getItem('token') : null;

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  };

  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  const res = await fetch(`${base}${path}`, {
    ...options,
    headers,
  });

  if (res.status === 401 && typeof window !== 'undefined') {
    localStorage.removeItem('token');
    window.location.href = '/login';
    throw new ApiError(401, 'Unauthorized');
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    // Admin handlers return `{ error }`; the public API envelope returns
    // `{ message }`. Prefer whichever is present so the real cause surfaces
    // instead of a generic "Request failed".
    throw new ApiError(res.status, body.error || body.message || 'Request failed');
  }

  return res;
}

async function requestOnce<T>(base: string, path: string, options: RequestInit = {}): Promise<T> {
  const res = await responseOnce(base, path, options);

  if (res.status === 204) {
    return undefined as T;
  }

  return res.json();
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  mode: RequestMode = 'same-origin',
  base: string = API_BASE,
): Promise<T> {
  if (mode === 'prefer-direct') {
    const directBase = directApiBase(base);
    if (directBase) {
      try {
        return await requestOnce<T>(directBase, path, options);
      } catch (err) {
        if (err instanceof ApiError) {
          throw err;
        }
      }
    }
  }

  return requestOnce<T>(base, path, options);
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body?: unknown, headers?: Record<string, string>) =>
    request<T>(path, { method: 'POST', body: body ? JSON.stringify(body) : undefined, headers }),
  postPreferDirect: <T>(path: string, body?: unknown) =>
    request<T>(
      path,
      { method: 'POST', body: body ? JSON.stringify(body) : undefined },
      'prefer-direct',
    ),
  patch: <T>(path: string, body?: unknown, headers?: Record<string, string>) =>
    request<T>(path, { method: 'PATCH', body: body ? JSON.stringify(body) : undefined, headers }),
  put: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: 'PUT', body: body ? JSON.stringify(body) : undefined }),
  delete: <T>(path: string, headers?: Record<string, string>) =>
    request<T>(path, { method: 'DELETE', headers }),
};

export const authApi = {
  get: <T>(path: string) => request<T>(path, {}, 'same-origin', AUTH_BASE),
  post: <T>(path: string, body?: unknown) =>
    request<T>(
      path,
      { method: 'POST', body: body ? JSON.stringify(body) : undefined },
      'same-origin',
      AUTH_BASE,
    ),
  delete: <T>(path: string) =>
    request<T>(path, { method: 'DELETE' }, 'same-origin', AUTH_BASE),
};

export const adminApi = {
  get: <T>(path: string) => requestOnce<T>(ADMIN_BASE, path),
  post: <T>(path: string, body?: unknown, headers?: Record<string, string>) =>
    requestOnce<T>(ADMIN_BASE, path, { method: 'POST', body: body ? JSON.stringify(body) : undefined, headers }),
  patch: <T>(path: string, body?: unknown, headers?: Record<string, string>) =>
    requestOnce<T>(ADMIN_BASE, path, { method: 'PATCH', body: body ? JSON.stringify(body) : undefined, headers }),
  put: <T>(path: string, body?: unknown) =>
    requestOnce<T>(ADMIN_BASE, path, { method: 'PUT', body: body ? JSON.stringify(body) : undefined }),
  delete: <T>(path: string, headers?: Record<string, string>) =>
    requestOnce<T>(ADMIN_BASE, path, { method: 'DELETE', headers }),
};
