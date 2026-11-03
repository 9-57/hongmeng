import { DayValue } from '../model/CarbonModels';

/**
 * 图表绘制。
 * 这里刻意不使用自定义组件（@Component）：CodeLinter 的
 * @performance/avoid-overusing-custom-component-check 规则提示，
 * 只负责画一块 Canvas 的结构用 @Builder + 独立绘制类即可，
 * 既省掉一层组件的创建与状态同步，也让 @Prop 数组的深拷贝开销消失。
 *
 * 尺寸来源：一律由调用方传入实际宽高（来自 Canvas 的 onAreaChange 或组件自身状态），
 * 不要依赖 ctx.width / ctx.height —— preview 下它可能滞后一帧或是 0，
 * 导致内容画到可视区外（表现为"柱子有、文字没有"）。
 *
 * 重绘约定（重要）：Canvas 只在 onReady / onAreaChange 时真正执行绘制命令，
 * 状态变化引起的 build 重执行不会重放 draw 调用。因此数据变了必须由页面调用
 * repaintXxxChart() 主动重画，否则用户看到的就是"切了区间图没动"。
 */

function alphaColor(hex: string, alpha: number): string {
  const h = hex.replace('#', '');
  if (h.length !== 6) {
    return hex;
  }
  const r = parseInt(h.substring(0, 2), 16);
  const g = parseInt(h.substring(2, 4), 16);
  const b = parseInt(h.substring(4, 6), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

/** 坐标轴/均值标签的数字写法：小值保留小数，大值取整，避免轴上出现 0.4000000000000001 */
function axisText(v: number): string {
  if (!isFinite(v) || v <= 0) {
    return '0';
  }
  if (v >= 10) {
    return `${Math.round(v)}`;
  }
  if (v >= 1) {
    return `${Math.round(v * 10) / 10}`;
  }
  return `${Math.round(v * 100) / 100}`;
}

/** 折线面积图：用于日/周/月/年趋势 */
export class LinePainter {
  draw(ctx: CanvasRenderingContext2D, w: number, h: number,
    data: DayValue[], accentIn: string, progressIn: number = 1): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    const accent = accentIn;
    ctx.clearRect(0, 0, w, h);
    const list = data;
    const n = list.length;
    if (n === 0) {
      return;
    }
    const padLeft = 34;
    const padRight = 12;
    const padTop = 16;
    const padBottom = 24;
    const innerW = w - padLeft - padRight;
    const innerH = h - padTop - padBottom;

    let max = 0;
    let sum = 0;
    for (let i = 0; i < n; i++) {
      sum += list[i].value;
      if (list[i].value > max) {
        max = list[i].value;
      }
    }
    if (max <= 0) {
      max = 1;
    }
    const hasValue = sum > 0;
    const step = Math.pow(10, Math.floor(Math.log10(max)));
    max = Math.ceil(max / step * 2) / 2 * step;
    const avg = sum / n;

    // 网格 + 左侧刻度：数据看板的趋势图要能读出量级，不能只是"一条好看的曲线"
    for (let i = 0; i <= 3; i++) {
      const y = padTop + innerH * i / 3;
      ctx.strokeStyle = '#EDEFEE';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(padLeft, y);
      ctx.lineTo(w - padRight, y);
      ctx.stroke();

      if (!hasValue) {
        continue;
      }
      ctx.fillStyle = '#98A39E';
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(axisText(max * (3 - i) / 3), padLeft - 6, y + 3);
    }

    if (!hasValue) {
      ctx.fillStyle = '#B3BDB8';
      ctx.font = '11px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('暂无数据', w / 2, padTop + innerH / 2);
    }

    const gap = n > 1 ? innerW / (n - 1) : 0;
    const points: number[][] = [];
    for (let i = 0; i < n; i++) {
      const x = padLeft + gap * i;
      const y = padTop + innerH - (list[i].value / max) * innerH;
      points.push([x, y]);
    }

    const progress = Math.max(0, Math.min(1, progressIn));
    const sweepX = padLeft + innerW * progress;

    // 从左往右"画"出来：面积、曲线、圆点、峰值标注都放进裁剪区，画到哪显示到哪。
    // 进度满时裁到整块画布，否则最右侧那个圆点和峰值文字会被切掉一半。
    const clipRight = progress >= 1 ? w : sweepX;
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, clipRight, h);
    ctx.clip();

    const grad = ctx.createLinearGradient(0, padTop, 0, padTop + innerH);
    grad.addColorStop(0, alphaColor(accent, 0.28));
    grad.addColorStop(1, alphaColor(accent, 0.02));
    ctx.beginPath();
    ctx.moveTo(points[0][0], padTop + innerH);
    for (let i = 0; i < n; i++) {
      ctx.lineTo(points[i][0], points[i][1]);
    }
    ctx.lineTo(points[n - 1][0], padTop + innerH);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // 均值虚线：给趋势一个参照，避免只看到"最新一根高不高"
    if (avg > 0) {
      const ay = padTop + innerH - (avg / max) * innerH;
      ctx.strokeStyle = alphaColor(accent, 0.45);
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.moveTo(padLeft, ay);
      ctx.lineTo(w - padRight, ay);
      ctx.stroke();
      ctx.setLineDash([]);

      const ly = ay - 4 < 10 ? ay + 11 : ay - 4;
      ctx.fillStyle = alphaColor(accent, 0.9);
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(`均值 ${axisText(avg)}`, padLeft + 2, ly);
    }

    ctx.beginPath();
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2.5;
    ctx.lineJoin = 'round';
    for (let i = 0; i < n; i++) {
      if (i === 0) {
        ctx.moveTo(points[i][0], points[i][1]);
      } else {
        ctx.lineTo(points[i][0], points[i][1]);
      }
    }
    ctx.stroke();

    for (let i = 0; i < n; i++) {
      ctx.beginPath();
      ctx.arc(points[i][0], points[i][1], 3.2, 0, Math.PI * 2);
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
      ctx.strokeStyle = accent;
      ctx.lineWidth = 2;
      ctx.stroke();
    }

    let maxIdx = 0;
    for (let i = 0; i < n; i++) {
      if (list[i].value > list[maxIdx].value) {
        maxIdx = i;
      }
    }
    if (list[maxIdx].value > 0) {
      ctx.fillStyle = accent;
      ctx.font = 'bold 10px sans-serif';
      ctx.textAlign = 'center';
      const ty = points[maxIdx][1] - 8 < 10 ? points[maxIdx][1] + 14 : points[maxIdx][1] - 8;
      ctx.fillText(`${list[maxIdx].value}`, points[maxIdx][0], ty);
    }

    ctx.restore();

    // X 轴标签不参与裁剪：动画过程中刻度一直在，只有曲线从左往右长出来
    ctx.fillStyle = '#8A9490';
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'center';
    const showEvery = n > 8 ? Math.ceil(n / 6) : 1;
    for (let i = 0; i < n; i++) {
      if (i % showEvery !== 0 && i !== n - 1) {
        continue;
      }
      ctx.fillText(list[i].label, Math.min(Math.max(points[i][0], 16), w - 16), h - 6);
    }
  }
}

