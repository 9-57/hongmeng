import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bumpDataVersion, todayStr } from '../common/Utils';
import { carbonStore } from '../viewmodel/CarbonStore';
import { auth } from './AuthService';
import { cloudAccount } from './CloudAccount';
import { RecogResult } from './ImageRecognitionService';
import {
  AUTO_DAILY_CAP, AUTO_DEDUPE_MS, AutoCandidate, AutoDecision, decideAutoRecords, PolicyContext
} from './AutoRecordPolicy';
import { storage } from './StorageService';

const TAG = 'carbon-auto';

/** 台账存储键：只存指纹与计数，不存图片本身 */
const LEDGER_KEY = 'auto_record_ledger';

/** 自动记账固定按 1 个计量单位记（模型只判"有没有这件事"，不判数量） */
const AUTO_QTY = 1;

/** 备注前缀：历史列表和导出报表里能一眼看出这条是识别来的 */
const NOTE_PREFIX = 'AI识别自动记账';

/** 台账最多保留的图片指纹条目，防止长期使用后无限增长 */
const MAX_IMAGE_ENTRIES = 200;

/** 一条"这张图记过账"的记录 */
class LedgerImage {
  hash: string = '';
  ts: number = 0;
}

/** 今日某行为的自动记账次数 */
class LedgerCount {
  activityId: string = '';
  n: number = 0;
}

/**
 * 自动记账台账。
 * JSON 里不能直接存 Map，所以计数用数组；读取时再转成 Map 交给策略函数。
 */
class AutoLedger {
  version: number = 1;
  images: LedgerImage[] = [];
  /** counts 所属日期 yyyy-MM-dd，跨天自动清零 */
  day: string = '';
  counts: LedgerCount[] = [];
}

/** 一次自动记账的结果，message 可直接 toast */
export class AutoCommitResult {
  ok: boolean = false;
  message: string = '';
  /** 已记账的展示项，例如「骑共享单车 +3」 */
  added: string[] = [];
  /** 本次共获得积分 */
  points: number = 0;
  /** 已记账的行为 id，界面据此把对应候选标成"已记账" */
  addedIds: string[] = [];
  /** 这张图在去重窗口内已经记过账 */
  duplicatedImage: boolean = false;
}

/**
 * 图片识别 → 自动判定 → 自动记账。
 *
 * 职责边界：
 *   - 判定该不该记（去重 / 日上限 / 置信度）交给 AutoRecordPolicy，纯函数、可回归；
 *   - 这里只做"读台账 → 算指纹 → 调策略 → 写库 → 回写台账"。
 *
 * 写库顺序与手动记账一致（登录后先服务端 RPC、再落本地）。区别在于这里不能
 * 因为云端失败就整轮放弃：手动记账本来就是只写本地，云端不可达时用户照样能记，
 * 自动记账如果必须云端成功才落库，就会出现"手动能记、自动记不上"的割裂。
 * 因此云端失败时退回本地写入，并在提示里写明"未同步云端"。
 */
export class AutoRecordService {
  /** 同一时刻只允许一轮自动记账，避免连续点识别把台账读脏 */
  private static committing: boolean = false;

