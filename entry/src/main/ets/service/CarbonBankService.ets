import { carbonStore } from '../viewmodel/CarbonStore';
import { storage } from './StorageService';
import { genId } from '../common/Utils';

/** 模拟接口的持久化 key */
const BANK_KEY = 'bank_json';

/** 碳积分与碳普惠积分的兑换比例（1:1，模拟平台规则） */
const EXCHANGE_RATE = 1;
/** 单次转入下限 / 上限，模拟平台风控规则 */
const TRANSFER_MIN = 10;
const TRANSFER_MAX = 5000;

/** 权益商品（城市碳普惠平台的合作权益） */
export class BankOffer {
  id: string;
  name: string;
  sponsor: string;
  icon: string;
  /** 所需碳普惠积分 */
  cost: number;
  /** 库存 */
  stock: number;
  desc: string;

  constructor(id: string, name: string, sponsor: string, icon: string, cost: number, stock: number, desc: string) {
    this.id = id;
    this.name = name;
    this.sponsor = sponsor;
    this.icon = icon;
    this.cost = cost;
    this.stock = stock;
    this.desc = desc;
  }
}

/** 权益目录（内置数据，等价于平台下发的商品列表） */
const BANK_OFFERS: BankOffer[] = [
  new BankOffer('metro', '地铁单程乘车券', '城市轨道交通集团', '🚇', 300, 30, '可在任一地铁站扫码进站，单程抵用'),
  new BankOffer('bike', '共享单车 30 天卡', '城市慢行交通联盟', '🚲', 400, 40, '30 天内每次骑行前 2 小时免费'),
  new BankOffer('coffee', '自带杯咖啡券', '低碳商户联盟', '☕', 200, 60, '到店自带杯可抵 15 元，减少一次性杯子'),
  new BankOffer('bag', '环保帆布袋', '再生材料工坊', '🛍️', 150, 80, '由回收 PET 瓶再生纤维制作'),
  new BankOffer('tree', '认养一棵公益树', '市绿化基金会', '🌳', 800, 100, '在城郊生态林认养一棵树，可查编号'),
  new BankOffer('book', '双碳科普图书', '城市图书馆', '📚', 600, 20, '《碳排放从哪里来》等科普读物一本')
];

/** 权益流水（正数为转入，负数为消费） */
export class BankOrder {
  id: string = '';
  /** in = 积分转入；out = 权益兑换 */
  type: string = 'in';
  /** 关联的权益 id，转入时为空 */
  offerId: string = '';
  title: string = '';
  icon: string = '🌿';
  /** 积分数（正数；消费时展示为负） */
  amount: number = 0;
  time: number = 0;
}

/** 模拟的碳普惠账户 */
export class BankAccount {
  /** 是否已开通 */
  bound: boolean = false;
  /** 所属城市 */
  city: string = '示例市';
  /** 平台账号（模拟） */
  accountNo: string = '';
  /** 碳普惠积分余额 */
  bankPoint: number = 0;
  /** 累计转入 */
  totalIn: number = 0;
  /** 累计消费 */
  totalOut: number = 0;
  /** 流水（新的在前） */
  orders: BankOrder[] = [];
}

/** 模拟接口的返回结构：code=0 表示成功 */
export class BankResult {
  code: number = 0;
  message: string = '';

  constructor(code: number, message: string) {
    this.code = code;
    this.message = message;
  }

  static ok(message: string): BankResult {
    return new BankResult(0, message);
  }

  static fail(code: number, message: string): BankResult {
    return new BankResult(code, message);
  }

  get success(): boolean {
    return this.code === 0;
  }
}

/**
 * 城市碳普惠平台接入服务（模拟）。
 *
 * 赛题要求"模拟城市碳普惠接口，实现积分互通与权益兑换"。真实平台需要企业与政府侧的
 * 接口授权，单机版应用不可能联通，因此这里用同一套请求/响应结构在端侧模拟：
 *   POST /api/v1/carbon/account/bind      开通碳普惠账户
 *   POST /api/v1/carbon/point/transfer    碳积分转入（1:1 兑换为碳普惠积分）
 *   POST /api/v1/carbon/offer/redeem      权益兑换
 * 请求参数校验、风控限额、库存扣减、流水落账、失败码返回都按真实接口的写法实现，
 * 唯一区别是数据来自内置目录与本机存储，不产生任何网络请求。
 */
export class CarbonBankService {
  private static instance: CarbonBankService | null = null;
  private acc: BankAccount = new BankAccount();
  private loadTask: Promise<void> | null = null;

  static getInstance(): CarbonBankService {
    if (CarbonBankService.instance === null) {
      CarbonBankService.instance = new CarbonBankService();
    }
    return CarbonBankService.instance;
  }

  /** 模拟网络往返，让加载态与真实接口一致 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 读取本地缓存的账户信息，重复调用只真正读一次 */
  ensureLoaded(): Promise<void> {
    if (this.loadTask === null) {
      this.loadTask = this.doLoad();
    }
    return this.loadTask;
  }

