import {
  DirectoryUser, FamilyInfo, FamilyInvite, FamilyMember, FamilySummary, Summary
} from '../model/CarbonModels';
import { asNumber, asText, supabase, RpcResponse } from './SupabaseClient';
import { auth } from './AuthService';
import { storage } from './StorageService';
import { round } from '../common/Utils';

/** 成员头像：服务端不存头像，按顺序给一个稳定的 emoji */
const MEMBER_AVATARS: string[] = ['🌿', '🍀', '🌳', '☀️', '🚲', '🌊'];

/** 一次写操作的结论 */
export class FamilyAction {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  /** accept 成功后带回的家庭 */
  family: FamilyInfo | null = null;

  static fail(code: string, message: string): FamilyAction {
    const out = new FamilyAction();
    out.code = code;
    out.message = message;
    return out;
  }
}

/* ==================== RPC 参数 ==================== */

class TokenArgs {
  p_token: string;

  constructor(token: string) {
    this.p_token = token;
  }
}

class SearchArgs {
  p_token: string;
  p_keyword: string;

  constructor(token: string, keyword: string) {
    this.p_token = token;
    this.p_keyword = keyword;
  }
}

class InviteArgs {
  p_token: string;
  p_invitee_id: string;
  p_family_name: string;

  constructor(token: string, inviteeId: string, familyName: string) {
    this.p_token = token;
    this.p_invitee_id = inviteeId;
    this.p_family_name = familyName;
  }
}

class InviteIdArgs {
  p_token: string;
  p_invite_id: string;

  constructor(token: string, inviteId: string) {
    this.p_token = token;
    this.p_invite_id = inviteId;
  }
}

/* ==================== 服务端返回的原始结构 ====================
 * 服务端字段名与前端模型不完全一致（member 用 userId，家庭用 createdAt 时间串），
 * 所以先按原始结构反序列化，再逐字段兜底成强类型对象。
 */

class RawMember {
  userId: string = '';
  username: string = '';
  nickname: string = '';
  role: string = '';
  isMe: boolean = false;
  isOwner: boolean = false;
  monthReduction: number = 0;
  todayReduction: number = 0;
  totalReduction: number = 0;
}

class RawFamily {
  id: string = '';
  name: string = '';
  inviteCode: string = '';
  ownerId: string = '';
  createdAt: string = '';
  memberLimit: number = 6;
  members: RawMember[] = [];
}

class RawInvite {
  inviteId: string = '';
  inviterId: string = '';
  inviteeId: string = '';
  nickname: string = '';
  username: string = '';
  familyName: string = '';
  hasFamily: boolean = false;
  createdAt: string = '';
  expiresAt: string = '';
}

class RawUser {
  id: string = '';
  username: string = '';
  nickname: string = '';
  hasFamily: boolean = false;
  isInMyFamily: boolean = false;
}

/* ==================== RPC 响应体 ==================== */

class StateEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  hasFamily: boolean = false;
  family: RawFamily | null = null;
  incoming: RawInvite[] | null = null;
  outgoing: RawInvite[] | null = null;
}

class SearchEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  users: RawUser[] | null = null;
}

class ActionEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  duplicated: boolean = false;
  dissolved: boolean = false;
  family: RawFamily | null = null;
}

/** 本地快照：只做"冷启动先有东西看"，真正的数据以云端为准 */
class FamilyCache {
  joined: boolean = false;
  family: FamilyInfo = new FamilyInfo();
  incoming: FamilyInvite[] = [];
  outgoing: FamilyInvite[] = [];
  cachedAt: number = 0;
}

/**
 * 家庭服务（云端版）。
 *
 * 数据全部落在 Supabase，客户端只做三件事：
 *   1. 调 RPC（family_state / family_search / family_invite / family_accept / ...）；
 *   2. 把最近一次结果缓存到 preferences，冷启动时先显示缓存再拉云端；
 *   3. 把服务端 JSON 兜底成强类型对象（字段缺失不能让页面崩）。
 *
 * 这里不再有"本地模拟用户目录"——搜索查的是真实的 users 表。
 */
export class FamilyService {
  private static instance: FamilyService | null = null;

  private familyValue: FamilyInfo = new FamilyInfo();
  private joined: boolean = false;
  private incomingValue: FamilyInvite[] = [];
  private outgoingValue: FamilyInvite[] = [];
  private myIdValue: string = '';
  private loaded: boolean = false;
  private loadPromise: Promise<void> | null = null;

