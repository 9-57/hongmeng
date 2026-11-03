import { CarbonRecord, CategoryValue, DayValue, LevelInfo, MonthReview, Summary } from '../model/CarbonModels';
import { carbonStore, BadgeState, TaskState } from '../viewmodel/CarbonStore';
import { bumpDataVersion, fmtKg, formatDate, round, weekLabel } from '../common/Utils';
import { DialogUtil } from '../common/DialogUtil';
import { auth } from '../service/AuthService';
import { requireLogin } from '../service/AccountGate';
import { Palette } from '../common/Theme';
import { ProgressBar, SectionTitle } from '../common/Widgets';
import { Insight } from '../service/InsightService';

/** 日历格：空白格 day = 0；count 是当天记录条数 */
class CalCell {
  day: number = 0;
  date: string = '';
  count: number = 0;
  isToday: boolean = false;
  future: boolean = false;

  constructor(day: number, date: string, count: number, isToday: boolean, future: boolean) {
    this.day = day;
    this.date = date;
    this.count = count;
    this.isToday = isToday;
    this.future = future;
  }
}

/** 日历表头，周一开头，与 weekStart() 的口径一致 */
const WEEK_HEADS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** 全透明色（ARGB 8 位，alpha = 00）；Color.Transparent 是 enum，不能塞进返回 string 的方法 */
const CLEAR_COLOR: string = '#00000000';

@Component
export struct HomeTab {
  /** 由主页面传入的刷新令牌，值变化即重新取数 */
  @Prop @Watch('onTokenChange') token: number = 0;
  /** 由主页面注入的跳转回调：点推荐任务直接切到「记一笔」并选中分类 */
  goRecord: (categoryId: string) => void = () => {};
  /** 当前皮肤：主色都经下面的方法取色，读它才会在切换后重绘 */
  @StorageProp('skinId') skinId: string = 'original';
  @State summary: Summary = new Summary();
  /** 个性化推荐与生活建议（来自 InsightService，按本地记录实时生成） */
  @State insights: Insight[] = [];
  /** 近 7 天每天的记录条数：账本首页讲“记了几笔”，不画减排量曲线 */
  @State rhythm: DayValue[] = [];
  /** 本月日历格（含首尾补白），由 buildCalendar() 一次性算好 */
  @State calCells: CalCell[] = [];
  @State monthLabel: string = '';
  @State tasks: TaskState[] = [];
  @State recentAll: CarbonRecord[] = [];
  @State cats: CategoryValue[] = [];
  @State level: LevelInfo = new LevelInfo();
  @State review: MonthReview = new MonthReview();
  @State goalProgress: number = 0;
  @State monthGoal: number = 30;
  @State badgeGot: number = 0;
  @State badgeTotal: number = 0;
  /** 详情弹层开关与当前查看的方块 */
  @State showDetail: boolean = false;
  @State detailKind: string = '';
  /** 账号登录态：任务奖励属于账号，未登录时领取按钮只做登录引导 */
  @State loggedIn: boolean = false;

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

  onTokenChange(): void {
    this.refresh();
  }

  refresh(): void {
    this.loggedIn = auth.isLoggedIn;
    this.summary = carbonStore.getSummary();
    this.rhythm = carbonStore.dailyCounts(7);
    this.tasks = carbonStore.getDailyTasks();
    this.recentAll = carbonStore.allRecordsDesc().slice(0, 10);
    this.cats = carbonStore.categorySeries('month');
    this.level = carbonStore.levelInfo();
    this.insights = carbonStore.insights();
    this.review = carbonStore.monthReview(0);
    this.monthGoal = carbonStore.monthGoal;
    this.goalProgress = carbonStore.monthGoalProgress();
    const bs = carbonStore.getBadgeStates();
    this.badgeTotal = bs.length;
    this.badgeGot = bs.filter((b: BadgeState) => b.unlocked).length;
    this.buildCalendar();
  }

