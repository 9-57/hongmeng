import { Activity, Category } from '../model/CarbonModels';
import { CATEGORIES } from '../model/CarbonData';
import { carbonStore } from '../viewmodel/CarbonStore';
import { describeErr, ImageRecognitionService, RecogResult, RecogTag } from '../service/ImageRecognitionService';
import { AutoRecordService } from '../service/AutoRecordService';
import { AIRecognitionService } from '../service/AIRecognitionService';
import { bumpDataVersion, dateStart, formatDate, fmtKg, round, todayStr, weekLabel } from '../common/Utils';
import { DialogUtil } from '../common/DialogUtil';
import { auth } from '../service/AuthService';
import { requireLogin } from '../service/AccountGate';
import { Palette } from '../common/Theme';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RECOG_TAG = 'carbon-vision';

/**
 * 记一笔。
 *
 * 注意（踩坑）：ArkUI 的 struct 不支持 TS 的 `get` 访问器——ets-loader 会把
 * `get selected()` 这类写法整个丢掉，但保留 `this.selected` 的引用，运行时
 * 恒为 undefined。曾因此导致试算面板永远不渲染、分类说明行空白。
 * 所以 struct 内部一律用普通方法（currentActivity() 等）取派生值。
 */
@Component
export struct RecordTab {
  /** 由主页面传入的刷新令牌，值变化即重新取数 */
  @Prop @Watch('onTokenChange') token: number = 0;
  /** 当前皮肤：主色都经下面的方法取色，读它才会在切换后重绘 */
  @StorageProp('skinId') skinId: string = 'original';
  @State activeCat: string = 'travel';
  @State selectedId: string = '';
  @State qty: number = 1;
  @State note: string = '';
  /** 是否已展开行内录入：只有点中某个行为后才在它下方显示录入区 */
  @State expanded: boolean = false;
  /** 图片智能识别：弹层开关 / 识别阶段（'' | 'pick' | 'analyze'）/ 结果快照 */
  @State showRecog: boolean = false;
  @State recogStage: string = '';
  @State recog: RecogResult = new RecogResult();
  /** 自动记账的结论（面板顶部横幅），空串表示这一轮没走到自动记账 */
  @State autoMsg: string = '';
  /** 横幅配色：true 绿色（已记账）/ false 黄色（未记账及原因） */
  @State autoOk: boolean = false;
  /** 已自动记账的行为 id，用于把候选项标成"已记账" */
  @State autoIds: string[] = [];
  /** AI 判定当前是否可用：false 时识别不可用（没有端侧兜底） */
  @State aiReady: boolean = false;
  /** 是否正在等模型答复（弹层先开、内容后填，避免慢模型期间看起来像没反应） */
  @State recogBusy: boolean = false;
  /** 看门狗定时器句柄：选图 Promise 长时间不落地时用来解锁按钮 */
  recogWatchdog: number = -1;
  /** 弹层延迟打开的定时器：等图库页退场后再打开，否则会被窗口切换吞掉 */
  recogOpenTimer: number = -1;
  /** 弹层是否真的呈现了（靠 bindSheet 的 onAppear 回填），用于失败重试 */
  sheetShown: boolean = false;
  /** 当前识别流程的令牌：新流程自增，用来识别"迟到的旧结果" */
  recogToken: number = 0;
  /** 最近一次选中的图片 uri，用于失败后"重试这张"而不必再翻图库 */
  lastPickedUri: string = '';
  /** 记账日期（yyyy-MM-dd），默认今天，可通过日期选择器补记 */
  @State recordDate: string = todayStr();
  /** 账号登录态：积分属于账号，未登录时保存按钮走登录引导 */
  @State loggedIn: boolean = false;

  p(): string {
    return Palette.skinById(this.skinId).primary;
  }

  pl(): string {
    return Palette.skinById(this.skinId).primaryLight;
  }

  aboutToAppear(): void {
    this.loggedIn = auth.isLoggedIn;
    this.pickDefault();
    // 存储读取是异步的，首次进入时若还没读完，读完后再校正一次选中项
    carbonStore.ensureLoaded(() => {
      this.syncSelection();
    });
    this.refreshAiReady();
  }

  /**
   * 判断识别现在能不能用（是否配好了模型）。
   *
   * 端侧色彩兜底删除后，没配模型时识别功能整体不可用，入口必须提前说清楚，
   * 而不是等用户选完图才发现没反应。
   */
  async refreshAiReady(): Promise<void> {
    try {
      const cfg = await AIRecognitionService.loadConfig();
      this.aiReady = AIRecognitionService.isUsable(cfg);
    } catch (e) {
      this.aiReady = false;
    }
  }

