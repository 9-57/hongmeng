import {
  Activity, Article, Badge, CarbonRecord, Category, CategoryValue, CertificateInfo, CertificateIssue,
  DailyTask, DayValue, LevelInfo, MonthReview, Summary
} from '../model/CarbonModels';
import {
  ACHIEVEMENT_BADGES, ACTIVITIES, CATEGORIES, DAILY_TASKS, LEVEL_STEPS, LEVEL_TITLES, REDEEM_BADGES
} from '../model/CarbonData';
import { ARTICLES } from '../model/ArticleData';
import { storage } from '../service/StorageService';
import { auth } from '../service/AuthService';
import { familyService } from '../service/FamilyService';
import { buildInsights, Insight, InsightInput } from '../service/InsightService';
import {
  certSerial, csvCell, dateStart, dayStart, fmtKg, formatDate, formatDateTime, genId, monthKey, round, todayStr,
  weekLabel, weekStart
} from '../common/Utils';

/** 备份格式版本，恢复时拒绝比当前版本更新的文件 */
const BACKUP_VERSION = 1;

/** 参与兑换/成就计算的账户元信息 */
export class AccountMeta {
  /** 已兑换徽章 id 列表 */
  exchanged: string[] = [];
  /** 已消费积分（领取任务奖励时用负数抵消，净额 = 累计获得 - spentPoint） */
  spentPoint: number = 0;
  /** 已领取的每日任务 key：yyyy-MM-dd#taskId */
  claimedTasks: string[] = [];
  /** 昵称 */
  nickName: string = '低碳同学';
  /** 目标：每月减排目标 kg */
  monthGoal: number = 30;
  /** 已颁发证书（含编号与日期），与 exchanged 分开存，便于证书页展示 */
  certificates: CertificateIssue[] = [];
}

/** 备份数据包结构（用于本地备份与恢复） */
export class BackupPackage {
  version: number = BACKUP_VERSION;
  exportedAt: string = '';
  records: CarbonRecord[] = [];
  exchanged: string[] = [];
  claimedTasks: string[] = [];
  spentPoint: number = 0;
  nickName: string = '低碳同学';
  monthGoal: number = 30;
  certificates: CertificateIssue[] = [];
  /** 家庭状态（JSON），旧备份没有此字段时保持无家庭 */
  family: string = '';
}

/** 每日任务完成状态 */
export class TaskState {
  task: DailyTask;
  current: number = 0;
  done: boolean = false;
  claimed: boolean = false;

  constructor(task: DailyTask) {
    this.task = task;
  }
}

/** 徽章展示态 */
export class BadgeState {
  badge: Badge;
  unlocked: boolean = false;
  /** 进度 0~1 */
  progress: number = 0;
  /** 进度文字，如 3/10 */
  progressText: string = '';

  constructor(badge: Badge) {
    this.badge = badge;
  }
}

/**
 * 碳排放记录与积分的业务中心（全局单例）。
 * 所有页面通过 @StorageLink 引用 version 变量来触发刷新。
 *
 * 统计口径统一说明：一条记录的"业务日期"是它的 date 字段（yyyy-MM-dd），
 * 不是写入时间 time。今日/本周/本月/年度、筛选、复盘全部按 date 聚合，
 * 这样补记、导入备份、跨零点时不会出现"列表里有、统计里没有"的错位。
 */
export class CarbonStore {
  private static instance: CarbonStore | null = null;

  records: CarbonRecord[] = [];
  meta: AccountMeta = new AccountMeta();
  loaded: boolean = false;

  /** 初始化去重：多个页面同时调 load() 时只读一次存储 */
  private loadPromise: Promise<void> | null = null;
  /** 汇总缓存：记录/账户变更时失效，避免 MineTab 一次渲染算十遍全量记录 */
  private summaryCache: Summary | null = null;
  private summaryDay: string = '';
  /** 倒序列表缓存 */
  private sortedCache: CarbonRecord[] | null = null;
  /** 已见过（早已获得 / 已弹过）的荣誉 id：避免启动时把历史荣誉当成新获得 */
  private seenHonors: Set<string> = new Set<string>();
  private honorsPrimed: boolean = false;
  /** O(1) 索引，替代满数组 filter */
  private activityMap: Map<string, Activity> = new Map<string, Activity>();
  private categoryMap: Map<string, Category> = new Map<string, Category>();
  private taskMap: Map<string, DailyTask> = new Map<string, DailyTask>();
  private articleMap: Map<string, Article> = new Map<string, Article>();
  private redeemMap: Map<string, Badge> = new Map<string, Badge>();

  private constructor() {
    for (const a of ACTIVITIES) {
      this.activityMap.set(a.id, a);
    }
    for (const c of CATEGORIES) {
      this.categoryMap.set(c.id, c);
    }
    for (const t of DAILY_TASKS) {
      this.taskMap.set(t.id, t);
    }
    for (const a of ARTICLES) {
      this.articleMap.set(a.id, a);
    }
    for (const b of REDEEM_BADGES) {
      this.redeemMap.set(b.id, b);
    }
  }

  static getInstance(): CarbonStore {
    if (CarbonStore.instance === null) {
      CarbonStore.instance = new CarbonStore();
    }
    return CarbonStore.instance;
  }

  // ==================== 初始化 ====================