  static getInstance(): FamilyService {
    if (FamilyService.instance === null) {
      FamilyService.instance = new FamilyService();
    }
    return FamilyService.instance;
  }

  /* ==================== 本地缓存 ==================== */

  /**
   * 只读本地快照，不发网络请求。
   * EntryAbility 在 auth.init() 之前就调用这里，那时还没有 token，
   * 联网必然 unauthorized，所以"加载"和"刷新"必须分开。
   * force=true 用于换账号后重读缓存（正常启动不需要）。
   */
  async load(force: boolean = false): Promise<void> {
    if (this.loaded && !force) {
      return;
    }
    if (this.loadPromise !== null) {
      await this.loadPromise;
      return;
    }
    const task = this.doLoad();
    this.loadPromise = task;
    try {
      await task;
    } finally {
      this.loadPromise = null;
    }
  }

  private async doLoad(): Promise<void> {
    this.loaded = true;
    if (!storage.isReady) {
      return;
    }
    const raw = await storage.readString(storage.familyKey, '');
    if (raw.length === 0) {
      return;
    }
    let parsed: FamilyCache | null = null;
    try {
      parsed = JSON.parse(raw) as FamilyCache;
    } catch (e) {
      parsed = null;
    }
    if (parsed === null || parsed === undefined) {
      return;
    }
    this.familyValue = this.normalizeFamily(parsed.family);
    this.joined = parsed.joined === true && this.familyValue.members.length > 0;
    this.incomingValue = this.normalizeInvites(parsed.incoming);
    this.outgoingValue = this.normalizeInvites(parsed.outgoing);
    this.myIdValue = this.pickMyId();
  }

  async ensureLoaded(callback: () => void): Promise<void> {
    if (!this.loaded) {
      try {
        await this.load();
      } catch (e) {
        // 读缓存失败也回调，页面显示空态
      }
    }
    callback();
  }

  private async persistCache(): Promise<void> {
    if (!storage.isReady) {
      return;
    }
    const cache = new FamilyCache();
    cache.joined = this.joined;
    cache.family = this.familyValue;
    cache.incoming = this.incomingValue;
    cache.outgoing = this.outgoingValue;
    cache.cachedAt = Date.now();
    await storage.writeString(storage.familyKey, JSON.stringify(cache));
  }

  /* ==================== 云端读写 ==================== */

  /**
   * 拉取家庭状态（家庭 + 收到/发出的待处理邀请）。
   * 返回可直接展示给用户的错误文案，空串表示成功。
   */
  async refresh(): Promise<string> {
    if (!auth.isLoggedIn) {
      this.clearLocal();
      return '';
    }
    const resp = await supabase.rpc('family_state', JSON.stringify(new TokenArgs(auth.token)));
    if (!resp.ok) {
      return resp.message.length > 0 ? resp.message : '家庭信息加载失败，请检查网络';
    }
    let env: StateEnvelope;
    try {
      env = JSON.parse(resp.raw) as StateEnvelope;
    } catch (e) {
      return '服务返回数据异常，请稍后重试';
    }
    this.familyValue = this.parseFamily(env.family);
    this.joined = env.hasFamily === true && this.familyValue.members.length > 0;
    this.incomingValue = this.parseInvites(env.incoming);
    this.outgoingValue = this.parseInvites(env.outgoing);
    this.myIdValue = this.pickMyId();
    this.loaded = true;
    await this.persistCache();
    return '';
  }