/** 柱状图：用于分类对比 */
export class BarPainter {
  /**
   * @param w 画布实际宽度
   * @param h 画布实际高度
   * @param labels 每根柱子下方的分类名（保留参数，绘制名由页面原生 Text 承担）
   * @param values 数值
   * @param colors 每根柱子的颜色
   */
  draw(ctx: CanvasRenderingContext2D, w: number, h: number,
    labels: string[], values: number[], colors: string[], progressIn: number = 1): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const n = values.length;
    if (n === 0) {
      return;
    }
    // 顶部 20 留给数值标注；底部 32 留给分类名（字体 11vp + 上下余量）
    const padTop = 20;
    // 左右不留白：柱子按 slot 等分整宽，下方原生 Text 也是等分整宽，
    // 两者中心才能严格对齐（详见 ChartTab 里分类名的 Row 布局）
    const padLeft = 0;
    const padRight = 0;
    const innerW = Math.max(10, w - padLeft - padRight);
    // innerH 必须为正且留出底部标签区，否则 baseY 会溢出到标签区外看不见
    const labelZone = 26;
    const innerH = Math.max(10, h - padTop - labelZone);
    const baseY = h - labelZone;

    let max = 0;
    for (let i = 0; i < n; i++) {
      if (values[i] > max) {
        max = values[i];
      }
    }
    const hasValue = max > 0;
    if (!hasValue) {
      max = 1;
    }

