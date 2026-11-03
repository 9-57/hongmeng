import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'carbon-cloud';

/**
 * Supabase 项目地址。
 * anon key 可以安全地打进客户端：数据库侧所有业务表都开启了 RLS 且没有任何 policy，
 * anon 既不能读也不能写表，只能调用 public schema 下显式授权的 RPC；
 * 真正的权限校验在 RPC 内部通过会话 token 完成，service_role / secret key 不会出现在客户端。
 */
export const SUPABASE_URL: string = 'https://hfumlfksryyzaebiuaca.supabase.co';
export const SUPABASE_ANON_KEY: string =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhmdW1sZmtzcnl5emFlYml1YWNhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMwODk4NjYsImV4cCI6MjEwODY2NTg2Nn0.RKoeeX1QZqvS7w1aEFpJ_JGwGo432nxXCfqjMToyxe0';

/** 一次 RPC 调用的结果 */
export class RpcResponse {
  /** 是否拿到 2xx 的 HTTP 响应（false 通常意味着断网 / 超时） */
  httpOk: boolean = false;
  /** 服务端业务是否成功（响应体里的 ok 字段） */
  ok: boolean = false;
  /** 业务错误码，如 unauthorized / already_claimed / insufficient_point */
  code: string = '';
  /** 可直接展示给用户的错误描述 */
  message: string = '';
  /** 原始响应文本，调用方按各自结构解析 */
  raw: string = '';
  /** HTTP 状态码，0 表示请求没有发出去 */
  status: number = 0;
}

/** JSON 解析后的字段兜底：JSON.parse 得到的对象里字段可能缺失 */
export function asText(v: string | undefined | null, def: string): string {
  return typeof v === 'string' ? v : def;
}

export function asNumber(v: number | undefined | null, def: number): number {
  return typeof v === 'number' && isFinite(v) ? v : def;
}

/** 服务端 / PostgREST 的错误响应结构 */
class ErrorEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
}

export class SupabaseClient {
  private static instance: SupabaseClient | null = null;

  static getInstance(): SupabaseClient {
    if (SupabaseClient.instance === null) {
      SupabaseClient.instance = new SupabaseClient();
    }
    return SupabaseClient.instance;
  }

  /**
   * 调用 /rest/v1/rpc/<name>。
   * body 为 JSON 字符串，键名与数据库函数的参数名一致（p_xxx）。
   * 这里不抛异常：网络错误会被归一成 code = 'network' 的结果，UI 层只需读 message。
   */
  async rpc(name: string, body: string): Promise<RpcResponse> {
    const out = new RpcResponse();
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${SUPABASE_ANON_KEY}`
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      };
      const resp = await request.request(`${SUPABASE_URL}/rest/v1/rpc/${name}`, options);
      out.status = resp.responseCode;
      out.raw = typeof resp.result === 'string' ? resp.result as string : '';
      out.httpOk = resp.responseCode >= 200 && resp.responseCode < 300;
      if (!out.httpOk) {
        out.code = 'http_error';
        out.message = this.errorMessage(out.raw, `服务暂时不可用（${resp.responseCode}）`);
        hilog.warn(0x0000, TAG, 'rpc %{public}s http %{public}d', name, resp.responseCode);
        return out;
      }
      const env = this.parseEnvelope(out.raw);
      out.ok = env.ok;
      out.code = env.code;
      out.message = env.message;
      return out;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'rpc %{public}s failed: %{public}s', name, JSON.stringify(e));
      out.httpOk = false;
      out.status = 0;
      out.code = 'network';
      out.message = '网络连接失败，请检查网络后重试';
      return out;
    } finally {
      request.destroy();
    }
  }

  private parseEnvelope(text: string): ErrorEnvelope {
    const env = new ErrorEnvelope();
    if (text.length === 0) {
      return env;
    }
    try {
      const obj = JSON.parse(text) as ErrorEnvelope;
      if (obj === null || obj === undefined) {
        return env;
      }
      env.ok = obj.ok === true;
      env.code = asText(obj.code, '');
      env.message = asText(obj.message, '');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'rpc response is not json');
    }
    return env;
  }

  private errorMessage(text: string, fallback: string): string {
    if (text.length === 0) {
      return fallback;
    }
    try {
      const obj = JSON.parse(text) as ErrorEnvelope;
      const msg = asText(obj.message, '');
      return msg.length > 0 ? msg : fallback;
    } catch (e) {
      return fallback;
    }
  }
}

export const supabase = SupabaseClient.getInstance();
