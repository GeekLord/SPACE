import { api } from '@/lib/api';

type DataPlaneAttachInfo = {
  url: string;
  events_url?: string | null;
  token: string;
};

type PublicSession = {
  id: string;
  attach?: DataPlaneAttachInfo | null;
};

type DataPlaneServerFrame =
  | { type: 'attached'; session_id: string; route_generation: number; current_node_id: string }
  | { type: 'process_started'; process_id: string; pid?: number | null }
  | { type: 'stdout'; seq: number; data_base64: string }
  | { type: 'stderr'; seq: number; data_base64: string }
  | { type: 'input_accepted'; seq: number }
  | { type: 'control_accepted'; seq: number }
  | { type: 'process_exited'; process_id: string; exit_code: number; status: string }
  | { type: 'backend_reconnecting'; reason: string; route_generation: number }
  | { type: 'backend_reconnected'; route_generation: number; current_node_id: string }
  | { type: 'resync_required'; reason: string }
  | { type: 'error'; code: string; message: string; retryable: boolean }
  | { type: 'closed'; reason: string }
  | { type: 'file_event'; seq: number; path: string; kind: string };

export type TerminalSessionEvent =
  | { type: 'status'; status: 'connecting' | 'attached' | 'closed'; message?: string }
  | { type: 'started'; processId: string; pid: number | null }
  | { type: 'output'; stream: 'stdout' | 'stderr'; text: string }
  | { type: 'accepted'; seq: number }
  | { type: 'exited'; processId: string; exitCode: number; status: string }
  | { type: 'reconnecting'; message: string }
  | { type: 'error'; message: string; retryable: boolean };

export type TerminalConnection = {
  readonly sessionId: string;
  sendInput: (input: string) => void;
  resize: (cols: number, rows: number) => void;
  close: () => void;
};

type TerminalOptions = {
  cols: number;
  rows: number;
};

function idempotencyKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `terminal-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function toWebSocketUrl(rawUrl: string): string {
  const parsed = new URL(rawUrl, window.location.origin);
  if (parsed.protocol === 'https:') {
    parsed.protocol = 'wss:';
  } else if (parsed.protocol === 'http:') {
    parsed.protocol = 'ws:';
  }
  return parsed.toString();
}

function encodeBase64(input: string): string {
  const bytes = new TextEncoder().encode(input);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return window.btoa(binary);
}

function decodeBase64(input: string, decoder: TextDecoder): string {
  const raw = window.atob(input);
  const bytes = new Uint8Array(raw.length);
  for (let index = 0; index < raw.length; index += 1) {
    bytes[index] = raw.charCodeAt(index);
  }
  return decoder.decode(bytes, { stream: true });
}

export async function openSandboxTerminal(
  sandboxId: string,
  onEvent: (event: TerminalSessionEvent) => void,
  options: TerminalOptions,
): Promise<TerminalConnection> {
  const session = await api.post<PublicSession>(
    `/sandboxes/${sandboxId}/terminal-sessions`,
    {
      command: [],
      cwd: null,
      env: {},
      size: { cols: options.cols, rows: options.rows },
    },
    { 'Idempotency-Key': idempotencyKey() },
  );

  const attach = session.attach;
  if (!attach?.url || !attach.token) {
    throw new Error('Terminal session did not return a data-plane attach token');
  }

  const socket = new WebSocket(toWebSocketUrl(attach.url));
  const stdoutDecoder = new TextDecoder();
  const stderrDecoder = new TextDecoder();
  let seq = 0;
  let closed = false;
  let heartbeat: number | null = null;

  const sendJson = (frame: unknown) => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(frame));
    }
  };

  const closeSocket = (notifyBackend: boolean) => {
    if (closed) return;
    closed = true;
    if (heartbeat) {
      window.clearInterval(heartbeat);
      heartbeat = null;
    }
    if (notifyBackend) {
      sendJson({ type: 'close' });
    }
    socket.close();
  };

  socket.addEventListener('open', () => {
    onEvent({ type: 'status', status: 'connecting' });
    sendJson({ type: 'attach', token: attach.token });
    heartbeat = window.setInterval(() => {
      seq += 1;
      sendJson({ type: 'heartbeat', seq });
    }, 25_000);
  });

  socket.addEventListener('message', (event) => {
    if (typeof event.data !== 'string') {
      onEvent({ type: 'error', message: 'Terminal received a non-text frame', retryable: false });
      return;
    }

    let frame: DataPlaneServerFrame;
    try {
      frame = JSON.parse(event.data) as DataPlaneServerFrame;
    } catch (error) {
      onEvent({ type: 'error', message: `Terminal received invalid JSON: ${error}`, retryable: false });
      return;
    }

    switch (frame.type) {
      case 'attached':
        onEvent({ type: 'status', status: 'attached' });
        break;
      case 'process_started':
        onEvent({ type: 'started', processId: frame.process_id, pid: frame.pid ?? null });
        break;
      case 'stdout':
        onEvent({ type: 'output', stream: 'stdout', text: decodeBase64(frame.data_base64, stdoutDecoder) });
        break;
      case 'stderr':
        onEvent({ type: 'output', stream: 'stderr', text: decodeBase64(frame.data_base64, stderrDecoder) });
        break;
      case 'input_accepted':
      case 'control_accepted':
        onEvent({ type: 'accepted', seq: frame.seq });
        break;
      case 'process_exited':
        onEvent({
          type: 'output',
          stream: 'stdout',
          text: stdoutDecoder.decode() + stderrDecoder.decode(),
        });
        onEvent({
          type: 'exited',
          processId: frame.process_id,
          exitCode: frame.exit_code,
          status: frame.status,
        });
        closeSocket(false);
        break;
      case 'backend_reconnecting':
        onEvent({ type: 'reconnecting', message: `Backend reconnecting: ${frame.reason}` });
        break;
      case 'backend_reconnected':
        onEvent({ type: 'reconnecting', message: `Backend reconnected to ${frame.current_node_id}` });
        break;
      case 'resync_required':
        onEvent({ type: 'error', message: `Terminal requires resync: ${frame.reason}`, retryable: true });
        break;
      case 'error':
        onEvent({ type: 'error', message: frame.message || frame.code, retryable: frame.retryable });
        break;
      case 'closed':
        onEvent({ type: 'status', status: 'closed', message: frame.reason });
        closeSocket(false);
        break;
      case 'file_event':
        break;
    }
  });

  socket.addEventListener('error', () => {
    onEvent({ type: 'error', message: 'Terminal WebSocket failed', retryable: true });
  });

  socket.addEventListener('close', () => {
    if (heartbeat) {
      window.clearInterval(heartbeat);
      heartbeat = null;
    }
    onEvent({ type: 'status', status: 'closed' });
  });

  return {
    sessionId: session.id,
    sendInput(input: string) {
      seq += 1;
      sendJson({ type: 'input', seq, data_base64: encodeBase64(input) });
    },
    resize(cols: number, rows: number) {
      sendJson({ type: 'resize', cols, rows });
    },
    close: () => closeSocket(true),
  };
}