  private async doLoad(): Promise<void> {
    const raw = await storage.readString(BANK_KEY, '');
    const next = new BankAccount();
    if (raw.length > 0) {
      try {
        const src = JSON.parse(raw) as BankAccount;
        if (src !== null && src !== undefined) {
          next.bound = src.bound === true;
          next.city = typeof src.city === 'string' && src.city.length > 0 ? src.city : '示例市';
          next.accountNo = typeof src.accountNo === 'string' ? src.accountNo : '';
          next.bankPoint = CarbonBankService.num(src.bankPoint);
          next.totalIn = CarbonBankService.num(src.totalIn);
          next.totalOut = CarbonBankService.num(src.totalOut);
          next.orders = Array.isArray(src.orders) ? src.orders : [];
        }
      } catch (e) {
        // 缓存损坏时退回空账户，不影响主业务数据
      }
    }
    this.acc = next;
  }

  private static num(v: number): number {
    return typeof v === 'number' && isFinite(v) && v > 0 ? v : 0;
  }

  private async persist(): Promise<void> {
    await storage.writeString(BANK_KEY, JSON.stringify(this.acc));
  }

  get account(): BankAccount {
    return this.acc;
  }

  get bound(): boolean {
    return this.acc.bound;
  }

  /** 权益目录 + 剩余库存 */
  offers(): BankOffer[] {
    return BANK_OFFERS;
  }

  /** 某权益已兑换数量 */
  soldCount(offerId: string): number {
    let n = 0;
    for (const o of this.acc.orders) {
      if (o.type === 'out' && o.offerId === offerId) {
        n++;
      }
    }
    return n;
  }

  /** 某权益剩余库存 */
  remain(offer: BankOffer): number {
    const left = offer.stock - this.soldCount(offer.id);
    return left > 0 ? left : 0;
  }

  /** 最近流水 */
  recentOrders(limit: number): BankOrder[] {
    return this.acc.orders.slice(0, limit);
  }

  /** 开通碳普惠账户 */
  async bind(city: string): Promise<BankResult> {
    if (this.acc.bound) {
      return BankResult.fail(1001, '账户已开通，无需重复绑定');
    }
    const name = city.trim().length > 0 ? city.trim() : '示例市';
    await CarbonBankService.delay(700);
    const tail = `${Date.now()}`.slice(-8);
    this.acc.bound = true;
    this.acc.city = name;
    this.acc.accountNo = `CN88${tail}`;
    this.acc.bankPoint = 0;
    this.acc.totalIn = 0;
    this.acc.totalOut = 0;
    this.acc.orders = [];
    await this.persist();
    return BankResult.ok(`已开通${name}碳普惠账户`);
  }

  /**
   * 碳积分转入碳普惠账户（1:1）。
   * 先扣本应用的碳积分，再记账到平台侧，任一步失败都不留下半套数据。
   */
  async transferIn(amount: number): Promise<BankResult> {
    if (!this.acc.bound) {
      return BankResult.fail(1002, '请先开通碳普惠账户');
    }
    const n = Math.floor(amount);
    if (!(n > 0)) {
      return BankResult.fail(1003, '转入数量必须大于 0');
    }
    if (n < TRANSFER_MIN) {
      return BankResult.fail(1004, `单次至少转入 ${TRANSFER_MIN} 碳积分`);
    }
    if (n > TRANSFER_MAX) {
      return BankResult.fail(1005, `单次最多转入 ${TRANSFER_MAX} 碳积分`);
    }
    if (carbonStore.getSummary().totalPoint < n) {
      return BankResult.fail(1006, '碳积分余额不足');
    }
    await CarbonBankService.delay(500);
    const paid = await carbonStore.spendPoints(n);
    if (!paid) {
      return BankResult.fail(1007, '扣减碳积分失败，请重试');
    }
    const got = n * EXCHANGE_RATE;
    this.acc.bankPoint += got;
    this.acc.totalIn += got;
    const order = new BankOrder();
    order.id = genId('bo');
    order.type = 'in';
    order.offerId = '';
    order.title = `碳积分转入（1:${EXCHANGE_RATE}）`;
    order.icon = '🔄';
    order.amount = got;
    order.time = Date.now();
    this.acc.orders.unshift(order);
    await this.persist();
    return BankResult.ok(`已转入 ${got} 碳普惠积分`);
  }

  /** 兑换权益：校验库存与余额后扣分并记流水 */
  async redeemOffer(offerId: string): Promise<BankResult> {
    if (!this.acc.bound) {
      return BankResult.fail(1002, '请先开通碳普惠账户');
    }
    const hit = BANK_OFFERS.filter((o: BankOffer) => o.id === offerId);
    if (hit.length === 0) {
      return BankResult.fail(1008, '权益不存在或已下架');
    }
    const offer = hit[0];
    if (this.remain(offer) <= 0) {
      return BankResult.fail(1009, '该权益已被兑完');
    }
    if (this.acc.bankPoint < offer.cost) {
      return BankResult.fail(1010, '碳普惠积分不足');
    }
    await CarbonBankService.delay(600);
    this.acc.bankPoint -= offer.cost;
    this.acc.totalOut += offer.cost;
    const order = new BankOrder();
    order.id = genId('bo');
    order.type = 'out';
    order.offerId = offer.id;
    order.title = offer.name;
    order.icon = offer.icon;
    order.amount = offer.cost;
    order.time = Date.now();
    this.acc.orders.unshift(order);
    await this.persist();
    return BankResult.ok(`兑换成功：${offer.name}`);
  }
}

export const carbonBank = CarbonBankService.getInstance();