  async load(): Promise<void> {
    if (this.loaded) {
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
    // preferences 尚未初始化时读出来是空串。这里必须直接返回、不能把 loaded 置真，
    // 否则会把"空"当成"已加载"，之后真正的存储数据再也读不进来（重启丢数据）。
    if (!storage.isReady) {
      return;
    }
    await this.loadRecords();
    await this.loadMeta();
    this.loaded = true;
    this.invalidate();
  }

  /**
   * 确保数据已加载后再执行回调。
   * 页面首次挂载时存储可能还没读完（preferences 是异步的），
   * 各页面用此方法兜底，避免首屏显示空数据。
   */
  async ensureLoaded(callback: () => void): Promise<void> {
    if (!this.loaded) {
      try {
        await this.load();
      } catch (e) {
        // 读取失败也要回调，让页面显示空态而不是一直空白
      }
    }
    callback();
  }

  private async loadRecords(): Promise<void> {
    const raw = await storage.readString(storage.recordsKey, '');
    if (raw.length === 0) {
      this.records = [];
      return;
    }
    try {
      const arr = JSON.parse(raw) as CarbonRecord[];
      if (!Array.isArray(arr)) {
        this.records = [];
        return;
      }
      const list: CarbonRecord[] = [];
      for (const item of arr) {
        list.push(this.normalizeRecord(item));
      }
      this.records = list;
    } catch (e) {
      this.records = [];
    }
  }

  /** 把任意来源（旧版本存储 / 备份文件）的记录补齐成合法结构 */
  private normalizeRecord(item: CarbonRecord): CarbonRecord {
    const src: CarbonRecord = (item === null || item === undefined) ? new CarbonRecord() : item;
    const r = new CarbonRecord();
    const time = typeof src.time === 'number' && isFinite(src.time) && src.time > 0 ? src.time : Date.now();
    r.time = time;
    r.id = typeof src.id === 'string' && src.id.length > 0 ? src.id : genId('r');
    r.activityId = typeof src.activityId === 'string' ? src.activityId : '';
    r.activityName = typeof src.activityName === 'string' ? src.activityName : '';
    r.categoryId = typeof src.categoryId === 'string' ? src.categoryId : '';
    r.unit = typeof src.unit === 'string' ? src.unit : '';
    r.qty = typeof src.qty === 'number' && isFinite(src.qty) ? src.qty : 0;
    r.factor = typeof src.factor === 'number' && isFinite(src.factor) ? src.factor : 0;
    const hasReduction = typeof src.reduction === 'number' && isFinite(src.reduction);
    r.reduction = hasReduction ? src.reduction : 0;
    r.date = typeof src.date === 'string' && dateStart(src.date) > 0 ? src.date : formatDate(time);
    const act = this.activityMap.get(r.activityId);
    if (act !== undefined) {
      if (r.activityName.length === 0) {
        r.activityName = act.name;
      }
      if (r.categoryId.length === 0) {
        r.categoryId = act.categoryId;
      }
      if (r.unit.length === 0) {
        r.unit = act.unit;
      }
      if (r.factor === 0) {
        r.factor = act.factor;
      }
    }
    // 减排量缺失时，补齐因子后再算，避免旧备份里 factor 为空导致减排量恒为 0
    if (!hasReduction) {
      r.reduction = round(r.qty * r.factor, 3);
    }
    r.point = typeof src.point === 'number' && isFinite(src.point) ? src.point : this.calcPoint(r);
    r.note = typeof src.note === 'string' ? src.note : '';
    return r;
  }

  private calcPoint(r: CarbonRecord): number {
    const act = this.activityMap.get(r.activityId);
    const base = act === undefined ? 0 : act.basePoint;
    return Math.max(1, Math.round(base + r.reduction * 2));
  }

  private async loadMeta(): Promise<void> {
    const raw = await storage.readString(storage.metaKey, '');
    const next = new AccountMeta();
    if (raw.length > 0) {
      try {
        const m = JSON.parse(raw) as AccountMeta;
        if (m !== null && m !== undefined) {
          next.exchanged = Array.isArray(m.exchanged) ? m.exchanged : [];
          next.claimedTasks = Array.isArray(m.claimedTasks) ? m.claimedTasks : [];
          next.spentPoint = typeof m.spentPoint === 'number' && isFinite(m.spentPoint) ? m.spentPoint : 0;
          next.nickName = typeof m.nickName === 'string' && m.nickName.length > 0 ? m.nickName : '低碳同学';
          next.monthGoal = typeof m.monthGoal === 'number' && m.monthGoal > 0 ? m.monthGoal : 30;
          next.certificates = this.parseCertificates(m.certificates);
        }
      } catch (e) {
        // 损坏的元信息退回默认值，不影响记录本身
      }
    }
    this.meta = next;
    this.pruneClaimedTasks();
    this.ensureCertificateIssues();
  }

  /** 校验备份/旧版本里的证书数组，丢掉未知 id 与坏数据 */
  private parseCertificates(raw: CertificateIssue[]): CertificateIssue[] {
    const list: CertificateIssue[] = [];
    if (!Array.isArray(raw)) {
      return list;
    }
    for (const item of raw) {
      if (item === null || item === undefined) {
        continue;
      }
      const badgeId = typeof item.badgeId === 'string' ? item.badgeId : '';
      const badge = this.redeemMap.get(badgeId);
      if (badge === undefined || badge.type !== 'cert') {
        continue;
      }
      const serial = typeof item.serial === 'string' && item.serial.length > 0 ?
        item.serial : `CF-LEGACY-${badgeId}`;
      const issuedAt = typeof item.issuedAt === 'number' && isFinite(item.issuedAt) ? item.issuedAt : 0;
      list.push(new CertificateIssue(badgeId, serial, issuedAt));
    }
    return list;
  }

  /**
   * 兼容升级前只存了 exchanged 的老数据：已兑换的证书补一条颁发记录，
   * 日期标记为 0（界面显示"早期获得"），不会丢证书。
   */
  private ensureCertificateIssues(): void {
    for (const id of this.meta.exchanged) {
      const badge = this.redeemMap.get(id);
      if (badge === undefined || badge.type !== 'cert') {
        continue;
      }
      let found = false;
      for (const issue of this.meta.certificates) {
        if (issue.badgeId === id) {
          found = true;
          break;
        }
      }
      if (!found) {
        this.meta.certificates.push(new CertificateIssue(id, `CF-LEGACY-${id}`, 0));
      }
    }
  }


  private async persistRecords(): Promise<void> {
    await storage.writeString(storage.recordsKey, JSON.stringify(this.records));
  }

  private async persistMeta(): Promise<void> {
    await storage.writeString(storage.metaKey, JSON.stringify(this.meta));
  }

  /** 数据或账户发生变化后调用，丢弃派生缓存 */
  private invalidate(): void {
    this.summaryCache = null;
    this.sortedCache = null;
  }

  /**
   * 清理过期/损坏的任务领取 key。
   * 历史 key 对应的奖励早已计入积分，删 key 不会改变账目，只避免数组无限增长。
   */
  private pruneClaimedTasks(): void {
    const today = todayStr();
    const kept: string[] = [];
    let changed = false;
    for (const key of this.meta.claimedTasks) {
      if (typeof key !== 'string') {
        changed = true;
        continue;
      }
      const parts = key.split('#');
      if (parts.length !== 2 || parts[0] !== today || this.taskMap.get(parts[1]) === undefined) {
        changed = true;
        continue;
      }
      kept.push(key);
    }
    if (changed) {
      this.meta.claimedTasks = kept;
    }
  }

  // ==================== 查询基础设施 ====================

  getActivities(): Activity[] {
    return ACTIVITIES;
  }

  getActivityById(id: string): Activity | undefined {
    return this.activityMap.get(id);
  }

  getCategoryById(id: string): Category | undefined {
    return this.categoryMap.get(id);
  }

  activitiesOf(categoryId: string): Activity[] {
    return ACTIVITIES.filter((a: Activity) => a.categoryId === categoryId);
  }

  getArticleById(id: string): Article | undefined {
    return this.articleMap.get(id);
  }

  /** 行为图标：记录只存 activityId，展示时统一从这里取，避免各页面各写一份 filter */
  iconOf(activityId: string): string {
    const a = this.activityMap.get(activityId);
    return a === undefined ? '🍃' : a.icon;
  }

  // ==================== 记录增删 ====================

  /**
   * 构造一条记录（不落库）。
   * 云端写入要以"先 RPC 成功、再更新本地"的顺序进行，因此拆成构造与落地两步；
   * 这样网络失败时本地不会多出一条服务端并不存在的记录。
   */
  createRecord(activity: Activity, qty: number, dateStr: string, note: string): CarbonRecord {
    const r = new CarbonRecord();
    r.id = genId('r');
    r.activityId = activity.id;
    r.activityName = activity.name;
    r.categoryId = activity.categoryId;
    r.unit = activity.unit;
    r.qty = qty;
    r.factor = activity.factor;
    r.reduction = round(qty * activity.factor, 3);
    // 积分 = 基础分 + 减排量 × 2，向上取整，鼓励高减排行为
    r.point = Math.max(1, Math.round(activity.basePoint + r.reduction * 2));
    const now = Date.now();
    const today = todayStr();
    r.date = dateStart(dateStr) > 0 ? dateStr : today;
    // 业务日期与写入时间保持一致：补记历史日期时，把时分秒平移到那一天
    r.time = r.date === today ? now : dateStart(r.date) + (now - dayStart(now));
    r.note = note;
    return r;
  }

  /** 把已构造好的记录写入本地 */
  async appendRecord(r: CarbonRecord): Promise<void> {
    this.records.push(r);
    this.invalidate();
    await this.persistRecords();
  }

  /** 新增一条记录，返回获得的积分 */
  async addRecord(activity: Activity, qty: number, dateStr: string, note: string): Promise<number> {
    // 兜底：积分是账号资产，未登录不允许产生任何记录
    if (!auth.isLoggedIn) {
      return 0;
    }
    const r = this.createRecord(activity, qty, dateStr, note);
    await this.appendRecord(r);
    return r.point;
  }

  /**
   * 删除一条记录，返回因删除而被回滚的每日任务 key（yyyy-MM-dd#taskId）。
   * 调用方（CloudAccount）据此逐个通知服务端回滚领奖记录。
   */
  async deleteRecord(id: string): Promise<string[]> {
    this.records = this.records.filter((r: CarbonRecord) => r.id !== id);
    this.invalidate();
    // 已领取的任务若因删除记录而不再满足条件，回滚其奖励，保证积分账实一致
    const revoked = await this.revokeInvalidClaims();
    await this.persistRecords();
    return revoked;
  }

  /** 回收不再满足条件的每日任务奖励，返回被回收的 key */
  async revokeInvalidClaims(): Promise<string[]> {
    this.pruneClaimedTasks();
    const counts = this.todayCountByCategory();
    const keep: string[] = [];
    const revoked: string[] = [];
    let changed = false;
    for (const key of this.meta.claimedTasks) {
      const parts = key.split('#');
      if (parts.length !== 2) {
        changed = true;
        continue;
      }
      const task = this.taskMap.get(parts[1]);
      if (task === undefined) {
        changed = true;
        continue;
      }
      const c = counts.get(task.categoryId);
      const cur = c === undefined ? 0 : c;
      if (cur < task.target) {
        // 今日任务已不达标，退回奖励（领取时是 spentPoint -= reward，这里对称加回）
        this.meta.spentPoint += task.reward;
        revoked.push(key);
        changed = true;
        continue;
      }
      keep.push(key);
    }
    if (changed) {
      this.meta.claimedTasks = keep;
      this.invalidate();
      await this.persistMeta();
    }
    return revoked;
  }

  async clearAll(): Promise<void> {
    this.records = [];
    this.meta = new AccountMeta();
    this.invalidate();
    await this.persistRecords();
    await this.persistMeta();
    // 家庭属于账户数据，清空数据时一并重置
    await familyService.reset();
  }

  /** 清空业务数据但保留昵称与月目标（"清空数据"用） */
  async clearBusinessData(): Promise<void> {
    this.records = [];
    this.meta.exchanged = [];
    this.meta.claimedTasks = [];
    this.meta.spentPoint = 0;
    this.invalidate();
    await this.persistRecords();
    await this.persistMeta();
  }

  // ==================== 云端数据落地 ====================

  /** 用服务端快照整体替换本地数据（登录成功 / 启动校验 / 刷新时调用） */
  async applyCloudSnapshot(records: CarbonRecord[], meta: AccountMeta): Promise<void> {
    const seen = new Set<string>();
    const list: CarbonRecord[] = [];
    if (Array.isArray(records)) {
      for (const item of records) {
        const r = this.normalizeRecord(item);
        if (seen.has(r.id)) {
          r.id = genId('r');
        }
        seen.add(r.id);
        list.push(r);
      }
    }
    this.records = list;
    this.meta = meta;
    this.pruneClaimedTasks();
    this.invalidate();
    await this.persistRecords();
    await this.persistMeta();
  }

  /** 服务端领奖成功后落地本地：记录 key 并采用服务端返回的消费积分 */
  async applyClaim(taskId: string, spentPoint: number): Promise<void> {
    const key = this.taskKey(taskId);
    if (!this.meta.claimedTasks.includes(key)) {
      this.meta.claimedTasks.push(key);
    }
    this.meta.spentPoint = spentPoint;
    this.invalidate();
    await this.persistMeta();
  }

  /** 服务端兑换成功后落地本地 */
  async applyRedeem(badgeId: string, spentPoint: number): Promise<void> {
    if (!this.meta.exchanged.includes(badgeId)) {
      this.meta.exchanged.push(badgeId);
    }
    this.meta.spentPoint = spentPoint;
    // 云账号兑换走服务端扣分，这里补发证书记录，保证与本地兑换一致
    this.ensureCertificateIssues();
    this.invalidate();
    await this.persistMeta();
  }

  /** 服务端积分转出（城市碳普惠）成功后落地本地 */
  async applySpentPoint(spentPoint: number): Promise<void> {
    this.meta.spentPoint = spentPoint;
    this.invalidate();
    await this.persistMeta();
  }

  /** 服务端回滚领奖成功后落地本地：移除 key 并采用服务端返回的消费积分 */
  async applyRevokedClaims(keys: string[], spentPoint: number): Promise<void> {
    const rest: string[] = [];
    for (const key of this.meta.claimedTasks) {
      if (!keys.includes(key)) {
        rest.push(key);
      }
    }
    this.meta.claimedTasks = rest;
    this.meta.spentPoint = spentPoint;
    this.invalidate();
    await this.persistMeta();
  }

  /** 服务端保存资料成功后落地本地 */
  async applyProfile(nickName: string, monthGoal: number): Promise<void> {
    this.meta.nickName = nickName;
    this.meta.monthGoal = monthGoal;
    await this.persistMeta();
  }

  /** 按时间倒序（返回内部只读数组，调用方不要原地修改） */
  allRecordsDesc(): CarbonRecord[] {
    if (this.sortedCache === null) {
      const copy = this.records.slice();
      copy.sort((a: CarbonRecord, b: CarbonRecord) => b.time - a.time);
      this.sortedCache = copy;
    }
    return this.sortedCache;
  }

  /** 记录的业务日期 0 点时间戳 */
  private recordDay(r: CarbonRecord): number {
    const ts = dateStart(r.date);
    return ts > 0 ? ts : dayStart(r.time);
  }

  /** 历史记录筛选：范围 all/week/month + 分类 */
  filterRecords(range: string, categoryId: string): CarbonRecord[] {
    const now = Date.now();
    let from = 0;
    if (range === 'week') {
      from = weekStart(now);
    } else if (range === 'month') {
      const d = new Date(now);
      from = new Date(d.getFullYear(), d.getMonth(), 1).getTime();
    }
    return this.allRecordsDesc().filter((r: CarbonRecord) => {
      const okCat = categoryId === 'all' || r.categoryId === categoryId;
      const okTime = from === 0 || this.recordDay(r) >= from;
      return okCat && okTime;
    });
  }

  // ==================== 统计 ====================

  /** 基础汇总（积分已扣除消费，任务奖励以负 spentPoint 形式合并） */
  getSummary(): Summary {
    const today = todayStr();
    if (this.summaryCache !== null && this.summaryDay === today) {
      return this.summaryCache;
    }
    const s = new Summary();
    const now = Date.now();
    const todayStartTs = dayStart(now);
    const wStart = weekStart(now);
    const d = new Date(now);
    const mStart = new Date(d.getFullYear(), d.getMonth(), 1).getTime();

    let earned = 0;
    for (const r of this.records) {
      earned += r.point;
      const day = this.recordDay(r);
      s.totalReduction += r.reduction;
      if (day >= todayStartTs) {
        s.todayReduction += r.reduction;
        s.todayCount += 1;
      }
      if (day >= wStart) {
        s.weekReduction += r.reduction;
      }
      if (day >= mStart) {
        s.monthReduction += r.reduction;
      }
    }
    s.totalCount = this.records.length;
    s.totalReduction = round(s.totalReduction, 2);
    s.todayReduction = round(s.todayReduction, 2);
    s.weekReduction = round(s.weekReduction, 2);
    s.monthReduction = round(s.monthReduction, 2);
    s.totalPoint = Math.max(0, earned - this.meta.spentPoint);
    // 一棵成年树年均固碳约 18kg
    s.treeCount = round(s.totalReduction / 18, 2);
    s.streakDays = this.calcStreak();
    this.summaryCache = s;
    this.summaryDay = today;
    return s;
  }

  /** 连续记录天数（今天没记则从昨天往前算） */
  calcStreak(): number {
    if (this.records.length === 0) {
      return 0;
    }
    const days = new Set<string>();
    for (const r of this.records) {
      days.add(r.date);
    }
    let cursor = dayStart(Date.now());
    // 今天没记录，允许从昨天起算（当天还没来及记不算断）
    if (!days.has(formatDate(cursor))) {
      cursor = dayStart(cursor - 86400000);
      if (!days.has(formatDate(cursor))) {
        return 0;
      }
    }
    let count = 0;
    while (days.has(formatDate(cursor))) {
      count += 1;
      cursor = dayStart(cursor - 86400000);
    }
    return count;
  }

  /** 最近 n 天的逐日减排量（从旧到新） */
  dailySeries(days: number): DayValue[] {
    const map = new Map<string, number>();
    for (const r of this.records) {
      const old = map.get(r.date);
      map.set(r.date, (old === undefined ? 0 : old) + r.reduction);
    }
    const list: DayValue[] = [];
    const base = dayStart(Date.now());
    for (let i = days - 1; i >= 0; i--) {
      const ts = dayStart(base - i * 86400000);
      const key = formatDate(ts);
      const v = map.get(key);
      const label = i === 0 ? '今天' : `${new Date(ts).getMonth() + 1}/${new Date(ts).getDate()}`;
      list.push(new DayValue(label, round(v === undefined ? 0 : v, 2), key));
    }
    return list;
  }

  /**
   * 最近 n 天每天"记了几笔"（从旧到新）。
   * 与 dailySeries 的差别只在统计口径：这里数"记了几笔"，不看减排量，
   * 供碳账本首页的「记录节奏」点阵使用——账本讲坚持，看板讲减排量。
   */
  dailyCounts(days: number): DayValue[] {
    const map = new Map<string, number>();
    for (const r of this.records) {
      const old = map.get(r.date);
      map.set(r.date, (old === undefined ? 0 : old) + 1);
    }
    const list: DayValue[] = [];
    const base = dayStart(Date.now());
    for (let i = days - 1; i >= 0; i--) {
      const ts = dayStart(base - i * 86400000);
      const key = formatDate(ts);
      const v = map.get(key);
      list.push(new DayValue(i === 0 ? '今天' : weekLabel(ts), v === undefined ? 0 : v, key));
    }
    return list;
  }

  /** 近 n 周（周一为起点）的周减排量 */
  weeklySeries(weeks: number): DayValue[] {
    const list: DayValue[] = [];
    const thisWeek = weekStart(Date.now());
    for (let i = weeks - 1; i >= 0; i--) {
      // 用日期运算而不是减固定毫秒：跨夏令时的时间轴上，直接减 7*86400000 会偏移一小时
      const startDate = new Date(thisWeek);
      startDate.setDate(startDate.getDate() - i * 7);
      const start = startDate.getTime();
      const endDate = new Date(startDate);
      endDate.setDate(endDate.getDate() + 7);
      const end = endDate.getTime();
      let v = 0;
      for (const r of this.records) {
        const day = this.recordDay(r);
        if (day >= start && day < end) {
          v += r.reduction;
        }
      }
      const label = i === 0 ? '本周' : `${startDate.getMonth() + 1}/${startDate.getDate()}`;
      list.push(new DayValue(label, round(v, 2), formatDate(start)));
    }
    return list;
  }

  /** 近 n 个月的月减排量 */
  monthlySeries(months: number): DayValue[] {
    const list: DayValue[] = [];
    const now = new Date();
    for (let i = months - 1; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const start = d.getTime();
      const end = new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime();
      let v = 0;
      for (const r of this.records) {
        const day = this.recordDay(r);
        if (day >= start && day < end) {
          v += r.reduction;
        }
      }
      const label = i === 0 ? '本月' : `${d.getMonth() + 1}月`;
      list.push(new DayValue(label, round(v, 2), monthKey(start)));
    }
    return list;
  }

  /** 近 n 年（按年份聚合） */
  yearlySeries(years: number): DayValue[] {
    const list: DayValue[] = [];
    const nowYear = new Date().getFullYear();
    for (let i = years - 1; i >= 0; i--) {
      const y = nowYear - i;
      const start = new Date(y, 0, 1).getTime();
      const end = new Date(y + 1, 0, 1).getTime();
      let v = 0;
      for (const r of this.records) {
        const day = this.recordDay(r);
        if (day >= start && day < end) {
          v += r.reduction;
        }
      }
      list.push(new DayValue(i === 0 ? '今年' : `${y}年`, round(v, 2), `${y}`));
    }
    return list;
  }

  /** 按时间维度取序列 */
  seriesBy(dim: string): DayValue[] {
    if (dim === 'week') {
      return this.weeklySeries(8);
    }
    if (dim === 'month') {
      return this.monthlySeries(6);
    }
    if (dim === 'year') {
      return this.yearlySeries(3);
    }
    return this.dailySeries(7);
  }

  /** 分类聚合（按时间范围过滤） */
  categorySeries(range: string): CategoryValue[] {
    const now = Date.now();
    let from = 0;
    if (range === 'today') {
      from = dayStart(now);
    } else if (range === 'week') {
      from = weekStart(now);
    } else if (range === 'month') {
      const d = new Date(now);
      from = new Date(d.getFullYear(), d.getMonth(), 1).getTime();
    }
    const list: CategoryValue[] = CATEGORIES.map(
      (c: Category) => new CategoryValue(c.id, c.name, c.color, c.icon, 0, 0));
    const index = new Map<string, CategoryValue>();
    for (const cv of list) {
      index.set(cv.categoryId, cv);
    }
    for (const r of this.records) {
      if (from > 0 && this.recordDay(r) < from) {
        continue;
      }
      const hit = index.get(r.categoryId);
      if (hit !== undefined) {
        hit.value += r.reduction;
        hit.count += 1;
      }
    }
    // 占比按"展示值"（已四舍五入）重新求合计，否则 0.402 → 显示 0.40，
    // 再用 0.40/0.402 算占比会得到 99.5% 这种不闭环的百分比（真机踩过）。
    let shownTotal = 0;
    for (const cv of list) {
      cv.value = round(cv.value, 2);
      shownTotal += cv.value;
    }
    for (const cv of list) {
      cv.ratio = shownTotal > 0 ? cv.value / shownTotal : 0;
    }
    list.sort((a: CategoryValue, b: CategoryValue) => b.value - a.value);
    return list;
  }

  /** 类别覆盖数 */
  categoryCoverage(): number {
    const set = new Set<string>();
    for (const r of this.records) {
      set.add(r.categoryId);
    }
    return set.size;
  }

  /** 本月目标进度 0~1 */
  monthGoalProgress(): number {
    const s = this.getSummary();
    const goal = this.meta.monthGoal > 0 ? this.meta.monthGoal : 30;
    return Math.min(1, s.monthReduction / goal);
  }

  // ==================== 每日任务 ====================

  /** 今日各类别完成条数 */
  private todayCountByCategory(): Map<string, number> {
    const map = new Map<string, number>();
    const t = todayStr();
    for (const r of this.records) {
      if (r.date !== t) {
        continue;
      }
      const old = map.get(r.categoryId);
      map.set(r.categoryId, (old === undefined ? 0 : old) + 1);
    }
    return map;
  }

  private taskKey(taskId: string): string {
    return `${todayStr()}#${taskId}`;
  }

  getDailyTasks(): TaskState[] {
    const counts = this.todayCountByCategory();
    return DAILY_TASKS.map((t: DailyTask) => {
      const st = new TaskState(t);
      const c = counts.get(t.categoryId);
      st.current = c === undefined ? 0 : c;
      st.done = st.current >= t.target;
      st.claimed = this.meta.claimedTasks.includes(this.taskKey(t.id));
      return st;
    });
  }

  /** 领取任务积分 */
  async claimTask(taskId: string): Promise<number> {
    if (!auth.isLoggedIn) {
      return 0;
    }
    const task = this.taskMap.get(taskId);
    if (task === undefined) {
      return 0;
    }
    this.pruneClaimedTasks();
    const counts = this.todayCountByCategory();
    const c = counts.get(task.categoryId);
    const current = c === undefined ? 0 : c;
    if (current < task.target) {
      return 0;
    }
    const key = this.taskKey(taskId);
    if (this.meta.claimedTasks.includes(key)) {
      return 0;
    }
    this.meta.claimedTasks.push(key);
    // 任务奖励以"负消费"形式入账，与兑换消费共用同一本账
    this.meta.spentPoint -= task.reward;
    this.invalidate();
    await this.persistMeta();
    return task.reward;
  }

  // ==================== 徽章与证书 ====================

  getBadgeStates(): BadgeState[] {
    const s = this.getSummary();
    const list: BadgeState[] = [];
    for (const b of ACHIEVEMENT_BADGES) {
      const st = new BadgeState(b);
      let cur = 0;
      if (b.conditionType === 'record') {
        cur = s.totalCount;
      } else if (b.conditionType === 'reduction') {
        cur = s.totalReduction;
      } else if (b.conditionType === 'streak') {
        cur = s.streakDays;
      } else if (b.conditionType === 'category') {
        cur = this.categoryCoverage();
      } else if (b.conditionType === 'night') {
        cur = this.records.filter((r: CarbonRecord) => new Date(r.time).getHours() >= 22).length > 0 ? 1 : 0;
      }
      st.unlocked = cur >= b.conditionValue;
      st.progress = Math.min(1, b.conditionValue > 0 ? cur / b.conditionValue : 0);
      const curText = b.conditionType === 'reduction' ? `${round(cur, 1)}` : `${Math.floor(cur)}`;
      st.progressText = st.unlocked ? '已达成' : `${curText}/${b.conditionValue}`;
      list.push(st);
    }
    return list;
  }

  /** 当前已获得的荣誉：成就徽章按当前数据实时判定 + 已兑换的徽章 / 证书 / 奖状 */
  private earnedHonorStates(): BadgeState[] {
    const list: BadgeState[] = [];
    for (const st of this.getBadgeStates()) {
      if (st.unlocked) {
        list.push(st);
      }
    }
    for (const st of this.getRedeemStates()) {
      if (st.unlocked) {
        list.push(st);
      }
    }
    return list;
  }

  /** 载入 / 清空 / 恢复后调用：把当前已获得的荣誉记为"已见"，历史荣誉不再弹窗 */
  primeHonors(): void {
    this.seenHonors.clear();
    for (const st of this.earnedHonorStates()) {
      this.seenHonors.add(st.badge.id);
    }
    this.honorsPrimed = true;
  }

  /**
   * 取本次新获得的荣誉，取完即标记已见。
   * 第一次调用（还没 prime）先登记现状并返回空，避免首屏把历史荣誉全弹一遍。
   */
  takeNewHonors(): Badge[] {
    if (!this.honorsPrimed) {
      this.primeHonors();
      return [];
    }
    const out: Badge[] = [];
    for (const st of this.earnedHonorStates()) {
      if (this.seenHonors.has(st.badge.id)) {
        continue;
      }
      this.seenHonors.add(st.badge.id);
      out.push(st.badge);
    }
    return out;
  }

  /** 按 id 找徽章 / 证书 / 奖状（含未获得的），给荣誉放大弹层用 */
  badgeById(id: string): Badge | undefined {
    for (const b of ACHIEVEMENT_BADGES) {
      if (b.id === id) {
        return b;
      }
    }
    for (const b of REDEEM_BADGES) {
      if (b.id === id) {
        return b;
      }
    }
    return undefined;
  }

  getRedeemStates(): BadgeState[] {
    return REDEEM_BADGES.map((b: Badge) => {
      const st = new BadgeState(b);
      st.unlocked = this.meta.exchanged.includes(b.id);
      st.progressText = st.unlocked ? '已获得' : `${b.cost} 积分`;
      return st;
    });
  }

  /** 兑换徽章，成功返回 true */
  /** 兑换徽章/证书，成功返回 true；证书会同时生成编号与颁发时间 */
  async redeem(badgeId: string): Promise<boolean> {
    if (!auth.isLoggedIn) {
      return false;
    }
    const badge = this.redeemMap.get(badgeId);
    if (badge === undefined) {
      return false;
    }
    if (this.meta.exchanged.includes(badgeId)) {
      return false;
    }
    if (this.getSummary().totalPoint < badge.cost) {
      return false;
    }
    this.meta.exchanged.push(badgeId);
    if (badge.type === 'cert') {
      const issue = new CertificateIssue(badgeId, certSerial(), Date.now());
      this.meta.certificates.push(issue);
    }
    this.meta.spentPoint += badge.cost;
    this.invalidate();
    await this.persistMeta();
    return true;
  }


  /** 已获得的可兑换勋章 */
  exchangedBadges(): Badge[] {
    return REDEEM_BADGES.filter((b: Badge) => this.meta.exchanged.includes(b.id));
  }

  /**
   * 通用积分消费（供积分互通等外部兑换使用）。
   * 与徽章兑换共用同一本支出账 spentPoint，保证余额恒等于"累计获得 - 累计消费"，
   * 不会出现两套账各扣一次、或外部消费不计入余额的问题。
   */
  async spendPoints(amount: number): Promise<boolean> {
    const n = Math.floor(amount);
    if (!(n > 0)) {
      return false;
    }
    if (this.getSummary().totalPoint < n) {
      return false;
    }
    this.meta.spentPoint += n;
    this.invalidate();
    await this.persistMeta();
    return true;
  }

  /** 已获得的证书，按颁发时间倒序（新证书在前） */
  certificates(): CertificateInfo[] {
    const list: CertificateInfo[] = [];
    for (const issue of this.meta.certificates) {
      const badge = this.redeemMap.get(issue.badgeId);
      if (badge !== undefined && badge.type === 'cert') {
        list.push(new CertificateInfo(badge, issue.serial, issue.issuedAt));
      }
    }
    list.sort((a: CertificateInfo, b: CertificateInfo) => b.issuedAt - a.issuedAt);
    return list;
  }

  /** 按证书 id 取颁发信息，没兑换过返回 null */
  certificateOf(badgeId: string): CertificateInfo | null {
    for (const issue of this.meta.certificates) {
      if (issue.badgeId === badgeId) {
        const badge = this.redeemMap.get(badgeId);
        if (badge !== undefined && badge.type === 'cert') {
          return new CertificateInfo(badge, issue.serial, issue.issuedAt);
        }
      }
    }
    return null;
  }

  // ==================== 智能服务：推荐 / 建议 / 分享 ====================

  /** 组装推荐引擎输入（一趟记录扫描 + 汇总缓存） */
  insightInput(): InsightInput {
    const input = new InsightInput();
    const s = this.getSummary();
    input.totalCount = s.totalCount;
    input.todayCount = s.todayCount;
    input.streakDays = s.streakDays;
    input.totalReduction = s.totalReduction;
    input.monthReduction = s.monthReduction;
    input.monthGoal = this.meta.monthGoal > 0 ? this.meta.monthGoal : 30;
    input.monthActiveDays = this.monthReview(0).activeDays;
    input.totalPoint = s.totalPoint;
    input.certCount = this.meta.certificates.length;
    for (const c of CATEGORIES) {
      input.categoryCounts.set(c.id, 0);
      input.categoryValues.set(c.id, 0);
    }
    for (const r of this.records) {
      const n = input.categoryCounts.get(r.categoryId);
      input.categoryCounts.set(r.categoryId, (n === undefined ? 0 : n) + 1);
      const v = input.categoryValues.get(r.categoryId);
      input.categoryValues.set(r.categoryId, (v === undefined ? 0 : v) + r.reduction);
    }
    return input;
  }

  /** 个性化任务与生活建议（1~3 条，纯函数生成） */
  insights(): Insight[] {
    return buildInsights(this.insightInput());
  }

  /** 社交分享文案：可直接粘贴到微信/QQ/微博 */
  buildShareText(): string {
    const s = this.getSummary();
    const lv = this.levelInfo();
    const certCount = this.certificates().length;
    const lines: string[] = [
      `🌱 ${this.meta.nickName} 的低碳成绩单`,
      `累计减排 ${fmtKg(s.totalReduction)} kgCO2e，约等于 ${fmtKg(s.treeCount)} 棵树一年的固碳量`,
      `连续打卡 ${s.streakDays} 天 · ${s.totalCount} 条低碳记录 · ${s.totalPoint} 碳积分`,
      `等级 ${lv.code} ${lv.title}${certCount > 0 ? ` · ${certCount} 张低碳证书` : ''}`,
      `本月减排 ${fmtKg(s.monthReduction)} kg（目标 ${this.meta.monthGoal} kg）`,
      '今天也少开一次车，多走一段路 🌍',
      '#碳足迹 #全民绿色生活'
    ];
    return lines.join('\n');
  }


  // ==================== 账户设置 ====================

  get nickName(): string {
    return this.meta.nickName;
  }

  async setNickName(name: string): Promise<void> {
    this.meta.nickName = name;
    await this.persistMeta();
  }

  get monthGoal(): number {
    return this.meta.monthGoal;
  }

  async setMonthGoal(goal: number): Promise<void> {
    this.meta.monthGoal = Math.max(1, Math.round(goal));
    await this.persistMeta();
  }

  /** 等级信息：阈值表来自数据层，UI 不再各自维护一份 */
  levelInfo(): LevelInfo {
    const total = this.getSummary().totalReduction;
    const info = new LevelInfo();
    let idx = 0;
    for (let i = 0; i < LEVEL_STEPS.length; i++) {
      if (total >= LEVEL_STEPS[i]) {
        idx = i;
      }
    }
    info.code = `Lv.${idx + 1}`;
    info.title = idx < LEVEL_TITLES.length ? LEVEL_TITLES[idx] : '';
    info.total = total;
    info.isMax = idx >= LEVEL_STEPS.length - 1;
    if (info.isMax) {
      info.progress = 1;
      info.nextNeed = 0;
    } else {
      const base = LEVEL_STEPS[idx];
      const next = LEVEL_STEPS[idx + 1];
      info.progress = Math.min(1, (total - base) / (next - base));
      info.nextNeed = round(next - total, 1);
    }
    return info;
  }

  // ==================== 导出报表 ====================

  /** 生成 CSV 格式的统计报表文本（用于导出留存） */
  buildCsvReport(): string {
    const lines: string[] = [];
    lines.push('日期,时间,行为,类别,数量,单位,减排量(kgCO2e),积分,备注');
    const catName = (id: string): string => {
      const c = this.getCategoryById(id);
      return c === undefined ? id : c.name;
    };
    for (const r of this.allRecordsDesc()) {
      const cells: string[] = [
        csvCell(r.date), csvCell(formatDateTime(r.time)), csvCell(r.activityName), csvCell(catName(r.categoryId)),
        `${r.qty}`, csvCell(r.unit), `${r.reduction}`, `${r.point}`, csvCell(r.note)
      ];
      lines.push(cells.join(','));
    }
    const s = this.getSummary();
    lines.push('');
    lines.push(`合计减排(kgCO2e),${s.totalReduction}`);
    lines.push(`合计记录(条),${s.totalCount}`);
    lines.push(`当前积分,${s.totalPoint}`);
    lines.push(`连续打卡(天),${s.streakDays}`);
    return lines.join('\n');
  }

  /** 导出为可读的文本摘要（用于分享/存档） */
  buildTextReport(): string {
    const s = this.getSummary();
    const lv = this.levelInfo();
    return [
      '【我的低碳碳账本】',
      `昵称：${this.meta.nickName}`,
      `等级：${lv.code} ${lv.title}`,
      `累计减排：${s.totalReduction} kgCO2e`,
      `本月减排：${s.monthReduction} kgCO2e（目标 ${this.meta.monthGoal} kg）`,
      `本周减排：${s.weekReduction} kgCO2e`,
      `今日减排：${s.todayReduction} kgCO2e`,
      `累计记录：${s.totalCount} 条`,
      `连续打卡：${s.streakDays} 天`,
      `当前碳积分：${s.totalPoint}`,
      `等效植树：${s.treeCount} 棵·年`,
      `生成时间：${formatDateTime(Date.now())}`
    ].join('\n');
  }

  // ==================== 备份与恢复 ====================

  /** 封装：给 UI 层用的备份数据包结构 */
  buildBackupPayload(): string {
    const pack = new BackupPackage();
    pack.version = BACKUP_VERSION;
    pack.exportedAt = formatDateTime(Date.now());
    pack.records = this.records.slice();
    pack.exchanged = this.meta.exchanged.slice();
    pack.claimedTasks = this.meta.claimedTasks.slice();
    pack.spentPoint = this.meta.spentPoint;
    pack.nickName = this.meta.nickName;
    pack.monthGoal = this.meta.monthGoal;
    pack.certificates = this.meta.certificates.slice();
    pack.family = familyService.exportState();
    return JSON.stringify(pack);
  }

  /** 从备份数据恢复，成功返回恢复的记录条数，失败返回 -1 */
  async restoreFromPayload(payload: string): Promise<number> {
    if (payload.length === 0) {
      return -1;
    }
    try {
      const pack = JSON.parse(payload) as BackupPackage;
      if (pack === null || pack === undefined || !Array.isArray(pack.records)) {
        return -1;
      }
      if (typeof pack.version === 'number' && pack.version > BACKUP_VERSION) {
        // 旧版本无法解析新格式，明确失败而不是恢复出半套数据
        return -1;
      }
      const seen = new Set<string>();
      const next: CarbonRecord[] = [];
      for (const item of pack.records) {
        const r = this.normalizeRecord(item);
        if (seen.has(r.id)) {
          r.id = genId('r');
        }
        seen.add(r.id);
        next.push(r);
      }
      const meta = new AccountMeta();
      meta.exchanged = Array.isArray(pack.exchanged) ? pack.exchanged : [];
      meta.claimedTasks = Array.isArray(pack.claimedTasks) ? pack.claimedTasks : [];
      meta.spentPoint = typeof pack.spentPoint === 'number' && isFinite(pack.spentPoint) ? pack.spentPoint : 0;
      meta.nickName = typeof pack.nickName === 'string' && pack.nickName.length > 0 ? pack.nickName : '低碳同学';
      meta.monthGoal = typeof pack.monthGoal === 'number' && pack.monthGoal > 0 ? pack.monthGoal : 30;
      meta.certificates = this.parseCertificates(pack.certificates);
      this.records = next;
      this.meta = meta;
      this.pruneClaimedTasks();
      this.ensureCertificateIssues();
      this.invalidate();
      await this.persistRecords();
      await this.persistMeta();
      if (typeof pack.family === 'string' && pack.family.length > 0) {
        await familyService.importState(pack.family);
      } else {
        await familyService.reset();
      }
      return next.length;
    } catch (e) {
      return -1;
    }
  }

  // ==================== 月度复盘 ====================

  /**
   * 月度复盘：一趟遍历同时算出本月/上月减排、活跃天数、最佳分类与最佳记录。
   * 原实现由页面分别调 monthReduction/monthActiveDays/bestCategory/bestRecord，
   * 四个方法各扫一遍全量记录，MineTab 一次渲染要扫十几遍。
   */
  monthReview(monthOffset: number): MonthReview {
    const now = new Date();
    const start = new Date(now.getFullYear(), now.getMonth() + monthOffset, 1).getTime();
    const end = new Date(now.getFullYear(), now.getMonth() + monthOffset + 1, 1).getTime();
    const prevStart = new Date(now.getFullYear(), now.getMonth() + monthOffset - 1, 1).getTime();

    const review = new MonthReview();
    const days = new Set<string>();
    const catMap = new Map<string, number>();
    let best: CarbonRecord | null = null;
    let prevTotal = 0;

    for (const r of this.records) {
      const day = this.recordDay(r);
      if (day >= start && day < end) {
        review.reduction += r.reduction;
        review.recordCount += 1;
        days.add(r.date);
        const old = catMap.get(r.categoryId);
        catMap.set(r.categoryId, (old === undefined ? 0 : old) + r.reduction);
        if (best === null || r.reduction > best.reduction) {
          best = r;
        }
      } else if (day >= prevStart && day < start) {
        prevTotal += r.reduction;
      }
    }

    review.reduction = round(review.reduction, 2);
    review.lastReduction = round(prevTotal, 2);
    review.activeDays = days.size;
    review.hasPrev = review.lastReduction > 0;
    review.changeRate = review.hasPrev ?
      round((review.reduction - review.lastReduction) / review.lastReduction, 3) : 0;

    let bestId = '';
    let bestVal = 0;
    catMap.forEach((v: number, k: string) => {
      if (v > bestVal) {
        bestVal = v;
        bestId = k;
      }
    });
    if (bestId.length > 0) {
      const c = this.getCategoryById(bestId);
      if (c !== undefined) {
        review.bestCategoryName = c.name;
        review.bestCategoryDesc = c.desc;
        review.bestCategoryIcon = c.icon;
      }
    }
    const top: CarbonRecord | null = best;
    if (top !== null) {
      review.bestRecordName = top.activityName;
      review.bestRecordValue = top.reduction;
      review.hasBestRecord = true;
    }
    return review;
  }
}

export const carbonStore = CarbonStore.getInstance();
