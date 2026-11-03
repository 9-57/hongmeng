import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const STORE_NAME = 'carbon_store';
const PREF_KEY_RECORDS = 'records_json';
const PREF_KEY_META = 'meta_json';
const PREF_KEY_SESSION = 'session_token';
const PREF_KEY_CITY_BASE = 'city_base_url';
const PREF_KEY_CITY_TOKEN = 'city_token';
const PREF_KEY_CITY_ACCOUNT = 'city_account';
const PREF_KEY_FAMILY = 'family_json';

/**
 * 本地持久化服务：基于 preferences（轻量键值存储）。
 * 记录与账户元信息始终落地本地，未登录时完全离线可用；
 * 登录后由 CloudAccount 用云端快照覆盖本地，保证换设备后能拉回账号数据。
 */
export class StorageService {
  private static instance: StorageService | null = null;
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;

  static getInstance(): StorageService {
    if (StorageService.instance === null) {
      StorageService.instance = new StorageService();
    }
    return StorageService.instance;
  }

  /** 初始化，需在 UIAbility onCreate 中调用；重复调用只会真正初始化一次 */
  async init(context: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    const task = this.doInit(context);
    this.initPromise = task;
    try {
      await task;
    } finally {
      this.initPromise = null;
    }
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      hilog.info(0x0000, 'carbon', 'preferences ready');
    } catch (e) {
      hilog.error(0x0000, 'carbon', 'preferences init failed: %{public}s', JSON.stringify(e));
    }
  }

  get isReady(): boolean {
    return this.store !== null;
  }

  async readString(key: string, defValue: string): Promise<string> {
    if (this.store === null) {
      return defValue;
    }
    try {
      const v = await this.store.get(key, defValue);
      return typeof v === 'string' ? v as string : defValue;
    } catch (e) {
      hilog.warn(0x0000, 'carbon', 'read key %{public}s failed', key);
      return defValue;
    }
  }

  async writeString(key: string, value: string): Promise<void> {
    if (this.store === null) {
      hilog.error(0x0000, 'carbon', 'write skipped, preferences not ready');
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      hilog.error(0x0000, 'carbon', 'write failed: %{public}s', JSON.stringify(e));
    }
  }

  get recordsKey(): string {
    return PREF_KEY_RECORDS;
  }

  get metaKey(): string {
    return PREF_KEY_META;
  }

  /** 登录会话 token 的存储键（由 AuthService 使用） */
  get sessionKey(): string {
    return PREF_KEY_SESSION;
  }

  /** 城市碳普惠平台地址（可在 App 内修改） */
  get cityBaseKey(): string {
    return PREF_KEY_CITY_BASE;
  }

  /** 城市平台下发的账号 token（由 CityService 使用） */
  get cityTokenKey(): string {
    return PREF_KEY_CITY_TOKEN;
  }

  /** 城市账号缓存：编号 / 积分 / 绑定时间 */
  get cityAccountKey(): string {
    return PREF_KEY_CITY_ACCOUNT;
  }

  /** 家庭状态（成员 / 邀请码），与账户数据分开存 */
  get familyKey(): string {
    return PREF_KEY_FAMILY;
  }
}

export const storage = StorageService.getInstance();