  /** 页面销毁时清掉看门狗，避免定时器在已卸载的组件上回调 */
  aboutToDisappear(): void {
    if (this.recogWatchdog !== -1) {
      clearTimeout(this.recogWatchdog);
      this.recogWatchdog = -1;
    }
    if (this.recogOpenTimer !== -1) {
      clearTimeout(this.recogOpenTimer);
      this.recogOpenTimer = -1;
    }
  }

  /**
   * 打开识别结果弹层。
   *
   * 踩过两次坑，这里都是为它们写的：
   * ① 图库是独立窗口，`pickImage()` 的 Promise 落地时图库往往还在退场动画里。
   *    这时立刻 `showRecog = true`，弹层会挂在"正在切换的窗口"上，切回来时
   *    已经被丢弃 —— 表现就是"选了图什么也没发生"，而且时好时坏。所以先等
   *    一小会儿再开。
   * ② 万一还是没开出来（bindSheet 的时序在不同机型上不一样），1.2 秒后
   *    通过 onAppear 回填的 `sheetShown` 判断一次，没出现就重开一次。
   */
  openRecogSheet(): void {
    // 已经开着就别重开：重复置真会被 onAppear/onDisappear 的探活逻辑当成
    // "没弹出来"，反而把正常显示的弹层关掉再开，肉眼看到的是闪一下。
    if (this.showRecog && this.sheetShown) {
      return;
    }
    if (this.recogOpenTimer !== -1) {
      clearTimeout(this.recogOpenTimer);
      this.recogOpenTimer = -1;
    }
    this.sheetShown = false;
    this.recogOpenTimer = setTimeout(() => {
      this.recogOpenTimer = -1;
      this.showRecog = true;
      hilog.info(0x0000, RECOG_TAG, 'sheet request sent');
      // 兜底重开：只重试一次，避免在异常的机型上反复闪
      setTimeout(() => {
        if (!this.sheetShown && this.showRecog) {
          hilog.warn(0x0000, RECOG_TAG, 'sheet not shown, retry once');
          this.showRecog = false;
          setTimeout(() => {
            this.showRecog = true;
          }, 200);
        }
      }, 1200);
    }, 450);
  }

  /**
   * 数据版本变化时只做"校正"，不重置用户已经选好的行为与数量。
   * 原实现每次版本自增都调 pickDefault()，在首页领任务奖励也会把这里的数量打回默认值。
   */
  onTokenChange(): void {
    this.loggedIn = auth.isLoggedIn;
    this.syncSelection();
    // 用户可能刚在「我的 → 个人设置」改过 AI 配置，切回来要重新判断入口文案
    this.refreshAiReady();
  }

  syncSelection(): void {
    const cur = this.currentActivity();
    if (cur === undefined || cur.categoryId !== this.activeCat) {
      this.pickDefault();
    }
  }

  pickDefault(): void {
    const list = carbonStore.activitiesOf(this.activeCat);
    if (list.length > 0) {
      this.selectedId = list[0].id;
      this.qty = this.clampQty(list[0].defaultQty, list[0].maxQty);
    }
  }

  /** 当前选中的行为（不要写成 get 访问器，见文件头说明） */
  currentActivity(): Activity | undefined {
    return carbonStore.getActivityById(this.selectedId);
  }

  maxQty(): number {
    const a = this.currentActivity();
    return a === undefined ? 100 : a.maxQty;
  }

  clampQty(value: number, max: number): number {
    return Math.max(1, Math.min(max, value));
  }

  previewReduction(): number {
    const a = this.currentActivity();
    return a === undefined ? 0 : round(a.factor * this.qty, 3);
  }

  previewPoint(): number {
    const a = this.currentActivity();
    if (a === undefined) {
      return 0;
    }
    return Math.max(1, Math.round(a.basePoint + this.previewReduction() * 2));
  }

  /** 快捷倍数：只保留不超过该行为数量上限的档位，避免出现选 ×10 但上限只有 4 的越界 */
  quickMultiples(): number[] {
    const max = this.maxQty();
    const all: number[] = [1, 2, 5, 10];
    return all.filter((n: number) => n <= max);
  }

