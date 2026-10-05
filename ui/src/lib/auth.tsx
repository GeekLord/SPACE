'use client';

import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { authApi } from './api';
import { Cluster, LoginResponse, MeResponse, Organization, Substrate, User } from './types';

interface AuthContextType {
  user: User | null;
  org: Organization | null;
  cluster: Cluster | null;
  substrate: Substrate | null;
  loading: boolean;
  login: (email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  refreshOrg: (org: Organization) => void;
  refreshCluster: (cluster: Cluster) => void;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  org: null,
  cluster: null,
  substrate: null,
  loading: true,
  login: async () => {},
  logout: async () => {},
  refreshOrg: () => {},
  refreshCluster: () => {},
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [org, setOrg] = useState<Organization | null>(null);
  const [cluster, setCluster] = useState<Cluster | null>(null);
  const [substrate, setSubstrate] = useState<Substrate | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const token = localStorage.getItem('token');
    if (!token) {
      setLoading(false);
      return;
    }

    Promise.all([authApi.get<MeResponse>('/me'), authApi.get<Cluster>('/cluster')])
      .then(([data, cluster]) => {
        setUser(data.user);
        setOrg(data.org);
        setCluster(cluster);
        setSubstrate(data.substrate ?? null);
      })
      .catch(() => {
        localStorage.removeItem('token');
      })
      .finally(() => setLoading(false));
  }, []);

  const login = async (email: string, password: string) => {
    const data = await authApi.post<LoginResponse>('/sessions', { email, password });
    localStorage.setItem('token', data.token);
    setUser(data.user);
    setOrg(data.org);
    const [me, cluster] = await Promise.all([
      authApi.get<MeResponse>('/me').catch(() => null),
      authApi.get<Cluster>('/cluster').catch(() => null),
    ]);
    setCluster(cluster);
    setSubstrate(me?.substrate ?? null);
  };

  const logout = async () => {
    try {
      await authApi.delete('/session');
    } finally {
      localStorage.removeItem('token');
      setUser(null);
      setOrg(null);
      setCluster(null);
      setSubstrate(null);
    }
  };

  const refreshOrg = (updated: Organization) => {
    setOrg(updated);
  };

  const refreshCluster = (updated: Cluster) => {
    setCluster(updated);
  };

  return (
    <AuthContext.Provider value={{ user, org, cluster, substrate, loading, login, logout, refreshOrg, refreshCluster }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