  /**
   * 生成本月日历格：首尾补空格，让格子按周一对齐。
   * 记录条数直接复用 dailyCounts(今天几号)——它正好覆盖 1 号到今天，
   * 不再为日历单独扫一遍全量记录。
   */
  buildCalendar(): void {
    const now = new Date();
    const year = now.getFullYear();
    const month = now.getMonth();
    const today = now.getDate();
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const firstWeekday = new Date(year, month, 1).getDay();
    const lead = firstWeekday === 0 ? 6 : firstWeekday - 1;

    const counts = carbonStore.dailyCounts(today);
    const map = new Map<string, number>();
    for (const d of counts) {
      map.set(d.date, d.value);
    }

    const cells: CalCell[] = [];
    for (let i = 0; i < lead; i++) {
      cells.push(new CalCell(0, '', 0, false, false));
    }
    for (let day = 1; day <= daysInMonth; day++) {
      const key = formatDate(new Date(year, month, day).getTime());
      const c = map.get(key);
      cells.push(new CalCell(day, key, c === undefined ? 0 : c, day === today, day > today));
    }
    while (cells.length % 7 !== 0) {
      cells.push(new CalCell(0, '', 0, false, false));
    }

    this.calCells = cells;
    this.monthLabel = `${year} 年 ${month + 1} 月`;
  }

