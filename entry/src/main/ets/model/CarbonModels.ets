/**
 * 基础数据类型定义
 * 说明：所有类均保持无方法（纯数据），便于 JSON 序列化与反序列化。
 */

/** 行为大类 */
export class Category {
  id: string = '';
  /** 名称 */
  name: string = '';
  /** 图标（emoji，保证离线可用） */
  icon: string = '';
  /** 主题色 */
  color: string = '';
  /** 一句话说明 */
  desc: string = '';

  constructor(id: string, name: string, icon: string, color: string, desc: string) {
    this.id = id;
    this.name = name;
    this.icon = icon;
    this.color = color;
    this.desc = desc;
  }
}

/** 具体低碳行为（内置碳排放因子） */
export class Activity {
  id: string = '';
  /** 所属大类 */
  categoryId: string = '';
  name: string = '';
  icon: string = '';
  /** 计量单位，如 km / 次 / 度 */
  unit: string = '';
  /** 单位减排量，单位 kgCO2e */
  factor: number = 0;
  /** 每次记账基础积分 */
  basePoint: number = 0;
  /** 因子来源说明 */
  factorFrom: string = '';
  /** 该行为的推荐使用场景提示 */
  hint: string = '';
  /** 默认数量 */
  defaultQty: number = 1;
  /** 数量步长 */
  step: number = 1;
  /** 数量上限 */
  maxQty: number = 100;

  constructor(id: string, categoryId: string, name: string, icon: string, unit: string, factor: number,
    basePoint: number, factorFrom: string, hint: string, defaultQty: number, step: number, maxQty: number) {
    this.id = id;
    this.categoryId = categoryId;
    this.name = name;
    this.icon = icon;
    this.unit = unit;
    this.factor = factor;
    this.basePoint = basePoint;
    this.factorFrom = factorFrom;
    this.hint = hint;
    this.defaultQty = defaultQty;
    this.step = step;
    this.maxQty = maxQty;
  }
}

/** 一条低碳行为记录 */
export class CarbonRecord {
  id: string = '';
  /** 行为 id */
  activityId: string = '';
  activityName: string = '';
  categoryId: string = '';
  unit: string = '';
  /** 数量 */
  qty: number = 0;
  /** 单位减排因子 */
  factor: number = 0;
  /** 减排量 kgCO2e */
  reduction: number = 0;
  /** 获得积分 */
  point: number = 0;
  /** 发生日期 yyyy-MM-dd */
  date: string = '';
  /** 记录时间戳（毫秒） */
  time: number = 0;
  /** 备注 */
  note: string = '';
}

/** 徽章 / 证书 */
export class Badge {
  id: string = '';
  name: string = '';
  icon: string = '';
  /** 徽章说明 */
  desc: string = '';
  /** 兑换所需积分，0 表示成就型（不可兑换，靠累计自动达成） */
  cost: number = 0;
  /** 类型：achievement 成就徽章 / cert 证书 */
  type: string = 'achievement';
  /** 达成条件说明 */
  conditionText: string = '';
  /** 条件类型 */
  conditionType: string = '';
  /** 条件阈值 */
  conditionValue: number = 0;

  constructor(id: string, name: string, icon: string, desc: string, cost: number, type: string,
    conditionText: string, conditionType: string, conditionValue: number) {
    this.id = id;
    this.name = name;
    this.icon = icon;
    this.desc = desc;
    this.cost = cost;
    this.type = type;
    this.conditionText = conditionText;
    this.conditionType = conditionType;
    this.conditionValue = conditionValue;
  }
}

/** 每日低碳任务 */
export class DailyTask {
  id: string = '';
  name: string = '';
  icon: string = '';
  /** 奖励积分 */
  reward: number = 0;
  /** 完成条件：关联的 categoryId，记录一条该类行为即完成 */
  categoryId: string = '';
  /** 目标数量 */
  target: number = 0;
  desc: string = '';

  constructor(id: string, name: string, icon: string, reward: number, categoryId: string, target: number,
    desc: string) {
    this.id = id;
    this.name = name;
    this.icon = icon;
    this.reward = reward;
    this.categoryId = categoryId;
    this.target = target;
    this.desc = desc;
  }
}

/** 科普文章 */
export class Article {
  id: string = '';
  title: string = '';
  /** 栏目：政策 / 知识 / 技巧 */
  section: string = '';
  /** 摘要 */
  summary: string = '';
  /** 标签 */
  tags: string[] = [];
  /** 正文段落 */
  paragraphs: string[] = [];
  /** 关键数据/要点 */
  keyPoints: string[] = [];
  /** 阅读时长（分钟） */
  readMinutes: number = 0;
  /** 顶部图标 */
  icon: string = '';

