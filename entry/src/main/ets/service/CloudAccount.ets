import { Activity, CarbonRecord } from '../model/CarbonModels';
import { DAILY_TASKS, REDEEM_BADGES } from '../model/CarbonData';
import { AccountMeta, BackupPackage, carbonStore } from '../viewmodel/CarbonStore';
import { bumpDataVersion, todayStr } from '../common/Utils';
import { asNumber, asText, supabase } from './SupabaseClient';
import { AuthResult, auth, CloudUser, normalizeUser } from './AuthService';

/** 一次写操作的结果；point = -1 表示需要提示失败，UI 可直接展示 message */
export class OpResult {
  ok: boolean = false;
  message: string = '';
  point: number = 0;
}

// ==================== 服务端响应结构 ====================

class SnapshotBadge {
  badgeId: string = '';
  kind: string = '';
  cost: number = 0;
  obtainedAt: number = 0;
}

class SnapshotClaim {
  claimDate: string = '';
  taskId: string = '';
  reward: number = 0;
}

class SnapshotEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  user: CloudUser | null = null;
  records: CarbonRecord[] = [];
  badges: SnapshotBadge[] = [];
  claims: SnapshotClaim[] = [];
}

class SpentEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  spentPoint: number = 0;
  available: number = 0;
  revoked: boolean = false;
}

// ==================== RPC 请求体（键名与数据库函数参数一致） ====================

class TokenArgs {
  p_token: string;

  constructor(token: string) {
    this.p_token = token;
  }
}

class RecordArgs {
  p_token: string;
  p_record: CarbonRecord;

  constructor(token: string, record: CarbonRecord) {
    this.p_token = token;
    this.p_record = record;
  }
}

class DeleteArgs {
  p_token: string;
  p_record_id: string;

  constructor(token: string, id: string) {
    this.p_token = token;
    this.p_record_id = id;
  }
}

class ClaimArgs {
  p_token: string;
  p_task_id: string;
  p_claim_date: string;
  p_reward: number;

  constructor(token: string, taskId: string, claimDate: string, reward: number) {
    this.p_token = token;
    this.p_task_id = taskId;
    this.p_claim_date = claimDate;
    this.p_reward = reward;
  }
}

class RevokeArgs {
  p_token: string;
  p_task_id: string;
  p_claim_date: string;

  constructor(token: string, taskId: string, claimDate: string) {
    this.p_token = token;
    this.p_task_id = taskId;
    this.p_claim_date = claimDate;
  }
}

class RedeemArgs {
  p_token: string;
  p_badge_id: string;
  p_cost: number;

  constructor(token: string, badgeId: string, cost: number) {
    this.p_token = token;
    this.p_badge_id = badgeId;
    this.p_cost = cost;
  }
}

class ProfileArgs {
  p_token: string;
  p_nickname: string;
  p_month_goal: number;

  constructor(token: string, nickname: string, monthGoal: number) {
    this.p_token = token;
    this.p_nickname = nickname;
    this.p_month_goal = monthGoal;
  }
}

class RestoreClaim {
  claimDate: string = '';
  taskId: string = '';
  reward: number = 0;
}

class RestoreBadge {
  badgeId: string = '';
  cost: number = 0;
}

class RestorePayload {
  records: CarbonRecord[] = [];
  claims: RestoreClaim[] = [];
  badges: RestoreBadge[] = [];
  nickname: string = '低碳同学';
  monthGoal: number = 30;
  spentPoint: number = 0;
}

class SnapshotArgs {
  p_token: string;
  p_payload: RestorePayload;

  constructor(token: string, payload: RestorePayload) {
    this.p_token = token;
    this.p_payload = payload;
  }
}

/**
 * 云账户业务层：所有写操作都遵循"先服务端成功、再更新本地"的顺序。
 * 积分、记录、任务领取、勋章兑换都属于账号数据，未登录一律拒绝写入，
 * 访客状态只能是空白模板，避免把积分领到没有归属的本地存储里。
 */
export class CloudAccount {
  private static instance: CloudAccount | null = null;

  static getInstance(): CloudAccount {
    if (CloudAccount.instance === null) {
      CloudAccount.instance = new CloudAccount();
    }
    return CloudAccount.instance;
  }

