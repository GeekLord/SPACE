import { adminApi } from '@/lib/api';

export type ProcessOutcome =
  | { type: 'exited'; exitCode: number }
  | { type: 'status'; status: string; exitCode: number }
  | { type: 'unknown' };

export interface ProcessRunResult {
  sessionId: string | null;
  processId: string | null;
  stdout: string;
  stderr: string;
  stdoutBytes: number;
  stderrBytes: number;
  outcome: ProcessOutcome | null;
}

interface PublicCommand {
  id: string;
  session_id: string;
  attach?: {
    url: string;
    events_url?: string | null;
    token: string;
  } | null;
}

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

function decodeBase64Bytes(data: string): Uint8Array {
  const raw = window.atob(data);
  const bytes = new Uint8Array(raw.length);
  for (let index = 0; index < raw.length; index += 1) {
    bytes[index] = raw.charCodeAt(index);
  }
  return bytes;
}

function idempotencyKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `command-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function processOutcome(frame: Extract<DataPlaneServerFrame, { type: 'process_exited' }>): ProcessOutcome {
  if (frame.status === 'exited') {
    return { type: 'exited', exitCode: frame.exit_code };
  }
  return { type: 'status', status: frame.status, exitCode: frame.exit_code };
}

function commandEventsUrl(command: PublicCommand): string {
  const eventsUrl = command.attach?.events_url;
  if (eventsUrl) {
    return new URL(eventsUrl, window.location.origin).toString();
  }

  const attachUrl = command.attach?.url;
  if (!attachUrl) {
    throw new Error('Command did not return a data-plane event stream URL');
  }
  const parsed = new URL(attachUrl, window.location.origin);
  parsed.pathname = parsed.pathname.replace(/\/attach$/, '/events');
  return parsed.toString();
}

function parseSseFrames(chunk: string, onFrame: (frame: DataPlaneServerFrame) => void): string {
  const normalized = chunk.replace(/\r\n/g, '\n');
  const parts = normalized.split('\n\n');
  const remainder = parts.pop() ?? '';

  for (const part of parts) {
    const data = part
      .split('\n')
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trimStart())
      .join('\n');
    if (!data) continue;
    onFrame(JSON.parse(data) as DataPlaneServerFrame);
  }

  return remainder;
}

export async function runSandboxCommand(
  sandboxId: string,
  command: string[],
  onUpdate: (result: ProcessRunResult) => void,
): Promise<ProcessRunResult> {
  // The console lists sandboxes across every org, so commands go through the
  // cross-org operator endpoint. The org-scoped public command endpoint rejects
  // any sandbox the signed-in admin does not personally own with "sandbox not
  // found", which made every command in this widget fail.
  const commandHandle = await adminApi.post<PublicCommand>(
    `/v1/sandboxes/${sandboxId}/commands`,
    {
      command,
      cwd: null,
      env: {},
      pty: null,
      stdin: false,
      timeout: null,
    },
    { 'Idempotency-Key': idempotencyKey() },
  );

  if (!commandHandle.attach?.token) {
    throw new Error('Command did not return a data-plane token');
  }

  let result: ProcessRunResult = {
    sessionId: commandHandle.session_id || commandHandle.id,
    processId: null,
    stdout: '',
    stderr: '',
    stdoutBytes: 0,
    stderrBytes: 0,
    outcome: null,
  };
  const stdoutDecoder = new TextDecoder();
  const stderrDecoder = new TextDecoder();

  const update = (next: ProcessRunResult) => {
    result = next;
    onUpdate(result);
  };

  const response = await fetch(commandEventsUrl(commandHandle), {
    headers: {
      Accept: 'text/event-stream',
      Authorization: `Bearer ${commandHandle.attach.token}`,
    },
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(body || `Command stream failed with HTTP ${response.status}`);
  }
  if (!response.body) {
    throw new Error('Command stream did not return a response body');
  }

  const reader = response.body.getReader();
  const streamDecoder = new TextDecoder();
  let buffer = '';

  const handleFrame = (frame: DataPlaneServerFrame) => {
    switch (frame.type) {
      case 'attached':
        update({ ...result, sessionId: frame.session_id });
        break;
      case 'process_started':
        update({ ...result, processId: frame.process_id });
        break;
      case 'stdout': {
        const bytes = decodeBase64Bytes(frame.data_base64);
        update({
          ...result,
          stdout: result.stdout + stdoutDecoder.decode(bytes, { stream: true }),
          stdoutBytes: result.stdoutBytes + bytes.length,
        });
        break;
      }
      case 'stderr': {
        const bytes = decodeBase64Bytes(frame.data_base64);
        update({
          ...result,
          stderr: result.stderr + stderrDecoder.decode(bytes, { stream: true }),
          stderrBytes: result.stderrBytes + bytes.length,
        });
        break;
      }
      case 'process_exited':
        update({
          ...result,
          processId: frame.process_id,
          stdout: result.stdout + stdoutDecoder.decode(),
          stderr: result.stderr + stderrDecoder.decode(),
          outcome: processOutcome(frame),
        });
        break;
      case 'error':
        throw new Error(frame.message || frame.code || 'Command stream failed');
      case 'resync_required':
        throw new Error(`Command stream requires resync: ${frame.reason}`);
      case 'closed':
        if (!result.outcome) {
          throw new Error(`Command stream closed before process exit: ${frame.reason}`);
        }
        break;
      case 'backend_reconnecting':
      case 'backend_reconnected':
      case 'input_accepted':
      case 'control_accepted':
      case 'file_event':
        break;
    }
  };

  while (!result.outcome) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    buffer = parseSseFrames(buffer + streamDecoder.decode(value, { stream: true }), handleFrame);
  }

  if (buffer.trim()) {
    parseSseFrames(`${buffer}\n\n`, handleFrame);
  }

  if (!result.outcome) {
    throw new Error('Command stream closed before process exit');
  }

  return result;
}
