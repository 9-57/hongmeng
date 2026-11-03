import { Activity, Category } from '../model/CarbonModels';
import { ACTIVITIES, CATEGORIES } from '../model/CarbonData';
import { round } from '../common/Utils';

/**
 * 个性化推荐与生活建议引擎（纯函数，便于回归测试）。
 *
 * 设计原则：
 * - 只根据用户真实数据下结论，不做随机推荐；
 * - 优先级：连续打卡将断 > 从未尝试的分类 > 类别结构失衡 > 月度目标 > 证书可兑换 > 鼓励；
 * - 不足 3 条时用通用生活技巧补齐，保证首页永远有内容。
 */

/** 推荐引擎的输入快照（由 CarbonStore 组装） */
export class InsightInput {
  totalCount: number = 0;
  todayCount: number = 0;
  streakDays: number = 0;
  totalReduction: number = 0;
  monthReduction: number = 0;
  monthGoal: number = 30;
  monthActiveDays: number = 0;
  totalPoint: number = 0;
  certCount: number = 0;
  /** categoryId -> 记录条数 */
  categoryCounts: Map<string, number> = new Map<string, number>();
  /** categoryId -> 累计减排 */
  categoryValues: Map<string, number> = new Map<string, number>();
}

/** 一条个性化推荐 / 生活建议 */
export class Insight {
  id: string = '';
  /** task：可跳转记录的推荐任务；advice：生活建议 */
  kind: string = 'advice';
  icon: string = '';
  title: string = '';
  detail: string = '';
  /** 建议去记录的分类，空串表示纯建议 */
  categoryId: string = '';
  /** 建议记录的具体行为，空串表示无 */
  activityId: string = '';
  /** 按钮文案，空串表示不显示按钮 */
  actionLabel: string = '';

  constructor(id: string, kind: string, icon: string, title: string, detail: string,
    categoryId: string, activityId: string, actionLabel: string) {
    this.id = id;
    this.kind = kind;
    this.icon = icon;
    this.title = title;
    this.detail = detail;
    this.categoryId = categoryId;
    this.activityId = activityId;
    this.actionLabel = actionLabel;
  }
}

const MAX_INSIGHTS = 3;

function countOf(input: InsightInput, categoryId: string): number {
  const n = input.categoryCounts.get(categoryId);
  return n === undefined ? 0 : n;
}

/** 取某分类里减排因子最高（收益最大）的行为 */
function bestActivityOf(categoryId: string): Activity {
  let best: Activity = ACTIVITIES[0];
  for (const a of ACTIVITIES) {
    if (a.categoryId === categoryId && a.factor > best.factor) {
      best = a;
    }
  }
  return best;
}

/** 全库减排因子最高的行为，用于月度目标建议 */
function highestImpactActivity(): Activity {
  let best: Activity = ACTIVITIES[0];
  for (const a of ACTIVITIES) {
    if (a.factor > best.factor) {
      best = a;
    }
  }
  return best;
}

/** 记录最少（最该补课）的分类 */
function leastUsedCategory(input: InsightInput): Category {
  let target: Category = CATEGORIES[0];
  let min = 999999;
  for (const c of CATEGORIES) {
    const n = countOf(input, c.id);
    if (n < min) {
      min = n;
      target = c;
    }
  }
  return target;
}

function pushUnique(list: Insight[], item: Insight): void {
  if (list.length >= MAX_INSIGHTS) {
    return;
  }
  for (const old of list) {
    if (old.id === item.id) {
      return;
    }
  }
  list.push(item);
}

/** 通用生活技巧：没有更具体的建议时补齐 */
function fallbackTips(): Insight[] {
  return [
    new Insight('tip-walk', 'task', '🚶', '3 公里内，试试走路', '短途步行或骑行代替打车，单次就能减 0.2~0.4 kg。',
      'travel', 'travel_walk', '去记录'),
    new Insight('tip-ac', 'task', '❄️', '空调调高 1℃', '夏天 26℃ 既舒服又省电，一晚能少排约 0.5 kg。',
      'energy', 'energy_ac', '去记录'),
    new Insight('tip-box', 'task', '📦', '快递箱拆平回收', '攒起来送回收点，纸箱循环一次就少砍一棵小树。',
      'recycle', 'recycle_paper', '去记录'),
    new Insight('tip-cup', 'task', '🥤', '自带水杯', '少用一次一次性杯，减碳约 0.055 kg，还更卫生。',
      'shopping', 'shop_cup', '去记录'),
    new Insight('tip-food', 'task', '🍚', '按量打饭，光盘一次', '剩饭背后是种植、运输、烹饪的整条碳链。',
      'food', 'food_clean', '去记录'),
    new Insight('tip-plant', 'task', '🌱', '参加一次低碳公益', '植树或公益捐步，把减排变成能分享的行动。',
      'plant', 'plant_antforest', '去记录')
  ];
}