  /**
   * 把一次 AI 识别结果落库。
   *
   * @param uri 选中的图片 uri，用于算去重指纹
   * @param r   识别结果（只有 AI 判定这一条来源）
   */
  static async commit(uri: string, r: RecogResult): Promise<AutoCommitResult> {
    const out = new AutoCommitResult();
    if (!r.ok || !r.hasLowCarbon || r.tags.length === 0) {
      out.message = '这次没有可自动记账的低碳行为';
      return out;
    }
    if (AutoRecordService.committing) {
      out.message = '上一次识别还在记账，稍等一下再试';
      return out;
    }
    AutoRecordService.committing = true;
    try {
      return await AutoRecordService.doCommit(uri, r);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'commit failed: %{public}s', e.message);
      out.message = '自动记账出错，请稍后重试';
      return out;
    } finally {
      AutoRecordService.committing = false;
    }
  }

  private static async doCommit(uri: string, r: RecogResult): Promise<AutoCommitResult> {
    const out = new AutoCommitResult();
    const now = Date.now();
    const today = todayStr();

    // 只保留能在内置清单里找到的行为，模型编出来的 id 一律不认
    const candidates: AutoCandidate[] = [];
    for (const t of r.tags) {
      const a = carbonStore.getActivityById(t.activityId);
      if (a === undefined) {
        continue;
      }
      candidates.push(new AutoCandidate(a.id, a.name));
    }
    if (candidates.length === 0) {
      out.message = '识别到的行为不在内置清单里，没有记账';
      return out;
    }

    const hash = await AutoRecordService.fingerprint(uri);
    const ledger = await AutoRecordService.loadLedger(today, now);

    const ctx = new PolicyContext();
    ctx.now = now;
    ctx.todayCount = AutoRecordService.countMap(ledger);
    ctx.imageSeen = AutoRecordService.seenMap(ledger);
    const decision = decideAutoRecords(candidates, hash, ctx);

    // 排查"识别出来了却没加分"：把模型给的 id 和闸门判定都记进日志
    const ids: string[] = [];
    for (const c of candidates) {
      ids.push(c.activityId);
    }
    hilog.info(0x0000, TAG, 'judge: tags=[%{public}s] dup=%{public}s accepted=%{public}d skip=%{public}d',
      ids.join(','), `${decision.duplicatedImage}`,
      decision.accepted.length, decision.skipped.length);

    if (decision.duplicatedImage) {
      out.duplicatedImage = true;
      out.message = '这张照片 24 小时内已经记过账，没有重复加分';
      return out;
    }

    const failures: string[] = [];
    const syncNotes: string[] = [];
    let counted = 0;
    for (const c of decision.accepted) {
      const a = carbonStore.getActivityById(c.activityId);
      if (a === undefined) {
        continue;
      }
      const note = AutoRecordService.noteOf(c);
      let point = 0;
      if (auth.isLoggedIn) {
        // 先服务端、再本地：云端成功时换设备拉回快照也有这条记录
        const op = await cloudAccount.addRecord(a, AUTO_QTY, today, note);
        if (op.ok) {
          point = op.point;
        } else {
          syncNotes.push(op.message.length > 0 ? op.message : '网络异常');
        }
      }
      if (point <= 0) {
        // 云端没成功（或未登录）：退回本地写入。手动记账本来就是这条路，
        // 自动记账没有理由因为云端不可达就什么都不记。
        const local = await carbonStore.addRecord(a, AUTO_QTY, today, note);
        if (local <= 0) {
          failures.push(syncNotes.length > 0 ? syncNotes[0] : '未登录，积分没有归属');
          break;
        }
        point = local;
        bumpDataVersion();
      }
      out.added.push(`${a.name} +${point}`);
      out.addedIds.push(a.id);
      out.points += point;
      counted += 1;
      AutoRecordService.bumpCount(ledger, a.id);
    }

    if (counted > 0) {
      AutoRecordService.rememberImage(ledger, hash, now);
      await AutoRecordService.saveLedger(ledger);
      out.ok = failures.length === 0;
    }
    out.message = AutoRecordService.buildMessage(out, decision, failures, syncNotes);
    hilog.info(0x0000, TAG, 'auto record: added=%{public}d point=%{public}d syncFail=%{public}d',
      counted, out.points, syncNotes.length);
    return out;
  }

  /** 拼一条人话结论：记了多少分、如果没记是为什么 */
  private static buildMessage(out: AutoCommitResult, decision: AutoDecision, failures: string[],
    syncNotes: string[]): string {
    if (out.added.length > 0) {
      const parts: string[] = [`已自动记账：${out.added.join('、')}`];
      if (failures.length > 0) {
        parts.push(`另有条目没记上：${failures[0]}`);
      }
      if (syncNotes.length > 0) {
        parts.push(`已记到本机，云端未同步（${syncNotes[0]}）`);
      }
      if (decision.cappedCount() > 0) {
        parts.push(`该行为今天已自动记账 ${AUTO_DAILY_CAP} 次，不再重复加分`);
      }
      return parts.join('；');
    }
    if (failures.length > 0) {
      return `识别成功，但记账没保存：${failures[0]}`;
    }
    if (decision.cappedCount() > 0) {
      return `识别到的行为今天已自动记账 ${AUTO_DAILY_CAP} 次，本次不重复加分`;
    }
    return '没有可自动记账的低碳行为';
  }

  /** 备注：标明来源 + 行为名，历史与报表里一眼能认出是识别记的账 */
  private static noteOf(c: AutoCandidate): string {
    return `${NOTE_PREFIX}：${c.activityName}`;
  }

  // ==================== 图片指纹 ====================

  /**
   * 计算图片的感知指纹（dHash，9×8 灰度相邻比较，64 位 → 16 位十六进制）。
   *
   * 用感知指纹而不是 uri / 文件大小：同一张照片经由图库返回的 uri 可能变化，
   * 复制一份后大小也可能不同，但缩略后的明暗结构不会变。指纹只在本机参与去重，
   * 不会上传，也不落进任何业务记录。
   */
  private static async fingerprint(uri: string): Promise<string> {
    if (uri.length === 0) {
      return '';
    }
    let src: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    let fd: number = -1;
    try {
      try {
        const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        fd = f.fd;
        src = image.createImageSource(f.fd);
      } catch (e) {
        src = image.createImageSource(uri);
      }
      if (src === null) {
        return '';
      }
      const info = await src.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return '';
      }
      const opt: image.DecodingOptions = {
        desiredSize: { width: 9, height: 8 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pixels = await src.createPixelMap(opt);
      // 少数解码路径会忽略 desiredSize：这时前 72 个像素只是原图左上角，
      // 拿它算指纹会让"左上角都是天空"的两张不同照片被判成同一张。
      const decoded = await pixels.getImageInfo();
      if (decoded.size.width !== 9 || decoded.size.height !== 8) {
        hilog.warn(0x0000, TAG, 'fingerprint skipped, decoded size mismatch');
        return '';
      }
      const buffer = new ArrayBuffer(pixels.getPixelBytesNumber());
      await pixels.readPixelsToBuffer(buffer);
      const bytes = new Uint8Array(buffer);
      const need = 9 * 8;
      if (bytes.length < need * 4) {
        return '';
      }
      const gray: number[] = [];
      for (let i = 0; i < need; i++) {
        const p = i * 4;
        gray.push((bytes[p] + bytes[p + 1] + bytes[p + 2]) / 3);
      }
      let bits = '';
      for (let y = 0; y < 8; y++) {
        for (let x = 0; x < 8; x++) {
          const left = gray[y * 9 + x];
          const right = gray[y * 9 + x + 1];
          bits += left > right ? '1' : '0';
        }
      }
      let hex = '';
      let nibble = 0;
      for (let i = 0; i < bits.length; i++) {
        nibble = (nibble << 1) | (bits.charAt(i) === '1' ? 1 : 0);
        if (i % 4 === 3) {
          hex += '0123456789abcdef'.charAt(nibble);
          nibble = 0;
        }
      }
      return hex;
    } catch (err) {
      const e = err as BusinessError;
      // 算不出指纹不算失败：退化成"不做同图去重"，但每日上限仍然生效
      hilog.warn(0x0000, TAG, 'fingerprint failed: %{public}s', e.message);
      return '';
    } finally {
      if (pixels !== null) {
        try {
          await pixels.release();
        } catch (e) {
          // 释放失败不影响结果
        }
      }
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
          // 同上
        }
      }
      if (fd !== -1) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 同上
        }
      }
    }
  }

  // ==================== 台账读写 ====================

  /** 读台账；顺手丢掉过窗的指纹，并在跨天时清零计数 */
  private static async loadLedger(today: string, now: number): Promise<AutoLedger> {
    const ledger = new AutoLedger();
    ledger.day = today;
    let raw = '';
    try {
      raw = await storage.readString(LEDGER_KEY, '');
    } catch (e) {
      return ledger;
    }
    if (raw.length === 0) {
      return ledger;
    }
    try {
      const parsed = JSON.parse(raw) as AutoLedger;
      if (parsed === null || parsed === undefined) {
        return ledger;
      }
      if (Array.isArray(parsed.images)) {
        for (const item of parsed.images) {
          if (item === undefined || item === null) {
            continue;
          }
          const hash = typeof item.hash === 'string' ? item.hash : '';
          const ts = typeof item.ts === 'number' && isFinite(item.ts) ? item.ts : 0;
          if (hash.length === 0 || ts <= 0) {
            continue;
          }
          if (Math.abs(now - ts) >= AUTO_DEDUPE_MS) {
            continue;
          }
          const entry = new LedgerImage();
          entry.hash = hash;
          entry.ts = ts;
          ledger.images.push(entry);
        }
      }
      // 计数只在同一天有效；昨天的次数不能压住今天的额度
      if (parsed.day === today && Array.isArray(parsed.counts)) {
        for (const item of parsed.counts) {
          if (item === undefined || item === null) {
            continue;
          }
          const id = typeof item.activityId === 'string' ? item.activityId : '';
          const n = typeof item.n === 'number' && isFinite(item.n) ? item.n : 0;
          if (id.length === 0 || n <= 0) {
            continue;
          }
          const count = new LedgerCount();
          count.activityId = id;
          count.n = Math.floor(n);
          ledger.counts.push(count);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'ledger parse failed, start fresh');
    }
    return ledger;
  }

  private static async saveLedger(ledger: AutoLedger): Promise<void> {
    try {
      await storage.writeString(LEDGER_KEY, JSON.stringify(ledger));
    } catch (e) {
      hilog.error(0x0000, TAG, 'ledger save failed');
    }
  }

  private static countMap(ledger: AutoLedger): Map<string, number> {
    const map = new Map<string, number>();
    for (const c of ledger.counts) {
      map.set(c.activityId, c.n);
    }
    return map;
  }

  private static seenMap(ledger: AutoLedger): Map<string, number> {
    const map = new Map<string, number>();
    for (const e of ledger.images) {
      map.set(e.hash, e.ts);
    }
    return map;
  }

  private static bumpCount(ledger: AutoLedger, activityId: string): void {
    for (const c of ledger.counts) {
      if (c.activityId === activityId) {
        c.n += 1;
        return;
      }
    }
    const count = new LedgerCount();
    count.activityId = activityId;
    count.n = 1;
    ledger.counts.push(count);
  }

  private static rememberImage(ledger: AutoLedger, hash: string, now: number): void {
    if (hash.length === 0) {
      return;
    }
    for (const e of ledger.images) {
      if (e.hash === hash) {
        e.ts = now;
        return;
      }
    }
    const entry = new LedgerImage();
    entry.hash = hash;
    entry.ts = now;
    ledger.images.push(entry);
    // 只保留最近 24 小时内的指纹，并给一个硬上限
    const kept: LedgerImage[] = [];
    for (const e of ledger.images) {
      if (Math.abs(now - e.ts) < AUTO_DEDUPE_MS) {
        kept.push(e);
      }
    }
    const start = kept.length > MAX_IMAGE_ENTRIES ? kept.length - MAX_IMAGE_ENTRIES : 0;
    ledger.images = kept.slice(start);
  }
}