  /** 未登录时统一拒绝账号级写操作，返回 true 表示已拒绝 */
  private denyGuest(out: OpResult, action: string): boolean {
    if (auth.isLoggedIn) {
      return false;
    }
    out.message = `请先登录后再${action}`;
    return true;
  }

  /**
   * 启动恢复：本地有 token 时拉取该账号的全量数据覆盖本地；
   * 没有 token 说明是访客，必须清掉本地残留的账号数据，回到空白模板。
   */
  async restore(): Promise<OpResult> {
    const out = new OpResult();
    if (!auth.isLoggedIn) {
      // 访客不应看到任何账号数据 —— 但这里不能直接 clearAll()。
      // 融合后的版本里本地账本还承载离线记录、证书与家庭，启动即清空会直接丢数据；
      // 未登录的数据可见性由 MineTab 的 GuestTemplate 负责隐藏，这里只跳过同步。
      out.ok = true;
      return out;
    }
    return await this.pull('账号数据同步失败');
  }

  /** 登录：成功后清空本地旧数据，再拉取该账号的数据 */
  async login(username: string, password: string): Promise<OpResult> {
    const gate = await this.signIn(username, password, '');
    return gate;
  }

  /** 注册：注册成功即登录，随后拉取（新账号为空） */
  async register(username: string, password: string, nickname: string): Promise<OpResult> {
    return await this.signIn(username, password, nickname);
  }

  private async signIn(username: string, password: string, nickname: string): Promise<OpResult> {
    const out = new OpResult();
    let res: AuthResult;
    if (nickname.length > 0) {
      res = await auth.register(username, password, nickname);
    } else {
      res = await auth.login(username, password);
    }
    if (!res.ok) {
      out.message = res.message;
      return out;
    }
    // 换账号必须先把上一个账号的本地数据清掉，避免串号
    await carbonStore.clearAll();
    const pulled = await this.pull('登录成功，但账号数据拉取失败');
    bumpDataVersion();
    if (!pulled.ok) {
      out.ok = true;
      out.message = pulled.message;
      return out;
    }
    out.ok = true;
    return out;
  }

  /** 退出登录：销毁服务端 token，并清空本地数据回到未登录模板 */
  async logout(): Promise<void> {
    await auth.logout();
    await carbonStore.clearAll();
    bumpDataVersion();
  }

