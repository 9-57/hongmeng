/** 日期/格式化/通用工具。所有函数均为纯函数，便于单测与复用。 */

/** 补零 */
function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** 时间戳 -> yyyy-MM-dd */
export function formatDate(ts: number): string {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 时间戳 -> MM-dd HH:mm */
export function formatDateTime(ts: number): string {
  const d = new Date(ts);
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** yyyy-MM-dd -> 时间戳（当天 0 点）；非法输入返回 0 */
export function dateStart(dateStr: string): number {
  if (typeof dateStr !== 'string' || dateStr.length !== 10) {
    return 0;
  }
  const parts = dateStr.split('-');
  if (parts.length !== 3) {
    return 0;
  }
  const y = Number(parts[0]);
  const m = Number(parts[1]);
  const d = Number(parts[2]);
  if (!isFinite(y) || !isFinite(m) || !isFinite(d) || m < 1 || m > 12 || d < 1 || d > 31) {
    return 0;
  }
  return new Date(y, m - 1, d).getTime();
}

/** 取某天 0 点的时间戳 */
export function dayStart(ts: number): number {
  const d = new Date(ts);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

/** 生成唯一 id */
let seed = 0;
export function genId(prefix: string): string {
  seed += 1;
  return `${prefix}_${Date.now()}_${seed}`;
}

/** 保留小数位 */
export function round(value: number, digits: number): number {
  const p = Math.pow(10, digits);
  return Math.round(value * p) / p;
}

/**
 * 证书编号：CF-yyyyMMdd-6位时间尾号。
 * 用时间尾号而不是自增序号，跨重启也不会重复；同毫秒重复的概率可以忽略。
 */
export function certSerial(): string {
  const d = new Date();
  const ymd = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  let tail = `${Date.now() % 1000000}`;
  while (tail.length < 6) {
    tail = `0${tail}`;
  }
  return `CF-${ymd}-${tail}`;
}

/** 数字友好显示：小于 1 保留 2 位，小于 100 保留 1 位，其他取整 */
export function fmtKg(value: number): string {
  if (!isFinite(value) || value === 0) {
    return '0';
  }
  const abs = Math.abs(value);
  if (abs < 1) {
    return value.toFixed(2);
  }
  if (abs < 100) {
    return value.toFixed(1);
  }
  return Math.round(value).toString();
}

/** 今天的日期字符串 */
export function todayStr(): string {
  return formatDate(Date.now());
}

/**
 * 本周起始（周一 0 点）。
 * 用 Date 的日期运算而不是直接减 86400000 毫秒：后者在跨夏令时的地区会偏移一小时，
 * 导致周一凌晨的记录被算进上一周。
 */
export function weekStart(ts: number): number {
  const d = new Date(dayStart(ts));
  const wd = d.getDay() === 0 ? 7 : d.getDay();
  d.setDate(d.getDate() - (wd - 1));
  return d.getTime();
}

/** 月份显示，如 2026-10 */
export function monthKey(ts: number): string {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`;
}

/** 中文星期 */
export function weekLabel(ts: number): string {
  const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  return names[new Date(ts).getDay()];
}

/** CSV 单元格转义：含逗号/引号/换行时加引号，内部引号翻倍 */
export function csvCell(value: string): string {
  const needQuote = value.indexOf(',') >= 0 || value.indexOf('"') >= 0 ||
    value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0;
  if (!needQuote) {
    return value;
  }
  return `"${value.split('"').join('""')}"`;
}

/** 安全取回 AppStorage 中的版本号并自增，驱动各页面刷新 */
export function bumpDataVersion(): void {
  const cur = AppStorage.get<number>('carbonVersion');
  AppStorage.setOrCreate('carbonVersion', (cur === undefined ? 0 : cur) + 1);
}

/** 荣誉类型的中文名：成就 / 兑换徽章都算「徽章」 */
export function honorTypeName(type: string): string {
  if (type === 'cert') {
    return '证书';
  }
  if (type === 'award') {
    return '奖状';
  }
  return '徽章';
}

/**
 * 请求全局荣誉放大弹层（Index 监听这个通道）。
 * 徽章/证书/奖状可能在任何页面获得，弹层放在 Index 才能盖住当前页面。
 */
export function requestHonorView(badgeId: string): void {
  AppStorage.setOrCreate('honorViewId', badgeId);
  const cur = AppStorage.get<number>('honorViewTick');
  AppStorage.setOrCreate('honorViewTick', (cur === undefined ? 0 : cur) + 1);
}