  /** 收起键盘：备注输入框有焦点时，点行为/保存都应把键盘让出来 */
  dismissKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      // 无输入焦点或控制器不可用时忽略
    }
  }

  onSelect(a: Activity): void {
    this.dismissKeyboard();
    // 再点一次同一项收起录入区；点其他项则切换并展开
    if (this.selectedId === a.id && this.expanded) {
      this.expanded = false;
      return;
    }
    this.selectedId = a.id;
    this.qty = this.clampQty(a.defaultQty, a.maxQty);
    this.expanded = true;
  }

  /** 该项是否处于展开录入状态 */
  isOpen(a: Activity): boolean {
    return this.expanded && this.selectedId === a.id;
  }

  async onSave(): Promise<void> {
    // 积分归账号所有：未登录不写入任何记录，直接引导登录
    if (!(await requireLogin(this.getUIContext(), '记账'))) {
      return;
    }
    const a = this.currentActivity();
    if (a === undefined) {
      DialogUtil.toast(this.getUIContext(), '请先选择一个低碳行为');
      return;
    }
    const qty = this.clampQty(this.qty, a.maxQty);
    const day = this.recordDate.length === 10 ? this.recordDate : todayStr();
    const isBackfill = day !== todayStr();
    const got = await carbonStore.addRecord(a, qty, day, this.note.trim());
    this.note = '';
    this.recordDate = todayStr();
    this.dismissKeyboard();
    bumpDataVersion();
    const prefix = isBackfill ? `已补记 ${day}：` : '记录成功：';
    DialogUtil.toast(this.getUIContext(),
      `${prefix}减排 ${round(a.factor * qty, 2)} kg，+${got} 积分`);
  }

  /**
   * 记账日期选择器。
   * 上限取"现在"而不是本月最后一天：carbonStore 的按天统计只处理已发生的日期，
   * 允许选未来日期会让趋势图凭空多出一个 0 值点。
   */
  openDatePicker(): void {
    const cur = dateStart(this.recordDate);
    this.getUIContext().showDatePickerDialog({
      start: new Date(2024, 0, 1),
      end: new Date(),
      selected: cur > 0 ? new Date(cur) : new Date(),
      onDateAccept: (value: Date) => {
        this.recordDate = formatDate(value.getTime());
      }
    });
  }

  /** 日期显示：今天 / 昨天 / yyyy-MM-dd 周X */
  dateLabel(): string {
    const today = todayStr();
    if (this.recordDate === today) {
      return '今天';
    }
    const ts = dateStart(this.recordDate);
    if (ts <= 0) {
      return this.recordDate;
    }
    const diff = Math.round((dateStart(today) - ts) / 86400000);
    if (diff === 1) {
      return '昨天';
    }
    return `${this.recordDate} ${weekLabel(ts)}`;
  }

  /**
   * 选图 → AI 判定 → 自动记账。
   *
   * 交互目标：用户只需选一张图，判定和加分都由模型完成，不再点两次（选候选 +
   * 一键记录）。因此这里在选图前就把登录拦住——积分是账号资产，等模型跑完
   * 十几秒再告诉用户"没登录"，体验最差。
   *
   * 踩坑（旧实现的根因）：模拟器上点系统图库里的"拍照"时，相机会话 Ability
   * （com.huawei.hmos.camera/PickerAbility）并不存在，picker.select() 的 Promise
   * 可能一直不落地。旧写法把 recogBusy 置真后只在正常返回的分支里复位，
   * 一旦卡住就永久停在"识别中"，再点也被开头的 guard 吞掉，只能杀进程。
   * 现在的三层兜底：
   *   ① 图库不再显示"拍照"入口（见 pickImage），从源头绕开坏路径；
   *   ② try/finally 保证任何分支都会复位；
   *   ③ 看门狗只负责"解锁界面"，不丢弃这一轮——用户在图库里慢慢挑照片是
   *      正常行为，挑完返回的结果仍然要认领（见 claimRun）。
   */
  async doRecognize(): Promise<void> {
    if (this.recogStage.length > 0) {
      hilog.info(0x0000, RECOG_TAG, 'tap ignored, stage=%{public}s', this.recogStage);
      return;
    }
    // 未登录不静默加分：先引导登录，再走识别
    if (!(await requireLogin(this.getUIContext(), '图片识别记账'))) {
      return;
    }
    const runId = ++this.recogToken;
    this.recogStage = 'pick';
    this.recogWatchdog = setTimeout(() => {
      this.recogWatchdog = -1;
      if (runId !== this.recogToken || this.recogStage.length === 0) {
        return;
      }
      // 只解锁，不作废：用户可能还在图库里挑，挑完照样能出结果。
      // 静默解锁，不弹 toast——大多数情况下用户马上就会带着照片回来。
      hilog.warn(0x0000, RECOG_TAG, 'pick still pending after timeout, unlock ui');
      this.recogStage = '';
    }, 45000);
    try {
      const picked = await ImageRecognitionService.pickImage();
      if (!this.claimRun(runId)) {
        return;
      }
      if (picked.uri.length === 0) {
        // 主动取消不打扰用户；真正失败才提示
        if (picked.reason.length > 0) {
          DialogUtil.toast(this.getUIContext(), picked.reason);
        }
        return;
      }
      this.lastPickedUri = picked.uri;
      await this.runAnalyze(picked.uri, runId);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, RECOG_TAG, 'doRecognize failed: %{public}s', describeErr(e));
      // 异常也放进弹层，别再弹一个会消失的 toast
      const fail = new RecogResult();
      fail.message = `识别过程出错（${describeErr(e)}）`;
      this.recogBusy = false;
      this.recog = fail;
      this.openRecogSheet();
    } finally {
      // 只有"当前流程"才有资格复位；已被新流程接管的旧流程不能清掉新流程的状态
      if (runId === this.recogToken) {
        if (this.recogWatchdog !== -1) {
          clearTimeout(this.recogWatchdog);
          this.recogWatchdog = -1;
        }
        this.recogStage = '';
        // 兜底：任何分支都不该让弹层停在"正在识别"
        this.recogBusy = false;
      }
    }
  }

  /**
   * 分析一张已经选中的图片。
   *
   * 面板从"开始识别"就打开：小模型一次要等十几秒，屏幕没变化用户会以为卡死
   * （真实机型上被反馈过）。识别完成后**不关面板**，而是把结论写进面板顶部：
   *   - 已自动记账：绿色横幅 + 候选项标"已记账"，用户什么都不用点；
   *   - 没记上（同图已记过 / 已达上限 / 云端与本机都失败）：黄色横幅写清原因，
   *     候选项仍可手动"填入"兜底。
   * 这样"识别中"和"识别结果"在同一个面板里连续呈现，不会出现空窗。
   */
  async runAnalyze(uri: string, runId: number): Promise<void> {
    this.recogStage = 'analyze';
    this.recogBusy = true;
    this.recog = new RecogResult();
    this.autoMsg = '';
    this.autoOk = false;
    this.autoIds = [];
    this.openRecogSheet();
    let outcome: RecogResult = new RecogResult();
    let autoMsg = '';
    let autoOk = false;
    let autoIds: string[] = [];
    try {
      const r = await ImageRecognitionService.recognize(uri);
      if (runId !== this.recogToken) {
        return;
      }
      hilog.info(0x0000, RECOG_TAG,
        'recognize done: ok=%{public}s tags=%{public}d msg=%{public}s',
        r.ok ? 'yes' : 'no', r.tags.length, r.message);
      outcome = r;
      if (r.ok) {
        // 这一轮确实走通了模型，入口文案随之变成"会自动记账"
        this.aiReady = true;
      }
      if (r.ok && r.hasLowCarbon && r.tags.length > 0) {
        const commit = await AutoRecordService.commit(uri, r);
        if (runId !== this.recogToken) {
          return;
        }
        autoMsg = commit.message;
        autoOk = commit.addedIds.length > 0;
        autoIds = commit.addedIds;
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, RECOG_TAG, 'analyze failed: %{public}s', describeErr(e));
      const fail = new RecogResult();
      fail.message = `识别过程出错（${describeErr(e)}）`;
      outcome = fail;
    }
    // 状态变量只落一次，避免一帧内的重复重绘（也避开 linter 的临时变量告警）
    this.recogBusy = false;
    this.recog = outcome;
    this.autoMsg = autoMsg;
    this.autoOk = autoOk;
    this.autoIds = autoIds;
    // 弹层这会儿多半已经开着，只换内容；万一那次被窗口切换吞了才补开
    if (!this.sheetShown) {
      this.openRecogSheet();
    }
  }

  /** 同一张图再来一次：模型偶发不按格式答，重试往往就好了，不用重选图 */
  async retryLast(): Promise<void> {
    if (this.recogStage.length > 0 || this.lastPickedUri.length === 0) {
      return;
    }
    const runId = ++this.recogToken;
    const uri = this.lastPickedUri;
    try {
      await this.runAnalyze(uri, runId);
    } finally {
      if (runId === this.recogToken) {
        this.recogStage = '';
        this.recogBusy = false;
      }
    }
  }

  /**
   * 判断一次异步结果还算不算"我的"。
   * 新一轮已经开跑（recogStage 非空）时，旧结果必须丢弃，否则会把新一轮
   * 的"选择中"状态覆盖掉；只是界面被看门狗解锁、用户并没有重新发起时，
   * 把这一轮认领回来，用户辛苦挑的照片才不会白选。
   */
  claimRun(runId: number): boolean {
    if (runId === this.recogToken) {
      return true;
    }
    if (this.recogStage.length > 0) {
      hilog.info(0x0000, RECOG_TAG, 'stale pick result dropped, run=%{public}d', runId);
      return false;
    }
    hilog.info(0x0000, RECOG_TAG, 'late pick result adopted, run=%{public}d', runId);
    this.recogToken = runId;
    return true;
  }

  /** 是否正在走识别流程（选图或分析），用于禁用重复点击 */
  recogBusyNow(): boolean {
    return this.recogStage.length > 0;
  }

  /** 识别入口的副标题：把"等用户选图"和"正在识别"分开，避免误以为卡死 */
  recogHint(): string {
    if (this.recogStage === 'pick') {
      return '请在图库里选一张照片';
    }
    if (this.recogStage === 'analyze') {
      return '正在识别，稍等一下';
    }
    // 没有端侧兜底：没配模型就是不能用，入口必须提前说清楚
    return this.aiReady
      ? '选一张照片，AI 判定后自动记账'
      : 'AI 未启用：请先在「我的 → 个人设置 → AI 图片识别」配置模型';
  }

  /** 识别入口的按钮文案 */
  recogBtnText(): string {
    if (this.recogStage === 'pick') {
      return '选择中';
    }
    if (this.recogStage === 'analyze') {
      return '识别中';
    }
    return '识别记账';
  }

  /** 点候选结果：只填参数，不直接落库，仍需用户点"一键记录"确认 */
  applyRecog(t: RecogTag): void {
    const a = carbonStore.getActivityById(t.activityId);
    if (a === undefined) {
      DialogUtil.toast(this.getUIContext(), '该行为暂不可用，请手动选择');
      return;
    }
    this.dismissKeyboard();
    this.activeCat = a.categoryId;
    this.selectedId = a.id;
    this.qty = this.clampQty(a.defaultQty, a.maxQty);
    this.expanded = true;
    this.showRecog = false;
    DialogUtil.toast(this.getUIContext(), `已填入「${a.name}」，确认数量后点一键记录`);
  }

  /**
   * 面板副标题：模型只回两个值，没有 evidence 可展示，
   * 命中时直接说清"类别 · 行为名"，比展示"模型已返回结论"更有信息量。
   */
  recogSubtitle(): string {
    if (!this.recog.ok) {
      return '这次没识别出来';
    }
    if (this.recog.tags.length > 0) {
      const t = this.recog.tags[0];
      return `${this.categoryName(t.categoryId)} · ${t.activityName}`;
    }
    return this.recog.hasLowCarbon ? '识别到低碳行为，但没有对应到内置清单' : '画面里没有明确的低碳行为';
  }

  /** 分类 id → 中文名，用于识别结果里显示"绿色出行 · 行为" */
  categoryName(id: string): string {
    for (const c of CATEGORIES) {
      if (c.id === id) {
        return c.name;
      }
    }
    return '';
  }

  /** 这条候选是否已经自动记账（同一轮里被策略放行并入账的行为） */
  isAutoAdded(t: RecogTag): boolean {
    return this.autoIds.indexOf(t.activityId) >= 0;
  }

  /** 没有候选时说什么（现在只有 AI 一条路径） */
  emptyRecogText(): string {
    if (this.recog.message.length > 0) {
      return this.recog.message;
    }
    return '画面里没有明确的低碳行为证据。可以试试拍：骑共享单车、吃干净的餐盘、走楼梯、分类回收物、自带水杯。';
  }

  @Builder
  CategoryChip(c: Category) {
    Column({ space: 4 }) {
      Text(c.icon)
        .fontSize(22)
      Text(c.name)
        .fontSize(11)
        .fontColor(this.activeCat === c.id ? '#FFFFFF' : Palette.textSub)
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor(this.activeCat === c.id ? c.color : Palette.card)
    .borderRadius(12)
    .border({ width: 1, color: this.activeCat === c.id ? c.color : Palette.line })
    .onClick(() => {
      if (this.activeCat === c.id) {
        return;
      }
      this.dismissKeyboard();
      this.activeCat = c.id;
      this.pickDefault();
      // 换分类后回到"未选"状态，录入区等用户点具体行为再展开
      this.expanded = false;
    })
  }

  @Builder
  ActivityItem(a: Activity) {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text(a.icon)
          .fontSize(20)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.selectedId === a.id ? this.pl() : '#F4F7F5')
          .borderRadius(11)

        Column({ space: 3 }) {
          Text(a.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text(`${a.factor} kg / ${a.unit} · ${a.hint}`)
            .fontSize(10)
            .fontColor(Palette.textLight)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 1 }) {
          Text('+' + a.basePoint)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p())
          Text('基础分')
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .padding(12)
      .onClick(() => {
        this.onSelect(a);
      })

      // 点中该项后，在该项下方展开录入区
      if (this.isOpen(a)) {
        Column() {
          this.InlineEditor(a)
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor(this.isOpen(a) ? this.pl() : Palette.card)
    .borderRadius(14)
    .border({ width: 1, color: this.isOpen(a) ? this.p() : Palette.line })
  }

  /** 行内录入：数量 / 快捷倍数 / 备注 / 日期 / 试算 / 保存 */
  @Builder
  InlineEditor(a: Activity) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text('−')
          .fontSize(20)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .fontColor(this.p())
          .backgroundColor(this.pl())
          .borderRadius(11)
          .onClick(() => {
            this.qty = this.clampQty(this.qty - a.step, a.maxQty);
          })

        Column({ space: 2 }) {
          Text(`${this.qty}`)
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text(a.unit)
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .layoutWeight(1)

        Text('+')
          .fontSize(20)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .fontColor(this.p())
          .backgroundColor(this.pl())
          .borderRadius(11)
          .onClick(() => {
            this.qty = this.clampQty(this.qty + a.step, a.maxQty);
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor('#F7F9F8')
      .borderRadius(12)

      // 快捷倍数
      Row({ space: 8 }) {
        ForEach(this.quickMultiples(), (n: number) => {
          Text(`×${n}`)
            .fontSize(11)
            .fontColor(this.qty === n ? '#FFFFFF' : Palette.textSub)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(this.qty === n ? this.p() : '#F0F3F2')
            .borderRadius(9)
            .onClick(() => {
              this.qty = this.clampQty(n, a.maxQty);
            })
        }, (n: number) => `e_${a.id}_${n}_${this.qty === n}`)
      }
      .width('100%')

      // 备注（数据层早已支持 note，此前 UI 没有入口，导出报表里这一列永远是空的）
      TextInput({ text: this.note, placeholder: '备注（可选）：和谁一起、去了哪里' })
        .fontSize(11)
        .height(34)
        .maxLength(40)
        .backgroundColor('#F7F9F8')
        .borderRadius(9)
        .onChange((v: string) => {
          this.note = v;
        })

      // 记账日期（默认今天，可补记历史；上限到今天）
      Row({ space: 8 }) {
        Text('🕒')
          .fontSize(12)
        Text('记录日期')
          .fontSize(11)
          .fontColor(Palette.textSub)
        Blank()
        Text(this.dateLabel())
          .fontSize(11)
          .fontColor(this.recordDate === todayStr() ? Palette.textSub : Palette.warn)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor('#F7F9F8')
          .borderRadius(8)
      }
      .width('100%')
      .onClick(() => {
        this.dismissKeyboard();
        this.openDatePicker();
      })

      Row() {
        Column({ space: 2 }) {
          Text('预计减排')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Row({ space: 3 }) {
            Text(fmtKg(this.previewReduction()))
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.p())
            Text('kg CO₂e')
              .fontSize(9)
              .fontColor(Palette.textSub)
              .margin({ bottom: 3 })
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Column({ space: 2 }) {
          Text('预计积分')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Text(`+${this.previewPoint()}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.warn)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .padding({ top: 4, bottom: 2 })

      Row() {
        Text(this.loggedIn ? '一键记录' : '登录后记账')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.loggedIn ? '#FFFFFF' : Palette.textSub)
      }
      .width('100%')
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.loggedIn ? this.p() : '#EDF1EF')
      .borderRadius(12)
      .onClick(() => {
        this.onSave();
      })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Palette.card)
    .borderRadius(12)
    .border({ width: 1, color: Palette.line })
  }

  /** 图片识别结果面板：给出候选与命中理由，避免黑箱 */
  @Builder
  RecogSheet() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('🤖')
          .fontSize(24)
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('识别结果')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
            Text(this.recogBusy ? '识别中' : 'AI 判定')
              .fontSize(9)
              .fontColor(this.recogBusy ? Palette.textSub : this.p())
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(this.recogBusy ? '#F0F2F1' : this.pl())
              .borderRadius(5)
          }
          .alignItems(VerticalAlign.Center)

          Text(this.recogBusy
            ? '正在识别这张照片'
            : this.recogSubtitle())
            .fontSize(10)
            .fontColor(Palette.textLight)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 等模型答复期间：给一条明确的进度，别让用户对着空白屏猜
      if (this.recogBusy) {
        Row({ space: 9 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(this.p())
          Text('正在识别这张照片，小模型可能要几秒…')
            .fontSize(11)
            .fontColor(Palette.textSub)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 9, bottom: 9 })
        .backgroundColor('#F3F7F4')
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
      }

      // 失败时把原因留在屏幕上，而不是弹个两秒就消失的 toast
      if (!this.recogBusy && !this.recog.ok) {
        Column({ space: 5 }) {
          Text('这次没识别出来')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#B3452F')
          Text(this.recog.message.length > 0 ? this.recog.message : '换个角度再拍一张试试')
            .fontSize(10.5)
            .fontColor(Palette.textSub)
            .width('100%')
            .lineHeight(16)
          if (this.lastPickedUri.length > 0) {
            Text('重试这张')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.p())
              .borderRadius(8)
              .margin({ top: 4 })
              .onClick(() => {
                this.retryLast();
              })
          }
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 9, bottom: 9 })
        .backgroundColor('#FBEFEC')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
      }

      // 自动记账的结论放最上面：记了还是没记、为什么没记，一眼可见
      if (!this.recogBusy && this.autoMsg.length > 0) {
        Row({ space: 7 }) {
          Text(this.autoOk ? '✓' : '!')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.autoOk ? this.p() : '#9C540F')
            .width(18)
            .height(18)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FFFFFF')
            .borderRadius(9)
          Text(this.autoMsg)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .lineHeight(16)
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 8, bottom: 8 })
        .backgroundColor(this.autoOk ? this.p() : '#9C540F')
        .borderRadius(9)
        .alignItems(VerticalAlign.Top)
      }

      // 没走到自动记账时，仍给一个明确结论（AI 判定）
      if (!this.recogBusy && this.recog.ok && this.autoMsg.length === 0) {
        Row({ space: 6 }) {
          Text(this.recog.hasLowCarbon ? '✓' : '—')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.recog.hasLowCarbon ? '#FFFFFF' : Palette.textSub)
          Text(this.recog.hasLowCarbon ? '检测到低碳行为' : '未检测到低碳行为')
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.recog.hasLowCarbon ? '#FFFFFF' : Palette.textSub)
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 7, bottom: 7 })
        .backgroundColor(this.recog.hasLowCarbon ? this.p() : '#EEF0EF')
        .borderRadius(9)
      }

      if (!this.recogBusy && this.recog.ok) {
        Text(this.autoOk
          ? '上面这些行为已经自动记进账本、积分也加好了，不需要再点。想改数量可以到历史记录里删掉重记。'
          : (this.recog.hasLowCarbon
            ? '这次没有自动入账。点一条候选可以手动补记（会先填好分类和数量，再点一键记录）。'
            : '模型没在画面里看到低碳行为。换张更贴近的照片，或者直接在下面手动选。'))
          .fontSize(11)
          .fontColor(Palette.textSub)
          .width('100%')
          .lineHeight(17)
      }

      Scroll() {
        Column({ space: 8 }) {
          if (!this.recogBusy && this.recog.ok && this.recog.tags.length === 0) {
            Text(this.emptyRecogText())
              .fontSize(11)
              .fontColor(Palette.textLight)
              .width('100%')
              .lineHeight(17)
          }
          ForEach(this.recog.tags, (t: RecogTag) => {
            Row({ space: 10 }) {
              Text(t.icon)
                .fontSize(20)
                .width(38)
                .height(38)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F4F7F5')
                .borderRadius(11)

              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  Text(t.activityName)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text)
                  if (t.point > 0) {
                    Text(`基础分 +${t.point}`)
                      .fontSize(9)
                      .fontColor(Palette.warn)
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('#FBF2DF')
                      .borderRadius(5)
                  }
                }
                .alignItems(VerticalAlign.Center)

                Text(`${this.categoryName(t.categoryId)} · ${t.activityId}`)
                  .fontSize(10)
                  .fontColor(Palette.textLight)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(this.isAutoAdded(t) ? '已记账' : '手动补记')
                .fontSize(11)
                .fontColor(this.isAutoAdded(t) ? Palette.textLight : this.p())
            }
            .width('100%')
            .padding(11)
            .backgroundColor(Palette.card)
            .borderRadius(13)
            .border({ width: 1, color: this.isAutoAdded(t) ? this.p() : Palette.line })
            .onClick(() => {
              // 已自动入账的条目不再重复写一遍，避免用户点了"手动补记"又点一键记录造成重复
              if (this.isAutoAdded(t)) {
                DialogUtil.toast(this.getUIContext(), `「${t.activityName}」已经自动记过了`);
                return;
              }
              this.applyRecog(t);
            })
          }, (t: RecogTag) => `${t.activityId}_${this.isAutoAdded(t)}`)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)


      Row({ space: 10 }) {
        Text('换张照片')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p())
          .layoutWeight(1)
          .height(42)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.pl())
          .borderRadius(12)
          .onClick(() => {
            // 正在识别时不允许再拉图库，否则两轮请求会互相覆盖状态
            if (this.recogBusy) {
              return;
            }
            // 先收起结果弹层：弹层还在时再拉图库，图库会被压在弹层下面看不见
            this.showRecog = false;
            this.doRecognize();
          })
        Text('关闭')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.textSub)
          .layoutWeight(1)
          .height(42)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F2F4F3')
          .borderRadius(12)
          .onClick(() => {
            this.showRecog = false;
          })
      }
      .width('100%')

      Text(this.recogBusy
        ? '正在识别，请稍候'
        : '图片只发给设置里填的那个模型接口，App 不保存图片')
        .fontSize(9)
        .fontColor(Palette.textLight)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 12 })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 分类横向选择
        Row({ space: 8 }) {
          ForEach(CATEGORIES, (c: Category) => {
            this.CategoryChip(c)
          }, (c: Category) => `${c.id}_${this.activeCat === c.id}`)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8 })

        // 当前分类说明
        Row({ space: 6 }) {
          Text(this.currentCatIcon())
            .fontSize(14)
          Text(this.currentCatDesc())
            .fontSize(11)
            .fontColor(Palette.textSub)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        // 图片智能识别入口（调本地部署的视觉模型，命中即自动记账）
        Column() {
          Row({ space: 10 }) {
            Text('📷')
              .fontSize(18)
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.pl())
              .borderRadius(10)

            Column({ space: 2 }) {
              Text('图片智能识别')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.text)
              Text(this.recogHint())
                .fontSize(10)
                .fontColor(Palette.textLight)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(this.recogBtnText())
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor(this.p())
              .borderRadius(9)
              .opacity(this.recogBusyNow() ? 0.6 : 1)
          }
          .width('100%')
          .padding(11)
          .backgroundColor(Palette.card)
          .borderRadius(14)
          .border({ width: 1, color: Palette.line })
          .onClick(() => {
            if (this.recogBusyNow()) {
              return;
            }
            this.doRecognize();
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })

        // 行为列表：点中某项后在该项下方展开录入区
        Column({ space: 8 }) {
          ForEach(carbonStore.activitiesOf(this.activeCat), (a: Activity) => {
            this.ActivityItem(a)
          }, (a: Activity) => `${a.id}_${this.isOpen(a)}`)
        }
        .width('100%')
        .padding({ left: 14, right: 14 })

        Text('减排量按公开数据估算，只用于比较和鼓励，不能当作碳交易依据')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 30, right: 30, bottom: 20 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .bindSheet(this.showRecog, this.RecogSheet(), {
      height: 460,
      dragBar: true,
      showClose: true,
      title: { title: '图片智能识别' },
      onAppear: () => {
        this.sheetShown = true;
        hilog.info(0x0000, RECOG_TAG, 'sheet appeared');
      },
      onDisappear: () => {
        this.sheetShown = false;
        hilog.info(0x0000, RECOG_TAG, 'sheet disappeared');
      }
    })
  }

  currentCatIcon(): string {
    const c = carbonStore.getCategoryById(this.activeCat);
    return c === undefined ? '' : c.icon;
  }

  currentCatDesc(): string {
    const c = carbonStore.getCategoryById(this.activeCat);
    return c === undefined ? '' : c.desc;
  }
}