    // 网格
    ctx.strokeStyle = '#EDEFEE';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 3; i++) {
      const y = padTop + innerH * i / 3;
      ctx.beginPath();
      ctx.moveTo(padLeft, y);
      ctx.lineTo(w - padRight, y);
      ctx.stroke();
    }

    const slot = innerW / n;
    const barW = Math.max(8, Math.min(24, slot * 0.5));
    const progress = Math.max(0, Math.min(1, progressIn));
    // 逐根错峰生长：第 i 根延后 (i/(n-1))*35% 出发，ease-out 收尾，柱子按顺序"长"起来
    const stagger = 0.35;
    const span = 1 - stagger;
    for (let i = 0; i < n; i++) {
      const val = values[i];
      const delay = n > 1 ? (i / (n - 1)) * stagger : 0;
      const local = Math.max(0, Math.min(1, (progress - delay) / span));
      const grown = 1 - Math.pow(1 - local, 3);
      const bh = hasValue ? (val / max) * innerH * grown : 0;
      const cx = padLeft + slot * i + slot / 2;
      const x = cx - barW / 2;
      const y = baseY - bh;
      const color = i < colors.length ? colors[i] : '#2F9E68';

      // 底槽：即使数值为 0 也画，作为"这一格有数据"的视觉占位
      ctx.fillStyle = alphaColor(color, 0.16);
      ctx.beginPath();
      ctx.moveTo(x, baseY);
      ctx.lineTo(x, padTop);
      ctx.lineTo(x + barW, padTop);
      ctx.lineTo(x + barW, baseY);
      ctx.closePath();
      ctx.fill();

      // 圆角实柱
      if (bh > 0.5) {
        ctx.fillStyle = color;
        const r = Math.min(4, barW / 2, bh);
        ctx.beginPath();
        ctx.moveTo(x, baseY);
        ctx.lineTo(x, y + r);
        ctx.arcTo(x, y, x + r, y, r);
        ctx.lineTo(x + barW - r, y);
        ctx.arcTo(x + barW, y, x + barW, y + r, r);
        ctx.lineTo(x + barW, baseY);
        ctx.closePath();
        ctx.fill();
      }
    }
  }
}

/** 环形图：用于行为占比 */
export class RingPainter {
  draw(ctx: CanvasRenderingContext2D, w: number, h: number,
    values: number[], colors: string[], centerTop: string, centerBottom: string,
    progressIn: number = 1): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2;
    const cy = h / 2;
    const outer = Math.min(w, h) / 2 - 6;
    const inner = outer * 0.63;

    let total = 0;
    for (let i = 0; i < values.length; i++) {
      total += values[i];
    }

    if (total <= 0) {
      ctx.beginPath();
      ctx.arc(cx, cy, (outer + inner) / 2, 0, Math.PI * 2);
      ctx.lineWidth = outer - inner;
      ctx.strokeStyle = '#EFF1F0';
      ctx.stroke();
      ctx.fillStyle = '#A8B0AD';
      ctx.font = '12px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('暂无数据', cx, cy + 4);
      return;
    }

    // 浅色底环：动画时先有"跑道"，扇区再从 12 点方向顺时针扫出来
    ctx.beginPath();
    ctx.arc(cx, cy, (outer + inner) / 2, 0, Math.PI * 2);
    ctx.lineWidth = outer - inner;
    ctx.strokeStyle = '#F1F4F2';
    ctx.stroke();

    const progress = Math.max(0, Math.min(1, progressIn));
    const limit = -Math.PI / 2 + Math.PI * 2 * progress;

    let angle = -Math.PI / 2;
    for (let i = 0; i < values.length; i++) {
      const v = values[i];
      if (v <= 0) {
        continue;
      }
      if (angle >= limit) {
        break;
      }
      const sweep = (v / total) * Math.PI * 2;
      const color = i < colors.length ? colors[i] : '#2F9E68';
      ctx.beginPath();
      ctx.arc(cx, cy, (outer + inner) / 2, angle, Math.min(angle + sweep, limit));
      ctx.lineWidth = outer - inner;
      ctx.strokeStyle = color;
      ctx.lineCap = 'butt';
      ctx.stroke();
      angle += sweep;
    }

