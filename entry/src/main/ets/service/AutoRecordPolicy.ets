/**
 * 图片识别自动记账的判定策略（纯函数，不碰 UI / 网络 / 存储）。
 *
 * 模型只回两个值（有没有、是哪一条），所以判定逻辑也随之收敛成两道硬闸：
 *   1. 同图去重：同一张照片 24 小时内只记一次，反复选同一张图不叠加；
 *   2. 单行为每日上限：同一 activityId 每天最多自动记 N 次，防连拍同类照片刷分。
 * 闸门都在这里判定，AutoRecordService 只负责"按判定结果干活"，
 * 因此这段逻辑可以被 tools/verify-logic.mjs 直接转译执行，不需要模拟图片。
 */

/** 单条行为每天最多自动记账次数 */
export const AUTO_DAILY_CAP = 3;

/** 同图去重时间窗：24 小时 */
export const AUTO_DEDUPE_MS = 24 * 60 * 60 * 1000;

/** 等待判定的候选（已映射到内置行为） */
export class AutoCandidate {
  activityId: string = '';
  activityName: string = '';

  constructor(activityId: string, activityName: string) {
    this.activityId = activityId;
    this.activityName = activityName;
  }
}

/** 判定上下文：由 AutoRecordService 从本地台账读出后填入 */
export class PolicyContext {
  /** 当前时间戳（毫秒） */
  now: number = 0;
  /** 图片指纹 → 上次记账时间戳 */
  imageSeen: Map<string, number> = new Map<string, number>();
  /** 今日各行为已自动记账次数 */
  todayCount: Map<string, number> = new Map<string, number>();
  /** 单行为每日上限 */
  dailyCap: number = AUTO_DAILY_CAP;
  /** 同图去重时间窗 */
  dedupeWindowMs: number = AUTO_DEDUPE_MS;
}

/** 被跳过的候选及原因 */
export class SkippedCandidate {
  activityId: string = '';
  /** 目前只有 daily_cap（已达今日上限） */
  reason: string = '';

  constructor(activityId: string, reason: string) {
    this.activityId = activityId;
    this.reason = reason;
  }
}

/** 判定结果 */
export class AutoDecision {
  accepted: AutoCandidate[] = [];
  skipped: SkippedCandidate[] = [];
  /** 这张图在去重窗口内已经记过账 */
  duplicatedImage: boolean = false;

  /** 因"已达今日上限"被跳过的条数 */
  cappedCount(): number {
    let n = 0;
    for (const s of this.skipped) {
      if (s.reason === 'daily_cap') {
        n += 1;
      }
    }
    return n;
  }
}

/**
 * 判定这一轮该记哪些、跳过哪些。
 *
 * 模型只给一条结论，所以没有"置信度筛选"这回事：它说是什么就是什么，
 * App 只负责拦住重复（同图、超量）。
 *
 * @param candidates 模型给出的候选（通常只有一条）
 * @param imageHash  图片指纹；空串表示算不出指纹，此时不做同图去重
 * @param ctx        台账上下文
 */
export function decideAutoRecords(candidates: AutoCandidate[], imageHash: string,
  ctx: PolicyContext): AutoDecision {
  const out = new AutoDecision();

  if (imageHash.length > 0) {
    const seenAt = ctx.imageSeen.get(imageHash);
    if (seenAt !== undefined) {
      // 用户改过系统时间时 age 可能为负，取绝对值，避免"改时间就能重复加分"
      const age = Math.abs(ctx.now - seenAt);
      if (age < ctx.dedupeWindowMs) {
        out.duplicatedImage = true;
        return out;
      }
    }
  }

  const seen: Map<string, boolean> = new Map<string, boolean>();
  for (const c of candidates) {
    if (c.activityId.length === 0) {
      continue;
    }
    // 同一次判定里同一个行为重复出现，只算一次
    if (seen.has(c.activityId)) {
      continue;
    }
    seen.set(c.activityId, true);

    const before = ctx.todayCount.get(c.activityId);
    const already = before === undefined ? 0 : before;
    if (already >= ctx.dailyCap) {
      out.skipped.push(new SkippedCandidate(c.activityId, 'daily_cap'));
      continue;
    }

    out.accepted.push(c);
  }
  return out;
}