  /** 按用户名或昵称搜人（服务端模糊匹配，最多 10 条） */
  async search(keyword: string): Promise<DirectoryUser[]> {
    const kw = keyword.trim();
    const out: DirectoryUser[] = [];
    if (kw.length === 0 || !auth.isLoggedIn) {
      return out;
    }
    const resp = await supabase.rpc('family_search', JSON.stringify(new SearchArgs(auth.token, kw)));
    if (!resp.ok) {
      return out;
    }
    let env: SearchEnvelope;
    try {
      env = JSON.parse(resp.raw) as SearchEnvelope;
    } catch (e) {
      return out;
    }
    const list = env.users;
    if (list === null || list === undefined || !Array.isArray(list)) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      if (raw === null || raw === undefined) {
        continue;
      }
      const id = asText(raw.id, '');
      if (id.length === 0) {
        continue;
      }
      const username = asText(raw.username, '');
      const nickname = asText(raw.nickname, username);
      out.push(new DirectoryUser(id, username, nickname, MEMBER_AVATARS[i % MEMBER_AVATARS.length],
        raw.hasFamily === true, raw.isInMyFamily === true));
    }
    return out;
  }

  /** 发邀请：对方同意后才建家庭 / 并入 */
  async invite(inviteeId: string, familyName: string): Promise<FamilyAction> {
    if (!auth.isLoggedIn) {
      return FamilyAction.fail('unauthorized', '登录已失效，请重新登录');
    }
    if (inviteeId.length === 0) {
      return FamilyAction.fail('invalid_target', '请选择要邀请的成员');
    }
    const args = new InviteArgs(auth.token, inviteeId, familyName.trim());
    const resp = await supabase.rpc('family_invite', JSON.stringify(args));
    const out = this.toAction(resp, '邀请发送失败，请稍后重试');
    if (out.ok) {
      await this.refresh();
    }
    return out;
  }

  /** 同意邀请：服务端在一个事务里建家庭 + 写入双方成员 */
  async accept(inviteId: string): Promise<FamilyAction> {
    if (!auth.isLoggedIn) {
      return FamilyAction.fail('unauthorized', '登录已失效，请重新登录');
    }
    const args = new InviteIdArgs(auth.token, inviteId);
    const resp = await supabase.rpc('family_accept', JSON.stringify(args));
    const out = this.toAction(resp, '接受邀请失败，请稍后重试');
    if (!out.ok) {
      return out;
    }
    if (out.family !== null && out.family.members.length > 0) {
      this.familyValue = out.family;
      this.joined = true;
      this.myIdValue = this.pickMyId();
    }
    // 同意后收件箱整体变化（其他邀请被服务端作废），重新拉一次最准确
    await this.refresh();
    out.family = this.familyValue;
    return out;
  }

  async reject(inviteId: string): Promise<FamilyAction> {
    if (!auth.isLoggedIn) {
      return FamilyAction.fail('unauthorized', '登录已失效，请重新登录');
    }
    const resp = await supabase.rpc('family_reject', JSON.stringify(new InviteIdArgs(auth.token, inviteId)));
    const out = this.toAction(resp, '拒绝邀请失败，请稍后重试');
    if (out.ok) {
      await this.refresh();
    }
    return out;
  }

  async cancel(inviteId: string): Promise<FamilyAction> {
    if (!auth.isLoggedIn) {
      return FamilyAction.fail('unauthorized', '登录已失效，请重新登录');
    }
    const resp = await supabase.rpc('family_cancel', JSON.stringify(new InviteIdArgs(auth.token, inviteId)));
    const out = this.toAction(resp, '撤回邀请失败，请稍后重试');
    if (out.ok) {
      await this.refresh();
    }
    return out;
  }

  /** 退出家庭；房主退出 = 解散 */
  async leave(): Promise<FamilyAction> {
    if (!auth.isLoggedIn) {
      return FamilyAction.fail('unauthorized', '登录已失效，请重新登录');
    }
    const wasOwner = this.isOwner();
    const resp = await supabase.rpc('family_leave', JSON.stringify(new TokenArgs(auth.token)));
    const out = this.toAction(resp, wasOwner ? '解散家庭失败，请稍后重试' : '退出家庭失败，请稍后重试');
    if (out.ok) {
      this.clearLocal();
      await this.refresh();
    }
    return out;
  }

  private toAction(resp: RpcResponse, fallback: string): FamilyAction {
    const out = new FamilyAction();
    if (!resp.ok) {
      out.code = resp.code;
      out.message = resp.message.length > 0 ? resp.message : fallback;
      return out;
    }
    let env: ActionEnvelope;
    try {
      env = JSON.parse(resp.raw) as ActionEnvelope;
    } catch (e) {
      out.message = '服务返回数据异常，请稍后重试';
      return out;
    }
    out.ok = true;
    out.code = asText(env.code, '');
    out.message = asText(env.message, '');
    out.family = this.parseFamily(env.family);
    if (out.family.members.length === 0) {
      out.family = null;
    }
    return out;
  }

  /* ==================== 查询 ==================== */

  hasFamily(): boolean {
    return this.joined && this.familyValue.members.length > 0;
  }

  family(): FamilyInfo {
    return this.familyValue;
  }

  /** 当前账号 id（uuid）；未登录或未拉到快照时为空 */
  myId(): string {
    if (this.myIdValue.length === 0) {
      this.myIdValue = this.pickMyId();
    }
    return this.myIdValue;
  }

  isOwner(): boolean {
    if (!this.hasFamily()) {
      return false;
    }
    const mine = this.myId();
    return mine.length > 0 && this.familyValue.ownerId === mine;
  }

  memberLimit(): number {
    return this.familyValue.memberLimit > 0 ? this.familyValue.memberLimit : 6;
  }

  /** 收到的待处理邀请 */
  incoming(): FamilyInvite[] {
    return this.incomingValue;
  }

  /** 自己发出、对方还没处理的邀请 */
  outgoing(): FamilyInvite[] {
    return this.outgoingValue;
  }

  /** 需要处理的动作数量（红点用） */
  pendingCount(): number {
    return this.incomingValue.length;
  }

  /* ==================== 汇总 ==================== */

  /**
   * 家庭汇总。成员减排量全部来自服务端 carbon_records（按 Asia/Shanghai 统计），
   * my 参数只作兜底：本地刚记完账、云端统计还没刷新时取较大值。
   */
  summary(my: Summary): FamilySummary {
    const out = new FamilySummary();
    if (!this.hasFamily()) {
      return out;
    }
    for (const m of this.familyValue.members) {
      let month = m.monthReduction;
      let today = m.todayReduction;
      let total = m.totalReduction;
      if (m.isMe) {
        month = Math.max(month, my.monthReduction);
        today = Math.max(today, my.todayReduction);
        total = Math.max(total, my.totalReduction);
      }
      out.monthReduction += month;
      out.todayReduction += today;
      out.totalReduction += total;
    }
    out.memberCount = this.familyValue.members.length;
    out.monthReduction = round(out.monthReduction, 2);
    out.todayReduction = round(out.todayReduction, 2);
    out.totalReduction = round(out.totalReduction, 2);
    out.treeCount = round(out.totalReduction / 18, 2);
    out.averageMonth = out.memberCount > 0 ? round(out.monthReduction / out.memberCount, 2) : 0;
    return out;
  }

  memberRatio(member: FamilyMember, totalMonth: number): number {
    if (totalMonth <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, member.monthReduction / totalMonth));
  }

  /* ==================== 备份兼容 ==================== */

  /**
   * 家庭是账号级云端数据，不随本机备份文件迁移。
   * 返回空串，CarbonStore 的恢复流程就不会尝试写回家庭。
   */
  exportState(): string {
    return '';
  }

  /** 旧备份里的家庭数据不再导入（以云端为准） */
  async importState(raw: string): Promise<boolean> {
    return false;
  }

  /** 清空本机缓存，不动云端家庭 */
  async reset(): Promise<void> {
    this.clearLocal();
    if (storage.isReady) {
      await storage.writeString(storage.familyKey, '');
    }
  }

  private clearLocal(): void {
    this.familyValue = new FamilyInfo();
    this.joined = false;
    this.incomingValue = [];
    this.outgoingValue = [];
    this.myIdValue = '';
    this.loaded = true;
  }

  /* ==================== 解析 ==================== */

  private pickMyId(): string {
    const u = auth.user;
    if (u !== null && u !== undefined && u.id.length > 0) {
      return u.id;
    }
    for (const m of this.familyValue.members) {
      if (m.isMe) {
        return m.id;
      }
    }
    return '';
  }

  /** 服务端家庭 JSON → FamilyInfo */
  private parseFamily(raw: RawFamily | null): FamilyInfo {
    const family = new FamilyInfo();
    if (raw === null || raw === undefined) {
      return family;
    }
    family.id = asText(raw.id, '');
    family.name = asText(raw.name, '');
    family.inviteCode = asText(raw.inviteCode, '');
    family.ownerId = asText(raw.ownerId, '');
    family.memberLimit = asNumber(raw.memberLimit, 6);
    const created = asText(raw.createdAt, '');
    if (created.length > 0) {
      const t = Date.parse(created);
      family.createdAt = isFinite(t) ? t : 0;
    }
    const members: FamilyMember[] = [];
    const list = raw.members;
    if (list !== null && list !== undefined && Array.isArray(list)) {
      for (let i = 0; i < list.length; i++) {
        const item = list[i];
        if (item === null || item === undefined) {
          continue;
        }
        const id = asText(item.userId, '');
        if (id.length === 0) {
          continue;
        }
        const nickname = asText(item.nickname, '成员');
        const isMe = item.isMe === true;
        const isOwner = item.isOwner === true || asText(item.role, '') === 'owner';
        members.push(new FamilyMember(
          id,
          asText(item.username, ''),
          nickname,
          isMe ? '🌱' : (isOwner ? '🏡' : MEMBER_AVATARS[i % MEMBER_AVATARS.length]),
          isMe,
          isOwner,
          asNumber(item.monthReduction, 0),
          asNumber(item.todayReduction, 0),
          asNumber(item.totalReduction, 0)
        ));
      }
    }
    family.members = members;
    if (family.name.length === 0 && members.length > 0) {
      family.name = '我的家庭';
    }
    return family;
  }

  /** 服务端邀请数组 → FamilyInvite[] */
  private parseInvites(raw: RawInvite[] | null): FamilyInvite[] {
    const out: FamilyInvite[] = [];
    if (raw === null || raw === undefined || !Array.isArray(raw)) {
      return out;
    }
    for (let i = 0; i < raw.length; i++) {
      const item = raw[i];
      if (item === null || item === undefined) {
        continue;
      }
      const inviteId = asText(item.inviteId, '');
      if (inviteId.length === 0) {
        continue;
      }
      const inv = new FamilyInvite();
      inv.inviteId = inviteId;
      inv.inviterId = asText(item.inviterId, '');
      inv.inviteeId = asText(item.inviteeId, '');
      inv.username = asText(item.username, '');
      inv.nickname = asText(item.nickname, inv.username);
      inv.familyName = asText(item.familyName, '我的低碳家庭');
      inv.hasFamily = item.hasFamily === true;
      inv.createdAt = asText(item.createdAt, '');
      inv.expiresAt = asText(item.expiresAt, '');
      out.push(inv);
    }
    return out;
  }

  /** 本地缓存反序列化（字段与 FamilyInfo/FamilyInvite 一致，只需兜底） */
  private normalizeFamily(raw: FamilyInfo): FamilyInfo {
    const family = new FamilyInfo();
    if (raw === null || raw === undefined) {
      return family;
    }
    family.id = asText(raw.id, '');
    family.name = asText(raw.name, '');
    family.inviteCode = asText(raw.inviteCode, '');
    family.ownerId = asText(raw.ownerId, '');
    family.memberLimit = asNumber(raw.memberLimit, 6);
    family.createdAt = asNumber(raw.createdAt, 0);
    const members: FamilyMember[] = [];
    if (Array.isArray(raw.members)) {
      for (const item of raw.members) {
        if (item === null || item === undefined) {
          continue;
        }
        const id = asText(item.id, '');
        if (id.length === 0) {
          continue;
        }
        members.push(new FamilyMember(
          id,
          asText(item.username, ''),
          asText(item.name, '成员'),
          asText(item.avatar, '🌱'),
          item.isMe === true,
          item.isOwner === true,
          asNumber(item.monthReduction, 0),
          asNumber(item.todayReduction, 0),
          asNumber(item.totalReduction, 0)
        ));
      }
    }
    family.members = members;
    return family;
  }

  private normalizeInvites(raw: FamilyInvite[]): FamilyInvite[] {
    const out: FamilyInvite[] = [];
    if (raw === null || raw === undefined || !Array.isArray(raw)) {
      return out;
    }
    for (const item of raw) {
      if (item === null || item === undefined) {
        continue;
      }
      const inviteId = asText(item.inviteId, '');
      if (inviteId.length === 0) {
        continue;
      }
      const inv = new FamilyInvite();
      inv.inviteId = inviteId;
      inv.inviterId = asText(item.inviterId, '');
      inv.inviteeId = asText(item.inviteeId, '');
      inv.username = asText(item.username, '');
      inv.nickname = asText(item.nickname, inv.username);
      inv.familyName = asText(item.familyName, '我的低碳家庭');
      inv.hasFamily = item.hasFamily === true;
      inv.createdAt = asText(item.createdAt, '');
      inv.expiresAt = asText(item.expiresAt, '');
      out.push(inv);
    }
    return out;
  }
}

export const familyService = FamilyService.getInstance();