    ctx.textAlign = 'center';
    ctx.fillStyle = '#22302B';
    ctx.font = `bold ${Math.round(outer / 3.6)}px sans-serif`;
    ctx.fillText(centerTop, cx, cy + 2);
    ctx.fillStyle = '#8A9490';
    ctx.font = `${Math.round(outer / 6)}px sans-serif`;
    ctx.fillText(centerBottom, cx, cy + Math.round(outer / 4));
  }
}

/**
 * 呼吸曲线动效绘制器（当前未挂载）。
 * 账本首页已改为「记录节奏」点阵，不再需要会动的画布；这里保留绘制器，
 * 需要"会动的曲线"时（例如给趋势详情弹层做情感化版本）可直接复用。
 */
export class CarbonFlowPainter {
  draw(ctx: CanvasRenderingContext2D, w: number, h: number, data: DayValue[], phase: number,
    accent: string = '#38A874', accentDark: string = '#217A4F'): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const padLeft = 12;
    const padRight = 12;
    const padTop = 14;
    const padBottom = 22;
    const innerW = Math.max(10, w - padLeft - padRight);
    const innerH = Math.max(10, h - padTop - padBottom);
    const baseY = padTop + innerH;

    const n = data.length;
    let max = 0;
    for (let i = 0; i < n; i++) {
      if (data[i].value > max) {
        max = data[i].value;
      }
    }
    const hasValue = max > 0;
    if (max <= 0) {
      max = 1;
    }

