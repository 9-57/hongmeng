import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { asNumber, asText, supabase } from './SupabaseClient';
import { auth } from './AuthService';
import { storage } from './StorageService';
import { carbonStore } from '../viewmodel/CarbonStore';
import { bumpDataVersion, genId } from '../common/Utils';

const TAG = 'carbon-city';

/** 演示平台接口密钥（与后端 Api.java 保持一致，正式环境应改为服务端下发） */
export const CITY_API_KEY: string = 'carbon-city-demo-2026';
/** 默认平台地址：电脑后端启动后可在页面内改成实际局域网地址 */
export const CITY_DEFAULT_BASE: string = 'http://192.168.0.161:8080';

/** 城市账号本地缓存 */
export class CityAccountInfo {
  cityNo: string = '';
  cityPoints: number = 0;
  appPointsIn: number = 0;
  boundAt: string = '';
  rate: number = 10;
}

/** 城市权益（与平台 /rewards 返回一致） */
export class CityReward {
  id: string = '';
  name: string = '';
  desc: string = '';
  cost: number = 0;
  stock: number = 0;
  status: string = '';
  category: string = '';
  icon: string = '';
}

/** 兑换订单 */
export class CityOrder {
  orderNo: string = '';
  rewardId: string = '';
  rewardName: string = '';
  cost: number = 0;
  status: string = '';
  voucherCode: string = '';
  createdAt: string = '';
}

/** 积分互通流水 */
export class CityTxn {
  txnNo: string = '';
  requestId: string = '';
  appPoints: number = 0;
  cityPoints: number = 0;
  rate: number = 10;
  createdAt: string = '';
}

/** 一次城市平台调用的结果，UI 只需读 ok / message 与展示字段 */
export class CityResult {
  ok: boolean = false;
  duplicated: boolean = false;
  code: string = '';
  message: string = '';
  /** HTTP 状态码，0 表示请求未发出 */
  httpStatus: number = 0;
  /** 健康检查专用：平台是否可达 */
  online: boolean = false;
  cityNo: string = '';
  cityToken: string = '';
  cityPoints: number = 0;
  appPointsIn: number = 0;
  /** 本次转出的碳积分 */
  appPoint: number = 0;
  /** 本次新增的城市积分 */
  cityPoint: number = 0;
  spentPoint: number = 0;
  availablePoint: number = 0;
  orderNo: string = '';
  voucherCode: string = '';
  rewardName: string = '';
  cost: number = 0;
  rate: number = 10;
  boundAt: string = '';
  rewards: CityReward[] = [];
  orders: CityOrder[] = [];
  transactions: CityTxn[] = [];
}

/** 平台统一响应体 */
class CityEnvelope {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  duplicated: boolean = false;
  cityNo: string = '';
  cityToken: string = '';
  cityPoints: number = 0;
  appPointsIn: number = 0;
  appPoints: number = 0;
  cityPointsAdded: number = 0;
  appPoint: number = 0;
  cityPoint: number = 0;
  spentPoint: number = 0;
  availablePoint: number = 0;
  orderNo: string = '';
  voucherCode: string = '';
  rewardName: string = '';
  cost: number = 0;
  rate: number = 10;
  boundAt: string = '';
  requestId: string = '';
  txnNo: string = '';
  createdAt: string = '';
  rewards: CityReward[] = [];
  orders: CityOrder[] = [];
  transactions: CityTxn[] = [];
}

/** 本地保存的城市账号快照（含归属的碳足迹账号，防止换号串用） */
class CityCache {
  ownerId: string = '';
  cityNo: string = '';
  cityPoints: number = 0;
  appPointsIn: number = 0;
  boundAt: string = '';
  rate: number = 10;
}

class BindBody {
  appUserId: string;
  appUsername: string;

  constructor(appUserId: string, appUsername: string) {
    this.appUserId = appUserId;
    this.appUsername = appUsername;
  }
}

class TransferBody {
  requestId: string;
  amount: number;

  constructor(requestId: string, amount: number) {
    this.requestId = requestId;
    this.amount = amount;
  }
}

