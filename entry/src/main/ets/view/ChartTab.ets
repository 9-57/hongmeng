import { CarbonRecord, Category, CategoryValue, DayValue, Summary } from '../model/CarbonModels';
import { CATEGORIES } from '../model/CarbonData';
import { carbonStore } from '../viewmodel/CarbonStore';
import { bumpDataVersion, fmtKg, round } from '../common/Utils';
import { BarChart, LineChart, RingChart, repaintBarChart, repaintLineChart, repaintRingChart } from '../components/Charts';
import { DialogUtil } from '../common/DialogUtil';
import { Palette } from '../common/Theme';
import { EmptyBox, ProgressBar } from '../common/Widgets';

/** 维度选项 */
class DimOption {
  id: string = '';
  name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

const DIMS: DimOption[] = [
  new DimOption('day', '日'),
  new DimOption('week', '周'),
  new DimOption('month', '月'),
  new DimOption('year', '年')
];

const RANGES: DimOption[] = [
  new DimOption('all', '全部'),
  new DimOption('month', '本月'),
  new DimOption('week', '本周')
];

/** 三块画布的稳定 key：不能用数据长度拼 key，否则重绘时查不到尺寸 */
const LINE_KEY = 'chart_line';
const BAR_KEY = 'chart_bar';
const RING_KEY = 'chart_ring';

/** 入场动画时长（ms）：三张图共用一条时间轴，各自的画法不同 */
const ANIM_MS = 780;

@Component
export struct ChartTab {
  /** 由主页面传入的刷新令牌，值变化即重新取数 */
  @Prop @Watch('onTokenChange') token: number = 0;
  /** 当前皮肤：主色都经下面的方法取色，读它才会在切换后重绘 */
  @StorageProp('skinId') skinId: string = 'original';
  @State @Watch('onDimChange') dim: string = 'day';
  @State series: DayValue[] = [];
  @State cats: CategoryValue[] = [];
  @State @Watch('onRangeChange') range: string = 'month';
  @State filterCat: string = 'all';
  @State filterRange: string = 'all';
  @State records: CarbonRecord[] = [];
  @State summary: Summary = new Summary();
  @State peakText: string = '';
  @State avgText: string = '0';
  @State totalText: string = '0';
  @State barLabelArr: string[] = [];
  @State barValueArr: number[] = [];
  @State barColorArr: string[] = [];
  /** TOP5 结果缓存：原来 build 里连调两次 topActivities()，每次都全量聚合 */
  @State ranks: ActivityRank[] = [];
  private lineSet: RenderingContextSettings = new RenderingContextSettings(true);
  private lineCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.lineSet);
  private barSet: RenderingContextSettings = new RenderingContextSettings(true);
  private barCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.barSet);
  private ringSet: RenderingContextSettings = new RenderingContextSettings(true);
  private ringCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.ringSet);
  /** 延迟重绘：切 Tab 瞬间画布还不可见，立即绘制会被丢弃 */
  private repaintTimer: number = -1;
  /** 入场动画进度 0~1：折线从左往右画、柱子依次长高、环从 12 点扫出、中心数字跟着累加 */
  private animPhase: number = 1;
  private animTimer: number = -1;
  private animStart: number = 0;

  p(): string {
    return Palette.skinById(this.skinId).primary;
  }

  pd(): string {
    return Palette.skinById(this.skinId).primaryDark;
  }

  pl(): string {
    return Palette.skinById(this.skinId).primaryLight;
  }

  aboutToAppear(): void {
    this.refresh();
    // 存储读取是异步的，首次进入时若还没读完，读完后再刷新一次
    carbonStore.ensureLoaded(() => {
      this.refresh();
    });
  }

  aboutToDisappear(): void {
    if (this.repaintTimer !== -1) {
      clearTimeout(this.repaintTimer);
      this.repaintTimer = -1;
    }
    this.stopAnim();
  }

  /** 入场动画：一条时间轴驱动三张图，每帧把进度写进 animPhase 再主动重绘 */
  playAnim(): void {
    this.stopAnim();
    this.animPhase = 0;
    this.animStart = Date.now();
    this.repaint();
    this.animTimer = setInterval(() => {
      const t = (Date.now() - this.animStart) / ANIM_MS;
      this.animPhase = t >= 1 ? 1 : t;
      this.repaint();
      if (t >= 1) {
        this.stopAnim();
      }
    }, 20);
  }

  stopAnim(): void {
    if (this.animTimer !== -1) {
      clearInterval(this.animTimer);
      this.animTimer = -1;
    }
    this.animPhase = 1;
  }

  onTokenChange(): void {
    this.refresh();
  }

  /** range 变化由 @Watch 统一驱动，点击处只改状态，避免重复刷新 */
  onRangeChange(): void {
    this.refresh();
  }

  onDimChange(): void {
    this.refresh();
  }

  refresh(): void {
    this.series = carbonStore.seriesBy(this.dim);
    this.cats = carbonStore.categorySeries(this.range);
    this.summary = carbonStore.getSummary();
    // 图表数据在取数时就定型，避免在 @Builder 里反复调方法导致重绘时机不确定
    // 用完整分类名：截成两字会让「绿色出行」和「绿色消费」都变成「绿色」，柱状图分不清
    this.barLabelArr = this.cats.map((c: CategoryValue) => c.name);
    this.barValueArr = this.cats.map((c: CategoryValue) => c.value);
    this.barColorArr = this.cats.map((c: CategoryValue) => c.color);

    let peak = 0;
    let sum = 0;
    let peakLabel = '-';
    for (const d of this.series) {
      sum += d.value;
      if (d.value > peak) {
        peak = d.value;
        peakLabel = d.label;
      }
    }
    // 全为 0 时不显示 "- 0" 这种占位，直接给一个破折号
    this.peakText = peak > 0 ? `${peakLabel} ${fmtKg(peak)}` : '—';
    this.avgText = fmtKg(round(sum / Math.max(1, this.series.length), 2));
    this.totalText = fmtKg(sum);

    this.refreshHistory();
    // 取完数先画一帧 0 进度，再启动入场动画；40ms 后的补绘复用当前进度，
    // 兜住"切 Tab 瞬间画布还没测量完、绘制被丢弃"的情况
    this.playAnim();
    this.scheduleRepaint();
  }

  scheduleRepaint(): void {
    if (this.repaintTimer !== -1) {
      clearTimeout(this.repaintTimer);
    }
    this.repaintTimer = setTimeout(() => {
      this.repaintTimer = -1;
      this.repaint();
    }, 40);
  }

  /**
   * 主动重绘三块画布。
   * Canvas 只在 onReady/onAreaChange 时执行绘制，切日/周/月/年或切换统计区间时
   * 这两个回调都不会触发；不主动重画，用户看到的就是"点了选项图没动"。
   */
  repaint(): void {
    repaintLineChart(LINE_KEY, this.lineCtx, this.series, this.p(), this.animPhase);
    repaintBarChart(BAR_KEY, this.barCtx, this.barLabelArr, this.barValueArr, this.barColorArr,
      this.animPhase);
    // 无数据时环形画布不在树上，避免对已销毁的画布下绘制指令
    if (this.hasData()) {
      // 中心数字跟着扫过的角度累加，扫满时正好等于合计
      repaintRingChart(RING_KEY, this.ringCtx, this.barValueArr, this.barColorArr,
        fmtKg(this.sumOfCats() * this.animPhase), 'kg CO₂e', this.animPhase);
    }
  }

  /** 历史记录区变化时只重算记录与排行，不必连带重算三块图表 */
  refreshHistory(): void {
    this.records = carbonStore.filterRecords(this.filterRange, this.filterCat);
    this.ranks = this.buildRanks();
  }

  @Styles
  cardStyle() {
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(18)
    .shadow({ radius: 14, color: '#081F3D12', offsetY: 4 })
  }

  /**
   * 分段控件。
   * 注意 1：这里不能写成 width('100%') —— 放在带 Blank 的 Row 里会被压成 0 宽，
   * 用户就会觉得"点了没反应"。改为按选项数量自适应的固定宽度。
   * 注意 2：`kind` 必须是常量（'dim'/'range'），不能把 this.dim 当参数传进来。
   * @Builder 的值参数只在构建时求值一次，传 dim 会导致高亮永远停在下标 0；
   * 高亮状态必须在属性表达式里直接读 this.dim/this.range 才能建立依赖。
   */
  @Builder
  SegControl(options: DimOption[], kind: string) {
    Row({ space: 4 }) {
      ForEach(options, (o: DimOption) => {
        Text(o.name)
          .fontSize(12)
          .fontColor(this.segActive(kind, o.id) ? '#FFFFFF' : Palette.textSub)
          .fontWeight(this.segActive(kind, o.id) ? FontWeight.Medium : FontWeight.Normal)
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 44 })
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.segActive(kind, o.id) ? this.p() : Color.Transparent)
          .borderRadius(8)
          .onClick(() => {
            this.onSegClick(kind, o.id);
          })
      }, (o: DimOption) => o.id)
    }
    .padding(3)
    .backgroundColor('#F0F3F2')
    .borderRadius(10)
  }

  segActive(kind: string, id: string): boolean {
    if (kind === 'dim') {
      return this.dim === id;
    }
    return this.range === id;
  }

  onSegClick(kind: string, id: string): void {
    if (kind === 'dim') {
      if (this.dim !== id) {
        this.dim = id;
      }
      return;
    }
    if (this.range !== id) {
      this.range = id;
    }
  }

  /** 统计值同样不能通过 @Builder 值参数传，否则切换维度后数字不刷新 */
  statText(kind: string): string {
    if (kind === 'total') {
      return this.totalText;
    }
    if (kind === 'peak') {
      return this.peakText;
    }
    return this.avgText;
  }

  /** 圆点强调色同样在方法里取，避免 @Builder 值参数缓存导致停在旧皮肤 */
  statAccent(kind: string): string {
    if (kind === 'total') {
      return this.p();
    }
    if (kind === 'peak') {
      return Palette.blue;
    }
    return Palette.purple;
  }

  /** 卡片标题行：图标 + 标题 + 右侧提示 */
  @Builder
  CardHead(icon: string, title: string, rightKind: string) {
    Row({ space: 6 }) {
      Text(icon)
        .fontSize(14)
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
      Blank()
      Text(this.headRight(rightKind))
        .fontSize(10)
        .fontColor(Palette.textLight)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  headRight(kind: string): string {
    if (kind === 'unit') {
      return '单位 kg CO₂e';
    }
    if (kind === 'bar') {
      return `共 ${this.cats.length} 类`;
    }
    if (kind === 'ring') {
      return this.hasData() ? `合计 ${fmtKg(this.sumOfCats())} kg` : '暂无数据';
    }
    if (kind === 'top') {
      return `近 ${this.records.length} 条`;
    }
    return `${this.records.length} 条`;
  }

  dimName(): string {
    for (const d of DIMS) {
      if (d.id === this.dim) {
        return d.name;
      }
    }
    return '日';
  }

  /**
   * 顶部总览卡：浅色报表风。
   * 「我的」页的低碳同学资料卡是深绿渐变，数据页不再用同款底，
   * 改成白底 + 大号深绿数字 + 浅色分段控件，靠排版而不是色块来立住头卡。
   */
  @Builder
  HeroCard() {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Row()
            .width(4)
            .height(15)
            .backgroundColor(this.p())
            .borderRadius(2)
          Text('减排看板')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Blank()
          Text(`按${this.dimName()}统计`)
            .fontSize(10)
            .fontColor(this.pd())
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(this.pl())
            .borderRadius(7)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('单位 kg CO₂e')
          .fontSize(11)
          .fontColor(Palette.textLight)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row({ space: 4 }) {
        Text(this.totalText)
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pd())
        Text('kg CO₂e')
          .fontSize(11)
          .fontColor(Palette.textSub)
          .margin({ bottom: 9 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Row({ space: 8 }) {
        Text(`日均 ${this.avgText} kg`)
          .fontSize(10)
          .fontColor(Palette.textSub)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ top: 6, bottom: 6 })
          .backgroundColor(Palette.card)
          .borderRadius(9)
          .border({ width: 1, color: Palette.line })

        Text(`最高 ${this.peakText}`)
          .fontSize(10)
          .fontColor(Palette.textSub)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ top: 6, bottom: 6 })
          .backgroundColor(Palette.card)
          .borderRadius(9)
          .border({ width: 1, color: Palette.line })
      }
      .width('100%')

      this.SegLightWide(DIMS, 'dim')
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .linearGradient({ angle: 165, colors: [['#FFFFFF', 0], [this.pl(), 1]] })
    .border({ width: 1, color: Palette.line })
    .shadow({ radius: 14, color: '#081F3D12', offsetY: 4 })
  }

  /** 浅色分段控件：浅灰绿轨道 + 主色高亮，跟深色卡上的白底控件区分 */
  @Builder
  SegLightWide(options: DimOption[], kind: string) {
    Row({ space: 4 }) {
      ForEach(options, (o: DimOption) => {
        Row() {
          Text(o.name)
            .fontSize(12)
            .fontColor(this.segActive(kind, o.id) ? '#FFFFFF' : Palette.textSub)
            .fontWeight(this.segActive(kind, o.id) ? FontWeight.Medium : FontWeight.Normal)
        }
        .layoutWeight(1)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.segActive(kind, o.id) ? this.p() : Color.Transparent)
        .borderRadius(9)
        .onClick(() => {
          this.onSegClick(kind, o.id);
        })
      }, (o: DimOption) => `seg_${kind}_${o.id}_${this.segActive(kind, o.id)}`)
    }
    .width('100%')
    .padding(4)
    .backgroundColor(Palette.card)
    .border({ width: 1, color: Palette.line })
    .borderRadius(12)
  }

  /** 趋势卡底部的小统计块 */
  @Builder
  StatBlock(label: string, kind: string) {
    Column({ space: 3 }) {
      Text(this.statText(kind))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 4 }) {
        Row()
          .width(5)
          .height(5)
          .backgroundColor(this.statAccent(kind))
          .borderRadius(3)
        Text(label)
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .alignItems(VerticalAlign.Center)
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#F6F9F7')
    .borderRadius(12)
  }

  /** 前三名用金银铜色，其余用浅灰 */
  rankBg(index: number): string {
    if (index === 0) {
      return '#E8B33A';
    }
    if (index === 1) {
      return '#AAB6B2';
    }
    if (index === 2) {
      return '#C98A5A';
    }
    return '#F0F3F2';
  }

  rankFg(index: number): string {
    return index < 3 ? '#FFFFFF' : Palette.textLight;
  }

  topValue(): number {
    let max = 0;
    for (const r of this.ranks) {
      if (r.value > max) {
        max = r.value;
      }
    }
    return max;
  }

  rankRatio(value: number): number {
    const max = this.topValue();
    return max <= 0 ? 0 : value / max;
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        this.HeroCard()

        // ===== 趋势卡 =====
        Column({ space: 12 }) {
          this.CardHead('📈', '减排趋势', 'unit')
          LineChart(LINE_KEY, () => this.series, this.p(), 180, this.lineCtx, () => this.animPhase)

          Row({ space: 8 }) {
            this.StatBlock('总计', 'total')
            this.StatBlock('最高', 'peak')
            this.StatBlock('平均', 'avg')
          }
          .width('100%')
        }
        .cardStyle()
        // 滚动/切 Tab 回来后按当前数据补画，避免画布内容丢失后一直空白
        .onVisibleAreaChange([0.0, 0.01], (isVisible: boolean, ratio: number) => {
          if (isVisible && ratio > 0) {
            this.repaint();
          }
        })

        // ===== 分类柱状 =====
        Column({ space: 12 }) {
          this.CardHead('📊', '各类行为减排对比', 'bar')

          // 单独占一行：放在标题行里会被 Blank 挤到没有点击区域
          Row() {
            this.SegControl(RANGES, 'range')
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)

          if (this.barValueArr.length > 0) {
            BarChart(BAR_KEY, () => this.barLabelArr, () => this.barValueArr,
              () => this.barColorArr, 180, this.barCtx, () => this.animPhase)
            // 分类名用原生 Text 渲染，不用 Canvas 画文字：
            // Canvas 的 fillText 在预览器里字体/基线不稳，曾出现"柱子在、字没有"。
            // 用 Row + 等分布局，保证每根柱子下方正好对齐一个名字。
            Row() {
              ForEach(this.barLabelArr, (name: string, i: number) => {
                Column({ space: 2 }) {
                  Text(name)
                    .fontSize(11)
                    .fontColor(Palette.textSub)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(fmtKg(this.barValueArr[i]))
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text)
                    .maxLines(1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }, (name: string, i: number) => `bl_${this.range}_${i}_${name}_${this.barValueArr[i]}`)
            }
            .width('100%')
          } else {
            EmptyBox('📊', '这段时间还没有数据', '')
          }
        }
        .cardStyle()
        .onVisibleAreaChange([0.0, 0.01], (isVisible: boolean, ratio: number) => {
          if (isVisible && ratio > 0) {
            this.repaint();
          }
        })

        // ===== 环形占比 =====
        Column({ space: 12 }) {
          this.CardHead('🍩', '各类行为占比', 'ring')

          if (this.hasData()) {
            Row({ space: 12 }) {
              RingChart(RING_KEY, () => this.barValueArr, () => this.barColorArr,
                () => fmtKg(this.sumOfCats() * this.animPhase), 'kg CO₂e', 148, this.ringCtx,
                () => this.animPhase)

              Column({ space: 9 }) {
                ForEach(this.cats.filter((c: CategoryValue) => c.value > 0), (cv: CategoryValue) => {
                  Column({ space: 5 }) {
                    Row({ space: 6 }) {
                      Row()
                        .width(8)
                        .height(8)
                        .backgroundColor(cv.color)
                        .borderRadius(4)
                      Text(cv.name)
                        .fontSize(11)
                        .fontColor(Palette.textSub)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${round(cv.ratio * 100, 1)}%`)
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Palette.text)
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)

                    ProgressBar({ progress: cv.ratio, color: cv.color, barHeight: 4 })
                  }
                  .width('100%')
                }, (cv: CategoryValue) => `${cv.categoryId}_${cv.value}_${round(cv.ratio, 3)}`)
              }
              .layoutWeight(1)
            }
            .width('100%')
          } else {
            EmptyBox('📊', '这段时间还没有数据', '')
          }
        }
        .cardStyle()
        .onVisibleAreaChange([0.0, 0.01], (isVisible: boolean, ratio: number) => {
          if (isVisible && ratio > 0) {
            this.repaint();
          }
        })

        // ===== 行为排行 =====
        Column({ space: 12 }) {
          this.CardHead('🏆', '最常记的低碳行为 TOP5', 'top')

          if (this.ranks.length === 0) {
            EmptyBox('🔍', '暂无记录', '')
          } else {
            ForEach(this.ranks, (item: ActivityRank, index: number) => {
              Row({ space: 10 }) {
                Text(`${index + 1}`)
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.rankFg(index))
                  .width(22)
                  .height(22)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.rankBg(index))
                  .borderRadius(11)

                Text(item.icon)
                  .fontSize(15)

                Column({ space: 5 }) {
                  Row({ space: 6 }) {
                    Text(item.name)
                      .fontSize(12)
                      .fontColor(Palette.text)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${item.count} 次`)
                      .fontSize(10)
                      .fontColor(Palette.textLight)
                  }
                  .width('100%')

                  ProgressBar({ progress: this.rankRatio(item.value), color: this.p(), barHeight: 4 })
                }
                .layoutWeight(1)

                Text(`${fmtKg(item.value)} kg`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.p())
                  .width(66)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }, (item: ActivityRank) => `${item.activityId}_${item.count}_${item.value}`)
          }
        }
        .cardStyle()

        // ===== 历史记录 =====
        Column({ space: 12 }) {
          this.CardHead('📝', '历史记录', 'history')

          Row() {
            Row({ space: 4 }) {
              ForEach(RANGES, (r: DimOption) => {
                Text(r.name)
                  .fontSize(11)
                  .fontColor(this.filterRange === r.id ? this.p() : Palette.textSub)
                  .fontWeight(this.filterRange === r.id ? FontWeight.Medium : FontWeight.Normal)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(this.filterRange === r.id ? '#FFFFFF' : Color.Transparent)
                  .borderRadius(9)
                  .onClick(() => {
                    if (this.filterRange === r.id) {
                      return;
                    }
                    this.filterRange = r.id;
                    this.refreshHistory();
                  })
              }, (r: DimOption) => `hist_range_${r.id}_${this.filterRange === r.id}`)
            }
            .padding(4)
            .backgroundColor('#F4F7F5')
            .borderRadius(12)
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)

          Scroll() {
            Row({ space: 6 }) {
              Text('全部')
                .fontSize(11)
                .fontColor(this.filterCat === 'all' ? this.p() : Palette.textSub)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.filterCat === 'all' ? this.pl() : '#F4F7F5')
                .borderRadius(9)
                .onClick(() => {
                  if (this.filterCat === 'all') {
                    return;
                  }
                  this.filterCat = 'all';
                  this.refreshHistory();
                })
              ForEach(CATEGORIES, (c: Category) => {
                Text(`${c.icon} ${c.name}`)
                  .fontSize(11)
                  .fontColor(this.filterCat === c.id ? this.p() : Palette.textSub)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(this.filterCat === c.id ? this.pl() : '#F4F7F5')
                  .borderRadius(9)
                  .onClick(() => {
                    if (this.filterCat === c.id) {
                      return;
                    }
                    this.filterCat = c.id;
                    this.refreshHistory();
                  })
              }, (c: Category) => `hist_cat_${c.id}_${this.filterCat === c.id}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

          if (this.records.length === 0) {
            EmptyBox('📭', '没有找到符合条件的记录', '')
          } else {
            ForEach(this.records, (r: CarbonRecord) => {
              Row({ space: 10 }) {
                Text(carbonStore.iconOf(r.activityId))
                  .fontSize(15)
                  .width(32)
                  .height(32)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#F4F7F5')
                  .borderRadius(9)

                Column({ space: 2 }) {
                  Text(r.activityName)
                    .fontSize(13)
                    .fontColor(Palette.text)
                  Text(`${r.date} · ${r.qty} ${r.unit}${r.note.length > 0 ? ' · ' + r.note : ''}`)
                    .fontSize(10)
                    .fontColor(Palette.textLight)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column({ space: 1 }) {
                  Text(`-${r.reduction}`)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.p())
                  Text(`+${r.point}分`)
                    .fontSize(9)
                    .fontColor(Palette.textLight)
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .border({ width: { bottom: 1 }, color: Palette.line })
              .onClick(() => {
                this.confirmDelete(r);
              })
            }, (r: CarbonRecord) => r.id)
          }

          Text('点击任意一条记录可删除')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 2 })
        }
        .cardStyle()
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  sumOfCats(): number {
    let s = 0;
    for (const c of this.cats) {
      s += c.value;
    }
    return round(s, 2);
  }

  hasData(): boolean {
    return this.sumOfCats() > 0;
  }

  buildRanks(): ActivityRank[] {
    const map = new Map<string, ActivityRank>();
    for (const r of this.records) {
      const old = map.get(r.activityId);
      if (old === undefined) {
        map.set(r.activityId, new ActivityRank(r.activityId, r.activityName,
          carbonStore.iconOf(r.activityId), 1, r.reduction));
      } else {
        old.count += 1;
        old.value = round(old.value + r.reduction, 2);
      }
    }
    const list: ActivityRank[] = [];
    map.forEach((v: ActivityRank) => {
      list.push(v);
    });
    list.sort((a: ActivityRank, b: ActivityRank) => {
      if (b.count !== a.count) {
        return b.count - a.count;
      }
      return b.value - a.value;
    });
    return list.slice(0, 5);
  }

  async confirmDelete(r: CarbonRecord): Promise<void> {
    const ok = await DialogUtil.confirm(this.getUIContext(), '删除这条记录？',
      `${r.activityName} · ${r.reduction} kg CO₂e，删除后统计会同步更新`, '删除', Palette.danger);
    if (ok) {
      this.doDelete(r.id);
    }
  }

  async doDelete(id: string): Promise<void> {
    await carbonStore.deleteRecord(id);
    bumpDataVersion();
    this.refresh();
    DialogUtil.toast(this.getUIContext(), '已删除');
  }
}

/** 行为排行项 */
class ActivityRank {
  activityId: string = '';
  name: string = '';
  icon: string = '';
  count: number = 0;
  value: number = 0;

  constructor(activityId: string, name: string, icon: string, count: number, value: number) {
    this.activityId = activityId;
    this.name = name;
    this.icon = icon;
    this.count = count;
    this.value = value;
  }
}