    // 底部虚线基准
    ctx.strokeStyle = '#E3EDE7';
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 5]);
    ctx.beginPath();
    ctx.moveTo(padLeft, baseY);
    ctx.lineTo(w - padRight, baseY);
    ctx.stroke();
    ctx.setLineDash([]);

    // 点位：数值映射到 8%~82% 高度，再叠加轻微呼吸偏移
    const count = n > 0 ? n : 1;
    const gap = count > 1 ? innerW / (count - 1) : 0;
    const pts: number[][] = [];
    for (let i = 0; i < count; i++) {
      const value = n > 0 ? data[i].value : 0;
      const x = count > 1 ? padLeft + gap * i : padLeft + innerW / 2;
      const ratio = hasValue ? value / max : 0.32;
      const breathe = Math.sin(phase * 0.8 + i * 0.9) * 2.2;
      const y = baseY - (0.08 + ratio * 0.74) * innerH + breathe;
      pts.push([x, y]);
    }

    // 面积渐变
    const areaGrad = ctx.createLinearGradient(0, padTop, 0, baseY);
    areaGrad.addColorStop(0, alphaColor(accent, 0.22));
    areaGrad.addColorStop(1, alphaColor(accent, 0.01));
    ctx.beginPath();
    ctx.moveTo(pts[0][0], baseY);
    this.traceCurve(ctx, pts);
    ctx.lineTo(pts[count - 1][0], baseY);
    ctx.closePath();
    ctx.fillStyle = areaGrad;
    ctx.fill();

    // 主曲线
    const lineGrad = ctx.createLinearGradient(padLeft, 0, w - padRight, 0);
    lineGrad.addColorStop(0, alphaColor(accent, 0.55));
    lineGrad.addColorStop(0.55, accent);
    lineGrad.addColorStop(1, accentDark);
    ctx.beginPath();
    ctx.moveTo(pts[0][0], pts[0][1]);
    this.traceCurve(ctx, pts);
    ctx.strokeStyle = lineGrad;
    ctx.lineWidth = 2.6;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();

    // 沿曲线移动的光点
    const total = this.pathLength(pts);
    if (total > 1) {
      for (let k = 0; k < 6; k++) {
        const at = ((phase * 0.16 + k / 6) % 1) * total;
        const p = this.pointAt(pts, at);
        ctx.beginPath();
        ctx.arc(p[0], p[1], 6.5, 0, Math.PI * 2);
        ctx.fillStyle = alphaColor(accent, 0.13);
        ctx.fill();
        ctx.beginPath();
        ctx.arc(p[0], p[1], 2.4, 0, Math.PI * 2);
        ctx.fillStyle = '#FFFFFF';
        ctx.fill();
        ctx.strokeStyle = accent;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }
    }

    // 末端脉冲，强调"最新一笔"
    const last = pts[count - 1];
    const pulse = (Math.sin(phase * 2.2) + 1) / 2;
    ctx.beginPath();
    ctx.arc(last[0], last[1], 7 + pulse * 7, 0, Math.PI * 2);
    ctx.fillStyle = alphaColor(accent, 0.08 + pulse * 0.10);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(last[0], last[1], 4, 0, Math.PI * 2);
    ctx.fillStyle = '#FFFFFF';
    ctx.fill();
    ctx.strokeStyle = accentDark;
    ctx.lineWidth = 2;
    ctx.stroke();

    // 上升的小气泡
    for (let i = 0; i < 9; i++) {
      const seed = (i * 73) % 97 / 97;
      const speed = 0.6 + (i % 4) * 0.35;
      const cycle = (phase * speed * 0.08 + i * 0.13) % 1;
      const x = padLeft + seed * innerW + Math.sin(phase * 0.7 + i) * 3;
      const y = baseY - cycle * innerH;
      ctx.globalAlpha = 0.22 * (1 - cycle);
      ctx.beginPath();
      ctx.arc(x, y, 1.2 + (i % 3) * 0.5, 0, Math.PI * 2);
      ctx.fillStyle = accent;
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // 日期标签
    if (n > 0) {
      ctx.fillStyle = '#8A9490';
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'center';
      const every = count > 7 ? Math.ceil(count / 7) : 1;
      for (let i = 0; i < n; i++) {
        if (i % every !== 0 && i !== n - 1) {
          continue;
        }
        const tx = Math.min(Math.max(pts[i][0], 18), w - 18);
        ctx.fillText(data[i].label, tx, h - 6);
      }
    }
  }

  /** 用二次贝塞尔把折线抹平，避免硬拐角；调用前请自行 moveTo 到首点 */
  private traceCurve(ctx: CanvasRenderingContext2D, pts: number[][]): void {
    ctx.lineTo(pts[0][0], pts[0][1]);
    for (let i = 1; i < pts.length - 1; i++) {
      const mx = (pts[i][0] + pts[i + 1][0]) / 2;
      const my = (pts[i][1] + pts[i + 1][1]) / 2;
      ctx.quadraticCurveTo(pts[i][0], pts[i][1], mx, my);
    }
    const last = pts[pts.length - 1];
    ctx.quadraticCurveTo(last[0], last[1], last[0], last[1]);
  }

  private pathLength(pts: number[][]): number {
    let total = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      const dx = pts[i + 1][0] - pts[i][0];
      const dy = pts[i + 1][1] - pts[i][1];
      total += Math.sqrt(dx * dx + dy * dy);
    }
    return total;
  }

  private pointAt(pts: number[][], dist: number): number[] {
    let left = dist;
    for (let i = 0; i < pts.length - 1; i++) {
      const dx = pts[i + 1][0] - pts[i][0];
      const dy = pts[i + 1][1] - pts[i][1];
      const seg = Math.sqrt(dx * dx + dy * dy);
      if (seg <= 0) {
        continue;
      }
      if (left <= seg) {
        const t = left / seg;
        return [pts[i][0] + dx * t, pts[i][1] + dy * t];
      }
      left -= seg;
    }
    const last = pts[pts.length - 1];
    return [last[0], last[1]];
  }
}

/** 绘制器单例。页面在数据变化后主动调用 repaintXxxChart()，不依赖画布生命周期回调 */
export const linePainter: LinePainter = new LinePainter();
export const barPainter: BarPainter = new BarPainter();
export const ringPainter: RingPainter = new RingPainter();
export const flowPainter: CarbonFlowPainter = new CarbonFlowPainter();

/**
 * 画布尺寸缓存：key 由页面固定（如 'home_line'、'chart_bar'）。
 * onAreaChange 记下真实布局宽高，后续 repaint 直接用；
 * 不要用 "数据长度/数据版本" 拼 key —— 那会让重绘时查不到尺寸而画不出来。
 */
const sizeMap: Map<string, number[]> = new Map<string, number[]>();

function setSize(key: string, w: number, h: number): void {
  sizeMap.set(key, [w, h]);
}

function cachedSize(key: string): number[] {
  const v = sizeMap.get(key);
  return v === undefined ? [0, 0] : v;
}