class RedeemBody {
  requestId: string;

  constructor(requestId: string) {
    this.requestId = requestId;
  }
}

class SupabaseTransferArgs {
  p_token: string;
  p_amount: number;
  p_request_id: string;
  p_city_no: string;

  constructor(token: string, amount: number, requestId: string, cityNo: string) {
    this.p_token = token;
    this.p_amount = amount;
    this.p_request_id = requestId;
    this.p_city_no = cityNo;
  }
}

class SupabaseRevertArgs {
  p_token: string;
  p_request_id: string;

  constructor(token: string, requestId: string) {
    this.p_token = token;
    this.p_request_id = requestId;
  }
}

/**
 * 城市碳普惠平台客户端。
 *
 * 积分转出的账目顺序：先在 Supabase 记账扣分，再调用平台加分；
 * 平台失败则调用 revert_city_transfer 把本地积分退回，保证两端不会长期不一致。
 * 同一个 requestId 在两端都是幂等的，网络重试不会重复扣分或重复加分。
 */
export class CityService {
  private static instance: CityService | null = null;

  private baseValue: string = CITY_DEFAULT_BASE;
  private tokenValue: string = '';
  private ownerValue: string = '';
  private accountValue: CityAccountInfo = new CityAccountInfo();
  private initialized: boolean = false;
  private initPromise: Promise<void> | null = null;

  static getInstance(): CityService {
    if (CityService.instance === null) {
      CityService.instance = new CityService();
    }
    return CityService.instance;
  }

  get baseUrl(): string {
    return this.baseValue;
  }

  get isBound(): boolean {
    return this.tokenValue.length > 0;
  }

  get account(): CityAccountInfo {
    return this.accountValue;
  }

