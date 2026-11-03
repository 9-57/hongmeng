import { storage } from './StorageService';
import { asNumber, asText, RpcResponse, supabase } from './SupabaseClient';

/** 服务端返回的账号信息（camelCase，与 _user_json 一致） */
export class CloudUser {
  id: string = '';
  username: string = '';
  nickname: string = '低碳同学';
  monthGoal: number = 30;
  spentPoint: number = 0;
  createdAt: string = '';
  lastLoginAt: string = '';
}

/** 登录 / 注册结果 */
export class AuthResult {
  ok: boolean = false;
  message: string = '';
  user: CloudUser | null = null;
}

/** login_user / register_user 的响应体 */
class SessionEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  token: string = '';
  user: CloudUser | null = null;
}

class LoginArgs {
  p_username: string;
  p_password: string;

  constructor(username: string, password: string) {
    this.p_username = username;
    this.p_password = password;
  }
}

class RegisterArgs {
  p_username: string;
  p_password: string;
  p_nickname: string;

  constructor(username: string, password: string, nickname: string) {
    this.p_username = username;
    this.p_password = password;
    this.p_nickname = nickname;
  }
}

class TokenArgs {
  p_token: string;

  constructor(token: string) {
    this.p_token = token;
  }
}

/**
 * 把 JSON.parse 出来的账号对象补齐为 CloudUser。
 * 服务端字段可能缺失（例如旧账号没有 lastLoginAt），这里统一兜底。
 */
export function normalizeUser(raw: CloudUser | null): CloudUser | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const u = new CloudUser();
  u.id = asText(raw.id, '');
  u.username = asText(raw.username, '');
  u.nickname = asText(raw.nickname, '低碳同学');
  u.monthGoal = asNumber(raw.monthGoal, 30);
  u.spentPoint = asNumber(raw.spentPoint, 0);
  u.createdAt = asText(raw.createdAt, '');
  u.lastLoginAt = asText(raw.lastLoginAt, '');
  return u;
}

/**
 * 账号会话管理：
 *   - 登录 / 注册成功后把服务端下发的 token 持久化到 preferences
 *   - 启动时恢复 token，再用 get_snapshot 校验（由 CloudAccount 负责拉取）
 *   - 退出登录时先清本地再通知服务端销毁 token
 *
 * 说明：token 只是服务端 sessions 表的一行记录，真正的权限校验在 RPC 内部完成，
 * 客户端的 isLoggedIn 仅用于决定 UI 展示与是否走云端读写。
 */
export class AuthService {
  private static instance: AuthService | null = null;

  private tokenValue: string = '';
  private userValue: CloudUser | null = null;

  static getInstance(): AuthService {
    if (AuthService.instance === null) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  get token(): string {
    return this.tokenValue;
  }

  get isLoggedIn(): boolean {
    return this.tokenValue.length > 0;
  }

  get user(): CloudUser | null {
    return this.userValue;
  }

  get username(): string {
    return this.userValue === null ? '' : this.userValue.username;
  }

  /** 启动时从本地恢复 token；preferences 未就绪时不做任何事 */
  async init(): Promise<void> {
    if (!storage.isReady) {
      return;
    }
    const saved = await storage.readString(storage.sessionKey, '');
    this.tokenValue = typeof saved === 'string' ? saved : '';
  }

  async login(username: string, password: string): Promise<AuthResult> {
    const args = new LoginArgs(username.trim(), password);
    const resp = await supabase.rpc('login_user', JSON.stringify(args));
    const out = await this.handleSession(resp, '登录失败，请稍后重试');
    return out;
  }

  async register(username: string, password: string, nickname: string): Promise<AuthResult> {
    const nick = nickname.trim().length > 0 ? nickname.trim() : '低碳同学';
    const args = new RegisterArgs(username.trim(), password, nick);
    const resp = await supabase.rpc('register_user', JSON.stringify(args));
    const out = await this.handleSession(resp, '注册失败，请稍后重试');
    return out;
  }

  /** 退出登录：先清本地会话，再尽力通知服务端（失败也不阻塞用户） */
  async logout(): Promise<void> {
    const old = this.tokenValue;
    await this.clearSession();
    if (old.length === 0) {
      return;
    }
    const args = new TokenArgs(old);
    await supabase.rpc('logout_user', JSON.stringify(args));
  }

  /** 仅清本地会话（token 失效时使用） */
  async clearSession(): Promise<void> {
    this.tokenValue = '';
    this.userValue = null;
    if (storage.isReady) {
      await storage.writeString(storage.sessionKey, '');
    }
  }

  /** 用最新快照里的账号信息更新内存缓存 */
  updateUser(u: CloudUser): void {
    this.userValue = u;
  }

  private async handleSession(resp: RpcResponse, fallback: string): Promise<AuthResult> {
    const out = new AuthResult();
    if (!resp.ok) {
      out.message = resp.message.length > 0 ? resp.message : fallback;
      return out;
    }
    let env: SessionEnvelope;
    try {
      env = JSON.parse(resp.raw) as SessionEnvelope;
    } catch (e) {
      out.message = '服务返回数据异常，请稍后重试';
      return out;
    }
    const token = asText(env.token, '');
    const user = normalizeUser(env.user);
    if (token.length === 0 || user === null) {
      out.message = '服务返回数据异常，请稍后重试';
      return out;
    }
    this.tokenValue = token;
    this.userValue = user;
    if (storage.isReady) {
      await storage.writeString(storage.sessionKey, token);
    }
    out.ok = true;
    out.user = user;
    return out;
  }
}

export const auth = AuthService.getInstance();