/** 数据变化后重绘折线图（尺寸未知时跳过，等 onAreaChange 首绘）；progress 用于入场动画 */
export function repaintLineChart(key: string, ctx: CanvasRenderingContext2D,
  data: DayValue[], accent: string, progress: number = 1): void {
  const s = cachedSize(key);
  if (s[0] > 0 && s[1] > 0) {
    linePainter.draw(ctx, s[0], s[1], data, accent, progress);
  }
}

/** 数据变化后重绘柱状图 */
export function repaintBarChart(key: string, ctx: CanvasRenderingContext2D,
  labels: string[], values: number[], colors: string[], progress: number = 1): void {
  const s = cachedSize(key);
  if (s[0] > 0 && s[1] > 0) {
    barPainter.draw(ctx, s[0], s[1], labels, values, colors, progress);
  }
}

/** 数据变化后重绘环形图 */
export function repaintRingChart(key: string, ctx: CanvasRenderingContext2D,
  values: number[], colors: string[], centerTop: string, centerBottom: string,
  progress: number = 1): void {
  const s = cachedSize(key);
  if (s[0] > 0 && s[1] > 0) {
    ringPainter.draw(ctx, s[0], s[1], values, colors, centerTop, centerBottom, progress);
  }
}

/** 折线面积图 */
@Builder
export function LineChart(key: string, dataProvider: () => DayValue[], accent: string, chartHeight: number,
  ctx: CanvasRenderingContext2D, progressProvider: () => number) {
  Canvas(ctx)
    .width('100%')
    .height(chartHeight)
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = Number(newV.width);
      // 高度用调用方声明的固定值，不信任 onAreaChange 的高度：
      // 滚动/切 Tab 时它可能上报 0 或裁剪后的高度，写进缓存会让后续 repaint 全部跳过。
      if (w <= 0) {
        return;
      }
      setSize(key, w, chartHeight);
      // 通过 provider 取数据：@Builder 的值参数会被长期缓存，直接传数组时
      // onAreaChange/onReady 会拿旧数组重画，把页面刚重绘的新图覆盖回旧数据。
      linePainter.draw(ctx, w, chartHeight, dataProvider(), accent, progressProvider());
    })
    .onReady(() => {
      // onReady 可能早于首次 onAreaChange：有缓存尺寸就补画一次（切 Tab 回来时同样受益）
      const s = cachedSize(key);
      if (s[0] > 0 && s[1] > 0) {
        linePainter.draw(ctx, s[0], s[1], dataProvider(), accent, progressProvider());
      }
    })
}

/** 柱状图 */
@Builder
export function BarChart(key: string, labelsProvider: () => string[], valuesProvider: () => number[],
  colorsProvider: () => string[], chartHeight: number, ctx: CanvasRenderingContext2D,
  progressProvider: () => number) {
  Canvas(ctx)
    .width('100%')
    .height(chartHeight)
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = Number(newV.width);
      if (w <= 0) {
        return;
      }
      setSize(key, w, chartHeight);
      barPainter.draw(ctx, w, chartHeight, labelsProvider(), valuesProvider(), colorsProvider(),
        progressProvider());
    })
    .onReady(() => {
      const s = cachedSize(key);
      if (s[0] > 0 && s[1] > 0) {
        barPainter.draw(ctx, s[0], s[1], labelsProvider(), valuesProvider(), colorsProvider(),
          progressProvider());
      }
    })
}

/** 环形图 */
@Builder
export function RingChart(key: string, valuesProvider: () => number[], colorsProvider: () => string[],
  centerTopProvider: () => string, centerBottom: string, ringSize: number,
  ctx: CanvasRenderingContext2D, progressProvider: () => number) {
  Canvas(ctx)
    .width(ringSize)
    .height(ringSize)
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = Number(newV.width);
      if (w <= 0) {
        return;
      }
      // 环形图尺寸由调用方的 ringSize 决定，同样不用可能被裁剪的 area 高度
      setSize(key, ringSize, ringSize);
      ringPainter.draw(ctx, ringSize, ringSize, valuesProvider(), colorsProvider(),
        centerTopProvider(), centerBottom, progressProvider());
    })
    .onReady(() => {
      const s = cachedSize(key);
      if (s[0] > 0 && s[1] > 0) {
        ringPainter.draw(ctx, s[0], s[1], valuesProvider(), colorsProvider(),
          centerTopProvider(), centerBottom, progressProvider());
      }
    })
}