/**
 * 生成 1~3 条个性化推荐。
 * 纯函数：相同输入必定得到相同输出，方便测试与复现。
 */
export function buildInsights(input: InsightInput): Insight[] {
  const list: Insight[] = [];

  // 1. 新用户：先完成第一条记录
  if (input.totalCount === 0) {
    pushUnique(list, new Insight('first', 'task', '🚶', '从一次步行开始',
      '记录第一条低碳行为，碳账本就开始运转了。', 'travel', 'travel_walk', '去记录'));
    pushUnique(list, new Insight('first-tip', 'advice', '🌱', '先记三天，找到你的排放大头',
      '不用一上来就追求完美，连续记三天，看看哪类行为最多。', '', '', ''));
  }

  // 2. 连续打卡要断：最高优先级
  if (input.totalCount > 0 && input.todayCount === 0 && input.streakDays > 0) {
    const c = leastUsedCategory(input);
    const a = bestActivityOf(c.id);
    pushUnique(list, new Insight('streak', 'task', '🔥', `连续 ${input.streakDays} 天，今天续上`,
      `今天还没有记录，别让连续打卡断在这里。推荐「${a.name}」。`, c.id, a.id, '去记录'));
  }

  // 3. 还有从未尝试过的分类：引导拓宽
  if (list.length < MAX_INSIGHTS) {
    for (const c of CATEGORIES) {
      if (countOf(input, c.id) === 0) {
        const a = bestActivityOf(c.id);
        pushUnique(list, new Insight(`try-${c.id}`, 'task', c.icon, `试一次${c.name}`,
          `${c.desc}。可以从「${a.name}」开始。`, c.id, a.id, '去记录'));
        break;
      }
    }
  }

  // 4. 类别结构失衡：某一类占比超过一半
  if (list.length < MAX_INSIGHTS && input.totalCount >= 5) {
    let maxCat: Category = CATEGORIES[0];
    let maxCount = 0;
    for (const c of CATEGORIES) {
      const n = countOf(input, c.id);
      if (n > maxCount) {
        maxCount = n;
        maxCat = c;
      }
    }
    if (maxCount / input.totalCount >= 0.5) {
      const target = leastUsedCategory(input);
      if (target.id !== maxCat.id) {
        const a = bestActivityOf(target.id);
        const pct = Math.round(maxCount / input.totalCount * 100);
        pushUnique(list, new Insight(`balance-${target.id}`, 'advice', '⚖️',
          `${maxCat.name}占了 ${pct}%`, `试试${target.name}，让低碳生活更均衡。推荐「${a.name}」。`,
          target.id, a.id, '去实践'));
      }
    }
  }

  // 5. 月度目标进度
  if (list.length < MAX_INSIGHTS && input.monthReduction < input.monthGoal * 0.5) {
    const need = round(input.monthGoal - input.monthReduction, 1);
    const a = highestImpactActivity();
    pushUnique(list, new Insight('goal', 'task', '🎯', `本月还差 ${need} kg`,
      `推荐「${a.name}」，单次约 ${a.factor} kg，离目标更近一步。`, a.categoryId, a.id, '去记录'));
  }

  // 6. 积分够换证书：提醒权益，不浪费
  if (list.length < MAX_INSIGHTS && input.certCount === 0 && input.totalPoint >= 180) {
    pushUnique(list, new Insight('cert', 'advice', '🎓', '积分已经够换证书了',
      `当前 ${input.totalPoint} 分，去「我的」兑换一张植树证书吧。`, '', '', ''));
  }

  // 7. 正反馈：连续 7 天以上
  if (list.length < MAX_INSIGHTS && input.streakDays >= 7) {
    pushUnique(list, new Insight('praise', 'advice', '🌿', `连续 ${input.streakDays} 天，习惯已经成型`,
      '保持节奏，比一次记很多更有价值。', '', '', ''));
  }

  // 8. 补位：通用生活技巧
  if (list.length < MAX_INSIGHTS) {
    for (const tip of fallbackTips()) {
      pushUnique(list, tip);
      if (list.length >= MAX_INSIGHTS) {
        break;
      }
    }
  }
  return list;
}