  constructor(id: string, title: string, section: string, summary: string, tags: string[], paragraphs: string[],
    keyPoints: string[], readMinutes: number, icon: string) {
    this.id = id;
    this.title = title;
    this.section = section;
    this.summary = summary;
    this.tags = tags;
    this.paragraphs = paragraphs;
    this.keyPoints = keyPoints;
    this.readMinutes = readMinutes;
    this.icon = icon;
  }
}

/** 汇总统计结果 */
export class Summary {
  totalReduction: number = 0;
  todayReduction: number = 0;
  weekReduction: number = 0;
  monthReduction: number = 0;
  totalPoint: number = 0;
  totalCount: number = 0;
  todayCount: number = 0;
  /** 连续打卡天数 */
  streakDays: number = 0;
  /** 等效种树棵数 */
  treeCount: number = 0;
}

/** 某一天的聚合值（用于折线图） */
export class DayValue {
  label: string = '';
  value: number = 0;
  /** 对应日期 yyyy-MM-dd */
  date: string = '';

  constructor(label: string, value: number, date: string) {
    this.label = label;
    this.value = value;
    this.date = date;
  }
}

/** 等级信息（避免用 string[] 的下标约定传递，曾出现下标错位难排查） */
export class LevelInfo {
  /** 如 Lv.3 */
  code: string = 'Lv.1';
  /** 等级称号 */
  title: string = '';
  /** 当前累计减排量 kg */
  total: number = 0;
  /** 距下一级还需 kg（最高级为 0） */
  nextNeed: number = 0;
  /** 当前等级内进度 0~1 */
  progress: number = 0;
  /** 是否已达最高级 */
  isMax: boolean = false;
}

/** 月度复盘的一次性聚合结果（一趟遍历算完，避免页面里反复扫全量记录） */
export class MonthReview {
  /** 本月减排量 kg */
  reduction: number = 0;
  /** 上月减排量 kg */
  lastReduction: number = 0;
  /** 本月有记录的天数 */
  activeDays: number = 0;
  /** 本月记录条数 */
  recordCount: number = 0;
  /** 环比变化率（-1 ~ +∞），上月无数据时无意义 */
  changeRate: number = 0;
  /** 上月是否有可比较的数据 */
  hasPrev: boolean = false;
  /** 贡献最大的分类 */
  bestCategoryName: string = '';
  bestCategoryDesc: string = '';
  bestCategoryIcon: string = '';
  /** 单次减排最高的记录 */
  bestRecordName: string = '';
  bestRecordValue: number = 0;
  hasBestRecord: boolean = false;
}

/** 某个分类的聚合值（用于柱状图/环形图） */
export class CategoryValue {
  categoryId: string = '';
  name: string = '';
  color: string = '';
  icon: string = '';
  value: number = 0;
  count: number = 0;
  /** 占比 0~1 */
  ratio: number = 0;

  constructor(categoryId: string, name: string, color: string, icon: string, value: number, count: number) {
    this.categoryId = categoryId;
    this.name = name;
    this.color = color;
    this.icon = icon;
    this.value = value;
    this.count = count;
  }
}

/** 已颁发的证书记录（持久化到账户元信息，备份可带走） */
export class CertificateIssue {
  /** 对应 REDEEM_BADGES 里的证书 id */
  badgeId: string = '';
  /** 证书编号，如 CF-20261027-482913 */
  serial: string = '';
  /** 颁发时间戳（毫秒）；早期版本迁移过来的数据为 0 */
  issuedAt: number = 0;

  constructor(badgeId: string, serial: string, issuedAt: number) {
    this.badgeId = badgeId;
    this.serial = serial;
    this.issuedAt = issuedAt;
  }
}

/** 证书展示态：兑换记录 + 证书定义 */
export class CertificateInfo {
  badge: Badge;
  serial: string = '';
  issuedAt: number = 0;

  constructor(badge: Badge, serial: string, issuedAt: number) {
    this.badge = badge;
    this.serial = serial;
    this.issuedAt = issuedAt;
  }
}

/**
 * 家庭成员。演示用户的数据存在成员对象里；"我"的减排量在汇总时
 * 用 CarbonStore 的实时 Summary 覆盖，保证记账后家庭总数立即变化。
 */