  // ==================== 初始化 / 本地状态 ====================

  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    const task = this.doInit();
    this.initPromise = task;
    try {
      await task;
    } finally {
      this.initPromise = null;
    }
  }

  private async doInit(): Promise<void> {
    // preferences 未就绪时直接返回，下次调用再重试，避免把默认值当成已加载
    if (!storage.isReady) {
      return;
    }
    const savedBase = await storage.readString(storage.cityBaseKey, '');
    this.baseValue = savedBase.length > 0 ? savedBase : CITY_DEFAULT_BASE;
    this.tokenValue = await storage.readString(storage.cityTokenKey, '');
    this.ownerValue = '';
    this.accountValue = new CityAccountInfo();
    const raw = await storage.readString(storage.cityAccountKey, '');
    if (raw.length > 0) {
      try {
        const cache = JSON.parse(raw) as CityCache;
        if (cache !== null && cache !== undefined) {
          this.ownerValue = asText(cache.ownerId, '');
          this.accountValue.cityNo = asText(cache.cityNo, '');
          this.accountValue.cityPoints = asNumber(cache.cityPoints, 0);
          this.accountValue.appPointsIn = asNumber(cache.appPointsIn, 0);
          this.accountValue.boundAt = asText(cache.boundAt, '');
          this.accountValue.rate = asNumber(cache.rate, 10);
        }
      } catch (e) {
        hilog.warn(0x0000, TAG, 'city cache is not json');
      }
    }
    if (this.tokenValue.length === 0) {
      this.accountValue = new CityAccountInfo();
      this.ownerValue = '';
    }
    this.initialized = true;
  }

  /** 修改平台地址；地址变化会清掉旧绑定（旧 token 属于另一台服务） */
  async setBaseUrl(raw: string): Promise<CityResult> {
    const out = new CityResult();
    await this.init();
    let url = raw.trim();
    if (url.length === 0) {
      out.message = '请填写平台地址';
      return out;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = `http://${url}`;
    }
    let guard = 0;
    while (url.endsWith('/') && guard < 3) {
      url = url.substring(0, url.length - 1);
      guard += 1;
    }
    if (url.indexOf(' ') >= 0) {
      out.message = '地址不能包含空格';
      return out;
    }
    if (url.length <= 'http://'.length) {
      out.message = '地址格式不正确，例如 http://192.168.0.161:8080';
      return out;
    }
    if (url === this.baseValue) {
      out.ok = true;
      out.message = '平台地址未变化';
      return out;
    }
    const hadBinding = this.isBound;
    this.baseValue = url;
    await storage.writeString(storage.cityBaseKey, url);
    await this.clearBinding();
    out.ok = true;
    out.message = hadBinding ? '地址已保存，原城市账号已解绑' : '平台地址已保存';
    return out;
  }

  /** 清空本地绑定（不影响平台侧账号与积分） */
  async clearBinding(): Promise<void> {
    this.tokenValue = '';
    this.ownerValue = '';
    this.accountValue = new CityAccountInfo();
    if (storage.isReady) {
      await storage.writeString(storage.cityTokenKey, '');
      await storage.writeString(storage.cityAccountKey, '');
    }
  }

  /**
   * 校验绑定归属：换碳足迹账号后不能继续使用上一个账号的城市 token。
   * 返回 true 表示发生了清理。
   */
  async ensureOwner(userId: string): Promise<boolean> {
    await this.init();
    if (userId.length === 0 || this.ownerValue.length === 0) {
      return false;
    }
    if (this.ownerValue !== userId) {
      await this.clearBinding();
      return true;
    }
    return false;
  }

  // ==================== 平台接口 ====================

  /** 健康检查（不需要 API Key） */
  async health(): Promise<CityResult> {
    await this.init();
    const res = await this.call('GET', '/api/v1/health', '', false);
    res.online = res.ok;
    if (res.ok) {
      res.message = '平台在线';
    }
    return res;
  }

  /** 绑定城市账号：平台按 appUserId 幂等复用，重复绑定会拿回原账号 */
  async bind(appUserId: string, appUsername: string): Promise<CityResult> {
    await this.init();
    const out = new CityResult();
    if (appUserId.length === 0) {
      out.message = '请先登录碳足迹账号';
      return out;
    }
    const res = await this.call('POST', '/api/v1/auth/bind',
      JSON.stringify(new BindBody(appUserId, appUsername)), false);
    if (!res.ok) {
      return res;
    }
    if (res.cityToken.length === 0) {
      out.message = '平台未返回账号凭证，请重试';
      return out;
    }
    this.tokenValue = res.cityToken;
    this.ownerValue = appUserId;
    this.accountValue.cityNo = res.cityNo;
    this.accountValue.cityPoints = res.cityPoints;
    this.accountValue.appPointsIn = res.appPointsIn;
    this.accountValue.boundAt = res.boundAt;
    this.accountValue.rate = res.rate > 0 ? res.rate : 10;
    await storage.writeString(storage.cityTokenKey, this.tokenValue);
    await this.saveAccount();
    out.ok = true;
    out.cityNo = res.cityNo;
    out.cityPoints = res.cityPoints;
    out.appPointsIn = res.appPointsIn;
    out.boundAt = res.boundAt;
    out.rate = this.accountValue.rate;
    out.message = `已绑定城市碳普惠账号 ${res.cityNo}`;
    return out;
  }

  /** 刷新城市积分与累计转入 */
  async refresh(): Promise<CityResult> {
    await this.init();
    const out = new CityResult();
    if (!this.isBound) {
      out.message = '尚未绑定城市碳普惠账号';
      return out;
    }
    const res = await this.call('GET', '/api/v1/points/balance', '', true);
    if (res.ok) {
      this.accountValue.cityNo = res.cityNo.length > 0 ? res.cityNo : this.accountValue.cityNo;
      this.accountValue.cityPoints = res.cityPoints;
      this.accountValue.appPointsIn = res.appPointsIn;
      this.accountValue.boundAt = res.boundAt.length > 0 ? res.boundAt : this.accountValue.boundAt;
      this.accountValue.rate = res.rate > 0 ? res.rate : this.accountValue.rate;
      await this.saveAccount();
    }
    return res;
  }

  /**
   * 碳积分 → 城市积分。
   * 先扣本地（Supabase 记账），再调平台；平台失败会尝试对账，确认未入账后回滚本地。
   */
  async transfer(amount: number): Promise<CityResult> {
    await this.init();
    const out = new CityResult();
    if (!auth.isLoggedIn) {
      out.message = '请先登录碳足迹账号';
      return out;
    }
    if (!this.isBound) {
      out.message = '请先绑定城市碳普惠账号';
      return out;
    }
    if (!isFinite(amount) || amount <= 0 || amount % 10 !== 0) {
      out.message = '转出积分需为 10 的倍数';
      return out;
    }
    if (amount > 100000) {
      out.message = '单次转出不能超过 100000 碳积分';
      return out;
    }
    const available = carbonStore.getSummary().totalPoint;
    if (amount > available) {
      out.message = `可用碳积分不足（当前 ${available} 分）`;
      return out;
    }

    const requestId = genId('city');
    const args = new SupabaseTransferArgs(auth.token, amount, requestId, this.accountValue.cityNo);
    const local = await supabase.rpc('transfer_to_city', JSON.stringify(args));
    if (!local.httpOk) {
      out.code = local.code;
      out.message = local.message.length > 0 ? local.message : '本地积分记账失败，请检查网络';
      return out;
    }
    const localEnv = this.parseEnvelope(local.raw);
    if (!local.ok) {
      out.code = local.code;
      out.message = local.message.length > 0 ? local.message : '本地积分记账失败';
      out.availablePoint = asNumber(localEnv.availablePoint, available);
      return out;
    }
    // 本地已扣分：立刻落地，避免页面仍显示旧余额
    await carbonStore.applySpentPoint(asNumber(localEnv.spentPoint, carbonStore.meta.spentPoint));
    bumpDataVersion();

    const platform = await this.call('POST', '/api/v1/points/transfer',
      JSON.stringify(new TransferBody(requestId, amount)), true);
    if (!platform.ok) {
      // 平台超时/断网时可能其实已经入账，先查流水再决定是否回滚
      const recovered = await this.findTxn(requestId);
      if (recovered !== null) {
        out.ok = true;
        out.duplicated = true;
        out.appPoint = recovered.appPoints;
        out.cityPoint = recovered.cityPoints;
        out.message = '网络波动，平台已收到转出并自动对账完成';
        await this.refresh();
        out.cityPoints = this.accountValue.cityPoints;
        out.appPointsIn = this.accountValue.appPointsIn;
        out.rate = this.accountValue.rate;
        return out;
      }
      const rollback = await this.revertLocal(requestId);
      out.code = platform.code;
      out.message = `${platform.message}${rollback}`;
      out.availablePoint = carbonStore.getSummary().totalPoint;
      return out;
    }

    this.accountValue.cityPoints = platform.cityPoints;
    this.accountValue.appPointsIn = platform.appPointsIn;
    this.accountValue.rate = platform.rate > 0 ? platform.rate : this.accountValue.rate;
    await this.saveAccount();
    out.ok = true;
    out.duplicated = platform.duplicated;
    out.appPoint = amount;
    out.cityPoint = platform.cityPoint;
    out.cityPoints = platform.cityPoints;
    out.appPointsIn = platform.appPointsIn;
    out.spentPoint = asNumber(localEnv.spentPoint, carbonStore.meta.spentPoint);
    out.availablePoint = carbonStore.getSummary().totalPoint;
    out.rate = this.accountValue.rate;
    out.message = `已转出 ${amount} 碳积分，获得 ${platform.cityPoint} 城市积分`;
    return out;
  }

  /** 权益列表（只需 API Key，未绑定也能浏览） */
  async fetchRewards(): Promise<CityResult> {
    await this.init();
    const res = await this.call('GET', '/api/v1/rewards', '', false);
    if (res.ok && res.rate > 0) {
      this.accountValue.rate = res.rate;
    }
    return res;
  }

  /** 兑换权益：平台负责扣城市积分、减库存、出券码 */
  async redeem(rewardId: string): Promise<CityResult> {
    await this.init();
    const out = new CityResult();
    if (!this.isBound) {
      out.message = '请先绑定城市碳普惠账号';
      return out;
    }
    if (rewardId.length === 0) {
      out.message = '权益不存在';
      return out;
    }
    const requestId = genId('redeem');
    const res = await this.call('POST', `/api/v1/rewards/${rewardId}/redeem`,
      JSON.stringify(new RedeemBody(requestId)), true);
    if (res.ok) {
      this.accountValue.cityPoints = res.cityPoints;
      await this.saveAccount();
    }
    return res;
  }

  /** 本账号的兑换订单 */
  async fetchOrders(): Promise<CityResult> {
    await this.init();
    const out = new CityResult();
    if (!this.isBound) {
      out.message = '尚未绑定城市碳普惠账号';
      return out;
    }
    return await this.call('GET', '/api/v1/orders', '', true);
  }

  // ==================== 内部实现 ====================

  private async findTxn(requestId: string): Promise<CityTxn | null> {
    const res = await this.call('GET', '/api/v1/transactions', '', true);
    if (!res.ok) {
      return null;
    }
    for (const t of res.transactions) {
      if (t.requestId === requestId) {
        return t;
      }
    }
    return null;
  }

  /** 撤销 Supabase 侧流水并采用服务端返回的消费积分 */
  private async revertLocal(requestId: string): Promise<string> {
    const resp = await supabase.rpc('revert_city_transfer',
      JSON.stringify(new SupabaseRevertArgs(auth.token, requestId)));
    if (!resp.ok) {
      hilog.error(0x0000, TAG, 'revert transfer failed: %{public}s', resp.code);
      return '；本地积分回滚失败，请稍后重试或联系管理员';
    }
    const env = this.parseEnvelope(resp.raw);
    await carbonStore.applySpentPoint(asNumber(env.spentPoint, carbonStore.meta.spentPoint));
    bumpDataVersion();
    return '；已退回本地碳积分';
  }

  private async saveAccount(): Promise<void> {
    if (!storage.isReady) {
      return;
    }
    const cache = new CityCache();
    cache.ownerId = this.ownerValue;
    cache.cityNo = this.accountValue.cityNo;
    cache.cityPoints = this.accountValue.cityPoints;
    cache.appPointsIn = this.accountValue.appPointsIn;
    cache.boundAt = this.accountValue.boundAt;
    cache.rate = this.accountValue.rate;
    await storage.writeString(storage.cityAccountKey, JSON.stringify(cache));
  }

  /**
   * 统一的 HTTP 调用：平台所有接口都返回 { ok, code, message, ... }。
   * 401 表示城市 token 失效（例如演示数据被重置），此时自动清空本地绑定。
   */
  private async call(method: string, path: string, body: string,
    withToken: boolean): Promise<CityResult> {
    const out = new CityResult();
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'X-API-Key': CITY_API_KEY
      };
      if (withToken) {
        header['Authorization'] = `Bearer ${this.tokenValue}`;
      }
      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 12000
      };
      if (method === 'POST') {
        options.extraData = body;
      }
      const resp = await request.request(`${this.baseValue}${path}`, options);
      out.httpStatus = resp.responseCode;
      const text = typeof resp.result === 'string' ? resp.result as string : '';
      const env = this.parseEnvelope(text);
      this.fill(out, env);
      const httpOk = resp.responseCode >= 200 && resp.responseCode < 300;
      if (httpOk) {
        out.ok = env.ok;
        if (!env.ok && out.message.length === 0) {
          out.message = '平台处理失败';
        }
      } else {
        out.ok = false;
        out.code = env.code.length > 0 ? env.code : 'http_error';
        if (env.message.length > 0) {
          out.message = env.message;
        } else {
          out.message = `平台返回 HTTP ${resp.responseCode}`;
        }
      }
      if (resp.responseCode === 401 && withToken) {
        await this.clearBinding();
        out.ok = false;
        out.message = '城市账号已失效，请重新绑定';
      }
      return out;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'request %{public}s failed: %{public}s', path, JSON.stringify(e));
      out.ok = false;
      out.code = 'network';
      out.httpStatus = 0;
      out.message = `无法连接平台服务，请确认电脑已启动后端、手机与电脑在同一 Wi-Fi，并检查地址 ${this.baseValue}`;
      return out;
    } finally {
      request.destroy();
    }
  }

  private parseEnvelope(text: string): CityEnvelope {
    const env = new CityEnvelope();
    if (text.length === 0) {
      return env;
    }
    try {
      const parsed = JSON.parse(text) as CityEnvelope;
      if (parsed === null || parsed === undefined) {
        return env;
      }
      return parsed;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'response is not json');
      return env;
    }
  }

  /** 把平台/数据库响应归一成 UI 可直接使用的结构 */
  private fill(out: CityResult, env: CityEnvelope): void {
    out.duplicated = env.duplicated === true;
    out.code = asText(env.code, '');
    out.message = asText(env.message, '');
    out.cityNo = asText(env.cityNo, '');
    out.cityToken = asText(env.cityToken, '');
    out.cityPoints = asNumber(env.cityPoints, 0);
    out.appPointsIn = asNumber(env.appPointsIn, 0);
    out.appPoint = asNumber(env.appPoint, asNumber(env.appPoints, 0));
    const added = asNumber(env.cityPoint, 0);
    out.cityPoint = added > 0 ? added : asNumber(env.cityPointsAdded, 0);
    out.spentPoint = asNumber(env.spentPoint, 0);
    out.availablePoint = asNumber(env.availablePoint, 0);
    out.orderNo = asText(env.orderNo, '');
    out.voucherCode = asText(env.voucherCode, '');
    out.rewardName = asText(env.rewardName, '');
    out.cost = asNumber(env.cost, 0);
    out.rate = asNumber(env.rate, 10);
    out.boundAt = asText(env.boundAt, '');
    out.rewards = this.normalizeRewards(env.rewards);
    out.orders = this.normalizeOrders(env.orders);
    out.transactions = this.normalizeTxns(env.transactions);
  }

  private normalizeRewards(list: CityReward[]): CityReward[] {
    const out: CityReward[] = [];
    if (!Array.isArray(list)) {
      return out;
    }
    for (const raw of list) {
      const r = new CityReward();
      r.id = asText(raw.id, '');
      r.name = asText(raw.name, '权益');
      r.desc = asText(raw.desc, '');
      r.cost = asNumber(raw.cost, 0);
      r.stock = asNumber(raw.stock, 0);
      r.status = asText(raw.status, '');
      r.category = asText(raw.category, '');
      r.icon = asText(raw.icon, '🎁');
      out.push(r);
    }
    return out;
  }

  private normalizeOrders(list: CityOrder[]): CityOrder[] {
    const out: CityOrder[] = [];
    if (!Array.isArray(list)) {
      return out;
    }
    for (const raw of list) {
      const o = new CityOrder();
      o.orderNo = asText(raw.orderNo, '');
      o.rewardId = asText(raw.rewardId, '');
      o.rewardName = asText(raw.rewardName, '权益');
      o.cost = asNumber(raw.cost, 0);
      o.status = asText(raw.status, '');
      o.voucherCode = asText(raw.voucherCode, '');
      o.createdAt = asText(raw.createdAt, '');
      out.push(o);
    }
    return out;
  }

  private normalizeTxns(list: CityTxn[]): CityTxn[] {
    const out: CityTxn[] = [];
    if (!Array.isArray(list)) {
      return out;
    }
    for (const raw of list) {
      const t = new CityTxn();
      t.txnNo = asText(raw.txnNo, '');
      t.requestId = asText(raw.requestId, '');
      t.appPoints = asNumber(raw.appPoints, 0);
      t.cityPoints = asNumber(raw.cityPoints, 0);
      t.rate = asNumber(raw.rate, 10);
      t.createdAt = asText(raw.createdAt, '');
      out.push(t);
    }
    return out;
  }
}

export const cityService = CityService.getInstance();