  /** 弹层内的白卡 */
  @Styles
  sheetCard() {
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.card)
    .borderRadius(14)
  }

  /** 顶部碳账本卡：记录节奏点阵 + 累计减排大数（不再画 7 天减排曲线） */
  @Builder
  RhythmCard() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('记录节奏')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Row({ space: 6 }) {
            Text(`今天 · ${weekLabel(Date.now())}`)
              .fontSize(11)
              .fontColor(Palette.textLight)
            Text(this.level.code)
              .fontSize(10)
              .fontColor(this.pd())
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(this.pl())
              .borderRadius(6)
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 1 }) {
          Row({ space: 3 }) {
            Text(fmtKg(this.summary.totalReduction))
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pd())
            Text('kg')
              .fontSize(10)
              .fontColor(Palette.textLight)
              .margin({ bottom: 4 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text('累计减排')
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(`近 7 天 · ${this.activeDays()} 天有记录`)
          .fontSize(10)
          .fontColor(Palette.textLight)
        Blank()
        Text(`≈ 种树 ${fmtKg(this.summary.treeCount)} 棵·年`)
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .width('100%')

      Column() {
        this.RhythmStrip()
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
      .backgroundColor('#F7FCF9')
      .borderRadius(14)

      Row({ space: 8 }) {
        this.LightStat('今日', 'today', 'kg')
        this.LightStat('本周', 'week', 'kg')
        this.LightStat('连续', 'streak', '天')
        this.LightStat('积分', 'point', '分')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 14 })
    .backgroundColor(Palette.card)
    .borderRadius(20)
    .border({ width: 1, color: '#E9F2EC' })
    .shadow({ radius: 14, color: '#081F3D12', offsetY: 4 })
  }

  /**
   * 记录节奏点阵：一列一天，点亮一颗 = 记了一笔。
   * 这里刻意不画折线/面积——"减排量曲线"只在数据看板出现，
   * 账本首页回答的是"最近有没有坚持记"，两者别再长成同一张图。
   * 纯原生布局实现，也不用 50ms 定时器重绘画布。
   */
  @Builder
  RhythmStrip() {
    Row({ space: 4 }) {
      ForEach(this.rhythm, (d: DayValue, i: number) => {
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Bottom }) {
            // 轨道：没有记录的日子也留一条浅色竖槽，点阵才不像"凭空浮着的几个点"
            Row()
              .width(3)
              .height(60)
              .borderRadius(2)
              .backgroundColor('#EAF1EC')

            Column({ space: 5 }) {
              ForEach(this.dotSlots(i), (slot: number) => {
                Row()
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.hasRecord(i) ? this.p() : Palette.card)
                  .border({ width: 1, color: this.hasRecord(i) ? this.p() : '#D7E2DC' })
              }, (slot: number) => `dot_${d.date}_${slot}_${d.value}`)
            }
            .height(60)
            .justifyContent(FlexAlign.End)
          }
          .width('100%')
          .height(60)

          Text(d.label)
            .fontSize(10)
            .fontColor(this.isTodayIndex(i) ? this.pd() : Palette.textLight)
            .fontWeight(this.isTodayIndex(i) ? FontWeight.Medium : FontWeight.Normal)
        }
        .layoutWeight(1)
        .padding({ top: 6, bottom: 5 })
        .borderRadius(10)
        .backgroundColor(this.isTodayIndex(i) ? this.pl() : Color.Transparent)
      }, (d: DayValue, i: number) => `rhythm_${d.date}_${d.value}_${i}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }

  /** 一列放几颗点：没记录时放一颗空心点占位；最多 5 颗，再多也只点亮 5 颗 */
  dotSlots(i: number): number[] {
    const count = i >= 0 && i < this.rhythm.length ? this.rhythm[i].value : 0;
    const n = count <= 0 ? 1 : Math.min(count, 5);
    const list: number[] = [];
    for (let k = 0; k < n; k++) {
      list.push(k);
    }
    return list;
  }

  hasRecord(i: number): boolean {
    return i >= 0 && i < this.rhythm.length && this.rhythm[i].value > 0;
  }

  isTodayIndex(i: number): boolean {
    return i === this.rhythm.length - 1;
  }

  /** 近 7 天有记录的天数 */
  activeDays(): number {
    let n = 0;
    for (const d of this.rhythm) {
      if (d.value > 0) {
        n += 1;
      }
    }
    return n;
  }

  /** 概览四格的值必须在这里读状态，不能通过 @Builder 值参数传入（否则不刷新） */
  statValue(kind: string): string {
    if (kind === 'today') {
      return fmtKg(this.summary.todayReduction);
    }
    if (kind === 'week') {
      return fmtKg(this.summary.weekReduction);
    }
    if (kind === 'streak') {
      return `${this.summary.streakDays}`;
    }
    return `${this.summary.totalPoint}`;
  }

  @Builder
  LightStat(label: string, kind: string, unit: string) {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        Text(this.statValue(kind))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
          .maxLines(1)
        Text(unit)
          .fontSize(8)
          .fontColor(Palette.textLight)
          .margin({ bottom: 2 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(9)
        .fontColor(Palette.textLight)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#F6F9F7')
    .borderRadius(10)
  }

  // ===== 2 列方块 =====

  @Builder
  TileGrid() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.Tile('goal', '🎯', '本月目标')
        this.Tile('task', '✅', '今日任务')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        this.Tile('calendar', '📅', '记录日历')
        this.Tile('source', '🌿', '减排来源')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        this.Tile('recent', '📝', '最近记录')
        this.Tile('level', '🏅', '我的等级')
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  /** 小方块：数值与进度都在方法里读状态，避免 @Builder 值参数被缓存后不刷新 */
  @Builder
  Tile(kind: string, icon: string, title: string) {
    Column({ space: 5 }) {
      Row({ space: 5 }) {
        Text(icon)
          .fontSize(13)
        Text(title)
          .fontSize(12)
          .fontColor(Palette.textSub)
        Blank()
        Text('›')
          .fontSize(15)
          .fontColor(Palette.textLight)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.tileValue(kind))
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })

      if (this.tileRatio(kind) >= 0) {
        ProgressBar({ progress: this.tileRatio(kind), color: this.tileAccent(kind), barHeight: 5 })
      }

      Text(this.tileHint(kind))
        .fontSize(10)
        .fontColor(Palette.textLight)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .layoutWeight(1)
    .height(120)
    .padding({ left: 13, right: 13, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .shadow({ radius: 10, color: '#0A1F3D14', offsetY: 2 })
    .onClick(() => {
      this.openDetail(kind);
    })
  }

  /** 方块强调色在方法里取：@Builder 值参数会被缓存，传进来就停在旧皮肤 */
  tileAccent(kind: string): string {
    if (kind === 'goal' || kind === 'calendar') {
      return this.p();
    }
    if (kind === 'task' || kind === 'recent') {
      return Palette.blue;
    }
    if (kind === 'source') {
      return Palette.purple;
    }
    return Palette.warn;
  }

  tileValue(kind: string): string {
    if (kind === 'goal') {
      return `${round(this.summary.monthReduction, 1)} / ${this.monthGoal} kg`;
    }
    if (kind === 'task') {
      return `${this.claimedTaskCount()} / ${this.tasks.length}`;
    }
    if (kind === 'calendar') {
      // 分母用"已过天数"，比"占整月"更贴近用户直觉：今天 28 号、记了 20 天
      return `${this.review.activeDays}/${new Date().getDate()} 天`;
    }
    if (kind === 'source') {
      if (this.cats.length === 0 || this.cats[0].value <= 0) {
        return '暂无';
      }
      return this.cats[0].name;
    }
    if (kind === 'recent') {
      if (this.recentAll.length === 0) {
        return '暂无记录';
      }
      return this.recentAll[0].activityName;
    }
    return this.level.code;
  }

  tileHint(kind: string): string {
    if (kind === 'goal') {
      if (this.goalProgress >= 1) {
        return '目标已达成，继续加油';
      }
      return `还差 ${round(this.monthGoal - this.summary.monthReduction, 1)} kg`;
    }
    if (kind === 'task') {
      const claimable = this.claimableCount();
      if (claimable > 0) {
        return `可领 ${this.taskRewardLeft()} 分`;
      }
      const left = this.tasks.length - this.claimedTaskCount();
      return left > 0 ? `还差 ${left} 项完成` : '今天的任务都领完了';
    }
    if (kind === 'calendar') {
      if (this.review.recordCount === 0) {
        return '本月还没有记录';
      }
      return `本月 ${this.review.recordCount} 条 · 连续 ${this.summary.streakDays} 天`;
    }
    if (kind === 'source') {
      if (this.cats.length === 0 || this.cats[0].value <= 0) {
        return '本月还没有记录';
      }
      return `占本月 ${Math.round(this.cats[0].ratio * 100)}%`;
    }
    if (kind === 'recent') {
      if (this.recentAll.length === 0) {
        return '去"记一笔"开始记录';
      }
      const r = this.recentAll[0];
      return `${r.qty} ${r.unit} · ${r.date}`;
    }
    return this.level.isMax ? '已达最高等级' : `再减 ${this.level.nextNeed} kg 升级`;
  }

  tileRatio(kind: string): number {
    if (kind === 'goal') {
      return this.goalProgress;
    }
    if (kind === 'task') {
      return this.tasks.length === 0 ? 0 : this.claimedTaskCount() / this.tasks.length;
    }
    if (kind === 'calendar') {
      const elapsed = new Date().getDate();
      return elapsed <= 0 ? 0 : Math.min(1, this.review.activeDays / elapsed);
    }
    if (kind === 'source') {
      if (this.cats.length === 0 || this.cats[0].value <= 0) {
        return -1;
      }
      return this.cats[0].ratio;
    }
    return -1;
  }

  claimedTaskCount(): number {
    return this.tasks.filter((ts: TaskState) => ts.done).length;
  }

  /** 已完成但还没领奖的任务数 */
  claimableCount(): number {
    return this.tasks.filter((ts: TaskState) => ts.done && !ts.claimed).length;
  }

  taskRewardLeft(): number {
    let sum = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      const ts = this.tasks[i];
      if (ts.done && !ts.claimed) {
        sum += ts.task.reward;
      }
    }
    return sum;
  }

  avgMonth(): number {
    const day = new Date().getDate();
    return this.summary.monthReduction / (day > 0 ? day : 1);
  }

  async onClaim(ts: TaskState): Promise<void> {
    // 奖励积分记在账号上：未登录不领奖，先引导登录
    if (!(await requireLogin(this.getUIContext(), '领取任务积分'))) {
      return;
    }
    const got = await carbonStore.claimTask(ts.task.id);
    if (got > 0) {
      DialogUtil.toast(this.getUIContext(), `任务完成，+${got} 碳积分`);
      bumpDataVersion();
    }
  }

  // ===== 详情弹层 =====

  openDetail(kind: string): void {
    this.detailKind = kind;
    this.showDetail = true;
  }

  detailTitle(): string {
    if (this.detailKind === 'goal') {
      return '本月减排目标';
    }
    if (this.detailKind === 'task') {
      return '今日低碳任务';
    }
    if (this.detailKind === 'calendar') {
      return '记录日历';
    }
    if (this.detailKind === 'source') {
      return '本月减排来源';
    }
    if (this.detailKind === 'recent') {
      return '最近记录';
    }
    return '我的等级';
  }

  @Builder
  DetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Palette.textSub)
      Blank()
      Text(value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  DetailSheet() {
    Column({ space: 12 }) {
      Row() {
        Text(this.detailTitle())
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text('关闭')
          .fontSize(13)
          .fontColor(Palette.textSub)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor('#F1F4F2')
          .borderRadius(10)
          .onClick(() => {
            this.showDetail = false;
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 10 }) {
          if (this.detailKind === 'goal') {
            this.GoalDetail()
          } else if (this.detailKind === 'task') {
            this.TaskDetail()
          } else if (this.detailKind === 'calendar') {
            this.CalendarDetail()
          } else if (this.detailKind === 'source') {
            this.SourceDetail()
          } else if (this.detailKind === 'recent') {
            this.RecentDetail()
          } else {
            this.LevelDetail()
          }
        }
        .width('100%')
        .padding({ bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14 })
    .backgroundColor(Palette.bg)
  }

  @Builder
  GoalDetail() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Row() {
          Text('本月已减')
            .fontSize(13)
            .fontColor(Palette.textSub)
          Blank()
          Text(`${round(this.summary.monthReduction, 1)} / ${this.monthGoal} kg`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p())
        }
        .width('100%')

        ProgressBar({ progress: this.goalProgress, color: this.p(), barHeight: 10 })

        Text(this.goalProgress >= 1 ? '目标已达成，超额部分继续累计' :
          `还差 ${round(this.monthGoal - this.summary.monthReduction, 1)} kg`)
          .fontSize(12)
          .fontColor(Palette.textSub)
          .width('100%')
      }
      .sheetCard()

      Column() {
        this.DetailRow('本月记录', `${this.review.recordCount} 条`)
        this.DetailRow('有记录的天数', `${this.review.activeDays} 天`)
        this.DetailRow('日均减排', `${fmtKg(this.avgMonth())} kg`)
        this.DetailRow('比上月', this.review.hasPrev ?
          `${this.review.changeRate >= 0 ? '+' : ''}${Math.round(this.review.changeRate * 100)}%` : '上月无记录')
        this.DetailRow('减排最多的类别', this.review.bestCategoryName.length > 0 ? this.review.bestCategoryName : '暂无')
      }
      .sheetCard()

      Text('想改目标？去「我的 → 月减排目标」调整。')
        .fontSize(11)
        .fontColor(Palette.textLight)
        .width('100%')
    }
    .width('100%')
  }

  @Builder
  TaskList() {
    Column({ space: 10 }) {
      ForEach(this.tasks, (ts: TaskState) => {
        Row({ space: 10 }) {
          Text(ts.task.icon)
            .fontSize(18)
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .backgroundColor(ts.done ? this.pl() : '#F4F6F5')
            .borderRadius(10)
          Column({ space: 2 }) {
            Text(ts.task.name)
              .fontSize(13)
              .fontColor(Palette.text)
            Text(ts.done ? '今日已完成' : `${ts.task.desc} · ${ts.current}/${ts.task.target}`)
              .fontSize(10)
              .fontColor(Palette.textLight)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (ts.claimed) {
            Text('已领 +' + ts.task.reward)
              .fontSize(10)
              .fontColor(Palette.textLight)
          } else if (ts.done) {
            Text(this.loggedIn ? `领 +${ts.task.reward}` : '登录后领')
              .fontSize(11)
              .fontColor(this.loggedIn ? '#FFFFFF' : Palette.textLight)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.loggedIn ? this.p() : '#F4F6F5')
              .borderRadius(9)
              .onClick(() => {
                this.onClaim(ts);
              })
          } else {
            Text(`+${ts.task.reward}`)
              .fontSize(11)
              .fontColor(Palette.textLight)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor('#F4F6F5')
              .borderRadius(9)
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }, (ts: TaskState) => `${ts.task.id}_${ts.done}_${ts.claimed}_${ts.current}`)
    }
    .width('100%')
  }

  @Builder
  TaskDetail() {
    Column({ space: 10 }) {
      Column({ space: 10 }) {
        Row() {
          Text(`${this.summary.todayCount} 条记录 · ${this.claimedTaskCount()}/${this.tasks.length} 完成`)
            .fontSize(11)
            .fontColor(Palette.textLight)
          Blank()
          Text(`可领 ${this.taskRewardLeft()} 分`)
            .fontSize(11)
            .fontColor(this.p())
        }
        .width('100%')

        this.TaskList()
      }
      .sheetCard()

      Text('记录一条对应类别的行为，任务就算完成；领奖后积分进入账本。')
        .fontSize(11)
        .fontColor(Palette.textLight)
        .width('100%')
    }
    .width('100%')
  }

  /** 记录日历：本月一格一天，浅绿 = 有记录、深绿 = 今天；这不是图表，只回答"哪天记了" */
  @Builder
  CalendarDetail() {
    Column({ space: 10 }) {
      Column({ space: 10 }) {
        Row() {
          Column({ space: 2 }) {
            Text(this.monthLabel)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
            Text('一格一天 · 浅绿表示当天有记录')
              .fontSize(10)
              .fontColor(Palette.textLight)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text(`${this.review.recordCount}`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p())
            Text('本月记录')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          ForEach(WEEK_HEADS, (w: string) => {
            Text(w)
              .fontSize(10)
              .fontColor(Palette.textLight)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }, (w: string) => `wh_${w}`)
        }
        .width('100%')

        Grid() {
          ForEach(this.calCells, (cell: CalCell, i: number) => {
            GridItem() {
              this.CalDay(i)
            }
          }, (cell: CalCell, i: number) => `cal_${i}_${cell.date}_${cell.count}_${cell.isToday}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(2)
        .rowsGap(2)
        .width('100%')
        .height(this.calendarHeight())

        Row({ space: 14 }) {
          Row({ space: 5 }) {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(this.pl())
              .border({ width: 1, color: this.p() })
            Text('有记录')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .alignItems(VerticalAlign.Center)

          Row({ space: 5 }) {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(this.p())
            Text('今天')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
      }
      .sheetCard()

      Column() {
        Row() {
          Column({ space: 2 }) {
            Text(`${this.review.activeDays}`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p())
            Text('天有记录')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 2 }) {
            Text(`${this.review.recordCount}`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p())
            Text('条记录')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 2 }) {
            Text(`${fmtKg(this.review.reduction)}`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p())
            Text('kg 减排')
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }
      .sheetCard()
    }
    .width('100%')
  }

  /** 日历单格：列宽由 Grid 的 7 等分模板决定，这里只定高 */
  @Builder
  CalDay(i: number) {
    Column({ space: 2 }) {
      Text(this.cellDayText(i))
        .fontSize(12)
        .fontColor(this.cellInk(i))
        .fontWeight(this.cellBold(i) ? FontWeight.Medium : FontWeight.Normal)
      Row()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.cellDot(i))
    }
    .width('100%')
    .height(36)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.cellBg(i))
    .borderRadius(9)
  }

  /** 日历总高：行数 × 格高 + 行间距；Grid 不给高度会被当成滚动容器而塌成 0 */
  calendarHeight(): number {
    const rows = Math.ceil(this.calCells.length / 7);
    return rows <= 0 ? 0 : rows * 36 + (rows - 1) * 2;
  }

  cellDayText(i: number): string {
    const c = this.calCells[i];
    return c.day > 0 ? `${c.day}` : '';
  }

  cellInk(i: number): string {
    const c = this.calCells[i];
    if (c.day <= 0) {
      return CLEAR_COLOR;
    }
    if (c.isToday) {
      return '#FFFFFF';
    }
    if (c.future) {
      return '#C9D2CE';
    }
    return c.count > 0 ? this.pd() : Palette.textSub;
  }

  cellBold(i: number): boolean {
    const c = this.calCells[i];
    return c.day > 0 && (c.isToday || c.count > 0);
  }

  cellDot(i: number): string {
    const c = this.calCells[i];
    if (c.day <= 0 || c.count <= 0) {
      return CLEAR_COLOR;
    }
    return c.isToday ? '#FFFFFF' : this.p();
  }

  cellBg(i: number): string {
    const c = this.calCells[i];
    if (c.day <= 0) {
      return CLEAR_COLOR;
    }
    if (c.isToday) {
      return this.p();
    }
    return c.count > 0 ? this.pl() : CLEAR_COLOR;
  }

  @Builder
  SourceDetail() {
    Column({ space: 10 }) {
      Column({ space: 2 }) {
        if (this.cats.length > 0 && this.cats[0].value > 0) {
          ForEach(this.cats, (cv: CategoryValue) => {
            Row({ space: 10 }) {
              Text(cv.icon)
                .fontSize(16)
                .width(28)
                .textAlign(TextAlign.Center)
              Column({ space: 4 }) {
                Row() {
                  Text(cv.name)
                    .fontSize(12)
                    .fontColor(Palette.text)
                  Blank()
                  Text(`${fmtKg(cv.value)} kg · ${cv.count} 次`)
                    .fontSize(11)
                    .fontColor(Palette.textSub)
                }
                .width('100%')

                ProgressBar({ progress: cv.ratio, color: cv.color, barHeight: 6 })
              }
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }, (cv: CategoryValue) => `${cv.categoryId}_${cv.value}_${round(cv.ratio, 3)}`)
        } else {
          Text('本月还没有记录，去「记一笔」记下第一条吧。')
            .fontSize(12)
            .fontColor(Palette.textLight)
            .padding({ top: 16, bottom: 16 })
        }
      }
      .sheetCard()
    }
    .width('100%')
  }

  @Builder
  RecentDetail() {
    Column({ space: 10 }) {
      Column({ space: 2 }) {
        if (this.recentAll.length === 0) {
          Text('还没有低碳记录，每记一笔都在为地球减负。')
            .fontSize(12)
            .fontColor(Palette.textLight)
            .padding({ top: 16, bottom: 16 })
        } else {
          ForEach(this.recentAll, (r: CarbonRecord) => {
            Row({ space: 10 }) {
              Text(carbonStore.iconOf(r.activityId))
                .fontSize(16)
                .width(32)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F4F7F5')
                .borderRadius(9)
              Column({ space: 2 }) {
                Text(r.activityName)
                  .fontSize(13)
                  .fontColor(Palette.text)
                Text(`${r.qty} ${r.unit} · ${r.date}${r.note.length > 0 ? ' · ' + r.note : ''}`)
                  .fontSize(10)
                  .fontColor(Palette.textLight)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(`-${r.reduction} kg`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.p())
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (r: CarbonRecord) => r.id)
        }
      }
      .sheetCard()

      if (this.recentAll.length > 0) {
        Text('完整历史可在「看板 → 历史记录」查看与删除。')
          .fontSize(11)
          .fontColor(Palette.textLight)
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  LevelDetail() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Row() {
          Text(this.level.code)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p())
          Text(this.level.title)
            .fontSize(13)
            .fontColor(Palette.textSub)
            .margin({ left: 8 })
          Blank()
          Text(`累计 ${fmtKg(this.level.total)} kg`)
            .fontSize(11)
            .fontColor(Palette.textSub)
        }
        .width('100%')

        ProgressBar({ progress: this.level.progress, color: this.p(), barHeight: 8 })

        Text(this.level.isMax ? '已达最高等级' : `再减 ${this.level.nextNeed} kg 就升级`)
          .fontSize(11)
          .fontColor(Palette.textSub)
          .width('100%')
      }
      .sheetCard()

      Column() {
        this.DetailRow('碳积分', `${this.summary.totalPoint} 分`)
        this.DetailRow('累计减排', `${fmtKg(this.summary.totalReduction)} kg`)
        this.DetailRow('记录次数', `${this.summary.totalCount} 次`)
        this.DetailRow('已获得徽章', `${this.badgeGot} / ${this.badgeTotal}`)
        this.DetailRow('相当于种树', `${fmtKg(this.summary.treeCount)} 棵·年`)
      }
      .sheetCard()
    }
    .width('100%')
  }

  /** 个性化推荐与生活建议：沿用 B 的推荐内容，套用 C 的白卡样式 */
  @Builder
  InsightCard() {
    Column() {
      Column({ space: 6 }) {
        SectionTitle('为你推荐', '基于你的记录')
        ForEach(this.insights, (it: Insight) => {
          Row({ space: 10 }) {
            Text(it.icon)
              .fontSize(18)
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .backgroundColor(it.kind === 'task' ? this.pl() : '#F4F6F5')
              .borderRadius(10)

            Column({ space: 2 }) {
              Row({ space: 5 }) {
                Text(it.title)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Palette.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(it.kind === 'task' ? '推荐任务' : '生活建议')
                  .fontSize(8)
                  .fontColor(this.pd())
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .backgroundColor(this.pl())
                  .borderRadius(4)
              }
              .width('100%')

              Text(it.detail)
                .fontSize(10)
                .fontColor(Palette.textLight)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(15)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (it.actionLabel.length > 0) {
              Text(it.actionLabel)
                .fontSize(10)
                .fontColor('#FFFFFF')
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .backgroundColor(this.p())
                .borderRadius(8)
            }
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            if (it.categoryId.length > 0) {
              this.goRecord(it.categoryId);
            }
          })
        }, (it: Insight) => it.id + '_' + it.title + '_' + it.detail + '_' + it.actionLabel)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(20)
    .border({ width: 1, color: '#E9F2EC' })
    .shadow({ radius: 14, color: '#081F3D12', offsetY: 4 })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.RhythmCard()
        this.TileGrid()
        this.InsightCard()

        Text('点小方块看详情 · 数据仅保存在本机')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .margin({ top: 4, bottom: 8 })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .bindSheet(this.showDetail, this.DetailSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Palette.bg
    })
  }
}