  /** 新增记录 */
  async addRecord(activity: Activity, qty: number, dateStr: string, note: string): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '记账')) {
      return out;
    }
    const record = carbonStore.createRecord(activity, qty, dateStr, note);
    const resp = await supabase.rpc('add_record', JSON.stringify(new RecordArgs(auth.token, record)));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '记录保存失败，请检查网络');
      return out;
    }
    await carbonStore.appendRecord(record);
    bumpDataVersion();
    out.ok = true;
    out.point = record.point;
    return out;
  }

  /** 删除记录（含服务端领奖回滚） */
  async deleteRecord(id: string): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '删除记录')) {
      return out;
    }
    const resp = await supabase.rpc('delete_record', JSON.stringify(new DeleteArgs(auth.token, id)));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '删除失败，请检查网络');
      return out;
    }
    const revoked = await carbonStore.deleteRecord(id);
    if (revoked.length > 0) {
      let spent = carbonStore.meta.spentPoint;
      for (const key of revoked) {
        const parts = key.split('#');
        if (parts.length !== 2) {
          continue;
        }
        const args = new RevokeArgs(auth.token, parts[1], parts[0]);
        const resp = await supabase.rpc('revoke_claim', JSON.stringify(args));
        const env = this.parseSpent(resp.raw);
        if (resp.ok && env !== null) {
          spent = env.spentPoint;
        }
      }
      // 以服务端账目为准，避免本地与云端在实际消费积分上出现分叉
      await carbonStore.applyRevokedClaims(revoked, spent);
    }
    bumpDataVersion();
    out.ok = true;
    return out;
  }

  /** 领取每日任务奖励 */
  async claimTask(taskId: string, reward: number): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '领取任务奖励')) {
      return out;
    }
    const args = new ClaimArgs(auth.token, taskId, todayStr(), reward);
    const resp = await supabase.rpc('claim_task', JSON.stringify(args));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '领取失败，请检查网络');
      return out;
    }
    const env = this.parseSpent(resp.raw);
    await carbonStore.applyClaim(taskId, env === null ? carbonStore.meta.spentPoint : env.spentPoint);
    bumpDataVersion();
    out.ok = true;
    out.point = reward;
    return out;
  }

  /** 兑换勋章 */
  async redeem(badgeId: string, cost: number): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '兑换勋章')) {
      return out;
    }
    const args = new RedeemArgs(auth.token, badgeId, cost);
    const resp = await supabase.rpc('redeem_badge', JSON.stringify(args));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '兑换失败，请检查网络');
      return out;
    }
    const env = this.parseSpent(resp.raw);
    await carbonStore.applyRedeem(badgeId, env === null ? carbonStore.meta.spentPoint : env.spentPoint);
    bumpDataVersion();
    out.ok = true;
    return out;
  }

  /** 保存昵称 / 月目标 */
  async updateProfile(nickName: string, monthGoal: number): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '修改个人资料')) {
      return out;
    }
    const nick = nickName.trim().length > 0 ? nickName.trim() : carbonStore.nickName;
    const goal = monthGoal > 0 ? Math.round(monthGoal) : carbonStore.monthGoal;
    const args = new ProfileArgs(auth.token, nick, goal);
    const resp = await supabase.rpc('update_profile', JSON.stringify(args));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '保存失败，请检查网络');
      return out;
    }
    const env = this.parseSnapshot(resp.raw);
    if (env !== null) {
      const user = normalizeUser(env.user);
      if (user !== null) {
        auth.updateUser(user);
      }
    }
    await carbonStore.applyProfile(nick, goal);
    bumpDataVersion();
    out.ok = true;
    return out;
  }

  /** 清空当前账号的业务数据（保留昵称与月目标） */
  async clearAll(): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '清空数据')) {
      return out;
    }
    const resp = await supabase.rpc('clear_records', JSON.stringify(new TokenArgs(auth.token)));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '清空失败，请检查网络');
      return out;
    }
    await carbonStore.clearBusinessData();
    bumpDataVersion();
    out.ok = true;
    return out;
  }

  /**
   * 用备份文件恢复。
   * 备份属于账号数据，必须登录后整体推到服务端覆盖账号数据，再重新拉取。
   */
  async restoreBackup(payload: string): Promise<OpResult> {
    const out = new OpResult();
    if (this.denyGuest(out, '恢复备份')) {
      return out;
    }
    if (payload.length === 0) {
      out.message = '备份内容为空';
      return out;
    }
    let pack: BackupPackage;
    try {
      pack = JSON.parse(payload) as BackupPackage;
    } catch (e) {
      out.message = '备份内容无法解析';
      return out;
    }
    if (pack === null || pack === undefined || !Array.isArray(pack.records)) {
      out.message = '备份内容无法解析';
      return out;
    }
    if (typeof pack.version === 'number' && pack.version > 1) {
      out.message = '备份版本过高，请升级应用后再恢复';
      return out;
    }

    const body = new RestorePayload();
    body.records = pack.records;
    body.nickname = typeof pack.nickName === 'string' ? pack.nickName : carbonStore.nickName;
    body.monthGoal = typeof pack.monthGoal === 'number' ? pack.monthGoal : carbonStore.monthGoal;
    body.spentPoint = typeof pack.spentPoint === 'number' ? pack.spentPoint : 0;
    body.claims = this.buildClaims(pack.claimedTasks);
    body.badges = this.buildBadges(pack.exchanged);

    const resp = await supabase.rpc('replace_snapshot', JSON.stringify(new SnapshotArgs(auth.token, body)));
    if (!resp.ok) {
      out.message = this.msg(resp.message, '恢复失败，请检查网络');
      return out;
    }
    const pulled = await this.pull('恢复成功，但数据同步失败');
    bumpDataVersion();
    if (!pulled.ok) {
      out.message = pulled.message;
      out.point = -1;
      return out;
    }
    out.ok = true;
    out.point = pack.records.length;
    return out;
  }

  // ==================== 内部 ====================

  /** 拉取快照并落地本地 */
  private async pull(fallback: string): Promise<OpResult> {
    const out = new OpResult();
    const args = new TokenArgs(auth.token);
    const resp = await supabase.rpc('get_snapshot', JSON.stringify(args));
    if (!resp.ok) {
      if (resp.code === 'unauthorized') {
        // token 已失效（过期或被其他设备登出），回到未登录模板
        await auth.clearSession();
        await carbonStore.clearAll();
        out.message = '登录已失效，请重新登录';
        bumpDataVersion();
        return out;
      }
      out.message = this.msg(resp.message, fallback);
      return out;
    }
    const env = this.parseSnapshot(resp.raw);
    if (env === null) {
      out.message = '服务返回数据异常，请稍后重试';
      return out;
    }

    const user = normalizeUser(env.user);
    const meta = new AccountMeta();
    meta.spentPoint = user === null ? 0 : user.spentPoint;
    meta.nickName = user === null ? '低碳同学' : user.nickname;
    meta.monthGoal = user === null || user.monthGoal <= 0 ? 30 : user.monthGoal;

    // 本地只保留今天的任务 key，与原有语义保持一致（历史 key 的积分早已并入 spentPoint）
    const today = todayStr();
    const keys: string[] = [];
    const claims = Array.isArray(env.claims) ? env.claims : [];
    for (const c of claims) {
      const date = asText(c.claimDate, '');
      const taskId = asText(c.taskId, '');
      if (date === today && taskId.length > 0) {
        keys.push(`${date}#${taskId}`);
      }
    }
    meta.claimedTasks = keys;

    const exchanged: string[] = [];
    const badges = Array.isArray(env.badges) ? env.badges : [];
    for (const b of badges) {
      const kind = asText(b.kind, '');
      const id = asText(b.badgeId, '');
      if (kind === 'redeem' && id.length > 0) {
        exchanged.push(id);
      }
    }
    meta.exchanged = exchanged;

    const records = Array.isArray(env.records) ? env.records : [];
    await carbonStore.applyCloudSnapshot(records, meta);
    if (user !== null) {
      auth.updateUser(user);
    }
    bumpDataVersion();
    out.ok = true;
    return out;
  }

  private parseSnapshot(text: string): SnapshotEnvelope | null {
    if (text.length === 0) {
      return null;
    }
    try {
      const env = JSON.parse(text) as SnapshotEnvelope;
      if (env === null || env === undefined) {
        return null;
      }
      return env;
    } catch (e) {
      return null;
    }
  }

  private parseSpent(text: string): SpentEnvelope | null {
    if (text.length === 0) {
      return null;
    }
    try {
      const env = JSON.parse(text) as SpentEnvelope;
      if (env === null || env === undefined) {
        return null;
      }
      env.spentPoint = asNumber(env.spentPoint, carbonStore.meta.spentPoint);
      return env;
    } catch (e) {
      return null;
    }
  }

  /** 把备份里的任务 key 还原成带 reward 的领奖记录 */
  private buildClaims(keys: string[]): RestoreClaim[] {
    const list: RestoreClaim[] = [];
    if (!Array.isArray(keys)) {
      return list;
    }
    for (const key of keys) {
      if (typeof key !== 'string') {
        continue;
      }
      const parts = key.split('#');
      if (parts.length !== 2) {
        continue;
      }
      let reward = 0;
      for (const t of DAILY_TASKS) {
        if (t.id === parts[1]) {
          reward = t.reward;
          break;
        }
      }
      if (reward <= 0) {
        continue;
      }
      const c = new RestoreClaim();
      c.claimDate = parts[0];
      c.taskId = parts[1];
      c.reward = reward;
      list.push(c);
    }
    return list;
  }

  /** 把备份里的兑换勋章 id 还原成带 cost 的记录 */
  private buildBadges(ids: string[]): RestoreBadge[] {
    const list: RestoreBadge[] = [];
    if (!Array.isArray(ids)) {
      return list;
    }
    for (const id of ids) {
      if (typeof id !== 'string') {
        continue;
      }
      for (const b of REDEEM_BADGES) {
        if (b.id === id) {
          const item = new RestoreBadge();
          item.badgeId = id;
          item.cost = b.cost;
          list.push(item);
          break;
        }
      }
    }
    return list;
  }

  private msg(text: string, fallback: string): string {
    return asText(text, '').length > 0 ? text : fallback;
  }
}

export const cloudAccount = CloudAccount.getInstance();