export class FamilyMember {
  /** 账号 id（服务端 users.id，uuid） */
  id: string = '';
  /** 登录账号，用于展示和搜索 */
  username: string = '';
  name: string = '';
  avatar: string = '🌱';
  isMe: boolean = false;
  isOwner: boolean = false;
  monthReduction: number = 0;
  todayReduction: number = 0;
  totalReduction: number = 0;

  constructor(id: string, username: string, name: string, avatar: string, isMe: boolean, isOwner: boolean,
    monthReduction: number, todayReduction: number, totalReduction: number) {
    this.id = id;
    this.username = username;
    this.name = name;
    this.avatar = avatar;
    this.isMe = isMe;
    this.isOwner = isOwner;
    this.monthReduction = monthReduction;
    this.todayReduction = todayReduction;
    this.totalReduction = totalReduction;
  }

  copy(): FamilyMember {
    return new FamilyMember(this.id, this.username, this.name, this.avatar, this.isMe, this.isOwner,
      this.monthReduction, this.todayReduction, this.totalReduction);
  }
}

/**
 * 一条家庭邀请。
 * family_id 为空 = 组建型（对方也在找家人，同意后由邀请人当房主新建家庭）；
 * hasFamily = true = 加入型（对方已有家庭，同意后并入）。
 */
export class FamilyInvite {
  inviteId: string = '';
  inviterId: string = '';
  inviteeId: string = '';
  /** 对方昵称 */
  nickname: string = '';
  /** 对方登录账号 */
  username: string = '';
  /** 家庭名（组建型是待建家庭的名字） */
  familyName: string = '我的低碳家庭';
  /** 对方是否已有家庭（true=加入型） */
  hasFamily: boolean = false;
  /** ISO 时间串，用于展示 */
  createdAt: string = '';
  expiresAt: string = '';

  copy(): FamilyInvite {
    const out = new FamilyInvite();
    out.inviteId = this.inviteId;
    out.inviterId = this.inviterId;
    out.inviteeId = this.inviteeId;
    out.nickname = this.nickname;
    out.username = this.username;
    out.familyName = this.familyName;
    out.hasFamily = this.hasFamily;
    out.createdAt = this.createdAt;
    out.expiresAt = this.expiresAt;
    return out;
  }
}

/** 一个家庭：创建者 + 至少一位成员 */
export class FamilyInfo {
  id: string = '';
  name: string = '';
  inviteCode: string = '';
  ownerId: string = '';
  createdAt: number = 0;
  /** 人数上限，由服务端下发 */
  memberLimit: number = 6;
  members: FamilyMember[] = [];

  memberCount(): number {
    return this.members.length;
  }

  ownerName(): string {
    for (const m of this.members) {
      if (m.id === this.ownerId) {
        return m.name;
      }
    }
    return '';
  }
}

/** 家庭碳足迹汇总 */
export class FamilySummary {
  memberCount: number = 0;
  /** 本月家庭减排 kg */
  monthReduction: number = 0;
  /** 今日家庭减排 kg */
  todayReduction: number = 0;
  /** 家庭累计减排 kg */
  totalReduction: number = 0;
  /** 等效植树（棵·年） */
  treeCount: number = 0;
  /** 成员月均减排 kg */
  averageMonth: number = 0;
}

/**
 * 搜索结果里的一个用户（服务端 family_search 的返回）。
 * 只包含公开信息：账号、昵称、是否已有家庭；不含任何减排数据。
 */
export class DirectoryUser {
  /** 账号 id（uuid），发邀请时用它 */
  id: string = '';
  /** 登录账号 */
  username: string = '';
  /** 昵称 */
  name: string = '';
  avatar: string = '🌱';
  /** 是否已经在某个家庭里 */
  hasFamilyFlag: boolean = false;
  /** 是否和我同在一个家庭 */
  inMyFamily: boolean = false;

  constructor(id: string, username: string, name: string, avatar: string, hasFamily: boolean,
    inMyFamily: boolean) {
    this.id = id;
    this.username = username;
    this.name = name;
    this.avatar = avatar;
    this.hasFamilyFlag = hasFamily;
    this.inMyFamily = inMyFamily;
  }

  hasFamily(): boolean {
    return this.hasFamilyFlag;
  }

  copy(): DirectoryUser {
    return new DirectoryUser(this.id, this.username, this.name, this.avatar, this.hasFamilyFlag,
      this.inMyFamily);
  }
}
