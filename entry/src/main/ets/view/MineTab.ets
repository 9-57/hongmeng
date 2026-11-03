import {
  CertificateInfo, DirectoryUser, FamilyInfo, FamilyInvite, FamilyMember, FamilySummary, LevelInfo, MonthReview,
  Summary
} from '../model/CarbonModels';
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { auth } from '../service/AuthService';
import { cityService } from '../service/CityService';
import { cloudAccount } from '../service/CloudAccount';
import { notificationService } from '../service/NotificationService';
import { familyService } from '../service/FamilyService';
import { carbonStore, BadgeState } from '../viewmodel/CarbonStore';
import { fileService } from '../service/FileService';
import { carbonBank, BankOffer, BankOrder } from '../service/CarbonBankService';
import { SkinService } from '../service/SkinService';
import { AIConfig, AIRecognitionService } from '../service/AIRecognitionService';
import { requireLogin } from '../service/AccountGate';
import { bumpDataVersion, fmtKg, formatDate, formatDateTime, requestHonorView, round } from '../common/Utils';
import { DialogUtil } from '../common/DialogUtil';
import { Palette, SKINS, SkinDef } from '../common/Theme';
import { EmptyBox, ProgressBar } from '../common/Widgets';

/** 导出到用户目录的文本摘要文件名 */
const TEXT_REPORT_FILE = 'carbon_summary.txt';

/** 权益展示态：把"剩余库存"这类派生值在刷新时算好，避免 build 里反复数流水 */
class OfferView {
  offer: BankOffer;
  remain: number = 0;

  constructor(offer: BankOffer, remain: number) {
    this.offer = offer;
    this.remain = remain;
  }
}

/** 碳普惠账户展示态（整体替换以触发刷新） */
class BankView {
  bound: boolean = false;
  city: string = '';
  accountNo: string = '';
  bankPoint: number = 0;
  totalIn: number = 0;
  totalOut: number = 0;
}

@Component
export struct MineTab {
  /** 由主页面传入的刷新令牌，值变化即重新取数 */
  @Prop @Watch('onTokenChange') token: number = 0;
  @State summary: Summary = new Summary();
  @State badges: BadgeState[] = [];
  @State redeemables: BadgeState[] = [];
  @State level: LevelInfo = new LevelInfo();
  /** 月度复盘一次性聚合结果，避免 build 里反复扫全量记录 */
  @State review: MonthReview = new MonthReview();
  @State csvText: string = '';
  @State goalInput: string = '';
  @State nick: string = '';
  /** 登录态与账号信息：未登录时只展示本机数据 */
  @State loggedIn: boolean = false;
  @State username: string = '';
  /** 已获得的电子证书（与徽章一一对应，按账号在本机保存） */
  @State certificates: CertificateInfo[] = [];
  /** 当前打开的证书 id，非空时弹出全屏证书 */
  @State openCertId: string = '';
  /** 分享成绩卡片 */
  @State showShare: boolean = false;
  /** 状态栏实况窗（通知）是否已授权 */
  @State notifyEnabled: boolean = false;
  /** 家庭 */
  @State familyJoined: boolean = false;
  @State family: FamilyInfo = new FamilyInfo();
  @State familySum: FamilySummary = new FamilySummary();
  @State familyMyId: string = '';
  @State showFamily: boolean = false;
  /** home=家庭首页，search=组建/加入搜索，add=邀请成员 */
  @State familyMode: string = 'home';
  @State familySearch: string = '';
  @State familyResults: DirectoryUser[] = [];
  /** 收到的待处理邀请 */
  @State familyIncoming: FamilyInvite[] = [];
  /** 自己发出、还没被处理的邀请 */
  @State familyOutgoing: FamilyInvite[] = [];
  /** 家庭相关请求进行中（避免连点重复提交） */
  @State familyBusy: boolean = false;
  /** 家庭接口的最近一次错误，常驻显示在页面顶部 */
  @State familyError: string = '';
  @State familySearching: boolean = false;
  @State familyNameInput: string = '';
  /** 搜索防抖定时器 */
  private familySearchTimer: number = -1;
  /** 备份状态 */
  @State backupExists: boolean = false;
  @State backupBytes: number = 0;
  @State backupTime: string = '';
  /** 详情面板：只绑一个 bindSheet，按 sheetKind 切换内容（同一组件上多次 bindSheet 只有一处生效） */
  @State showSheet: boolean = false;
  @State sheetKind: string = '';
  /** 个人荣誉面板当前分类：badge 徽章 / cert 证书 / award 奖状 */
  @State honorTab: string = 'badge';
  /** 当前皮肤：AppStorage 里的值，切换后用于高亮色块 */
  @StorageProp('skinId') skinId: string = 'original';
  /**
   * 全局数据版本。登录/退出会 bump 它，这里跟着刷新一次登录态。
   * 为什么不只靠父组件的 @Prop token：从登录页 router.back() 回来时，
   * 父页面 onPageShow 的 token 自增并不总能传到已挂载的 Tab 上，
   * 会出现"已经登录了，本页还显示登录/注册"的情况。
   */
  @StorageProp('carbonVersion') @Watch('onCloudVersion') cloudVersion: number = 0;
  /** 家庭邀请浮层请求打开家庭页（Index 写 tick，这里消费） */
  @StorageProp('familyOpenTick') @Watch('onFamilyOpenTick') familyOpenTick: number = 0;
  @State bank: BankView = new BankView();
  @State offers: OfferView[] = [];
  @State bankOrders: BankOrder[] = [];
  /** AI 图片识别配置（与「记一笔」里的识别共用同一份存储） */
  @State aiEnabled: boolean = false;
  @State aiBaseUrl: string = '';
  @State aiApiKey: string = '';
  @State aiModel: string = '';
  /** 测试连接的结论，空串表示还没测过 */
  @State aiTest: string = '';
  @State aiTestOk: boolean = false;
  @State aiTesting: boolean = false;
  @State transferInput: string = '100';
  @State bankBusy: boolean = false;
  /** 面板重开定时器：要等关闭动画结束再以新类型重开，中途重建会偶现崩溃 */
  private reopenTimer: number = -1;
  /** 荣誉放大弹层的请求定时器：先关面板，等关闭动画结束再弹，否则弹层会被面板盖住 */
  private honorTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.refreshBackupState();
    // 存储读取是异步的，首次进入时若还没读完，读完后再刷新一次
    carbonStore.ensureLoaded(() => {
      this.refresh();
    });
    carbonBank.ensureLoaded().then(() => {
      this.refreshBank();
    });
    this.refreshNotifyState();
    familyService.ensureLoaded(() => {
      this.refreshFamily();
      // 缓存先渲染，再拉云端（登录态才拉，未登录直接空态）
      this.syncFamily(true);
    });
    this.loadAIConfig();
    // 如果是从首页的「家庭邀请」浮层点进来的，这里把家庭页打开
    this.consumeFamilyOpenRequest();
  }

  /**
   * 家庭邀请浮层（Index）想让我打开家庭页：它只往 AppStorage 里写标志位。
   * 这里既监听 tick，也在挂载时主动查一次 —— Tab 可能是刚被切过来才创建的，
   * 那时 Watch 已经错过了那次变化。
   */
  consumeFamilyOpenRequest(): void {
    const pending = AppStorage.get<boolean>('familyOpenPending');
    if (pending === true) {
      AppStorage.setOrCreate('familyOpenPending', false);
      this.openFamily();
    }
  }

  onFamilyOpenTick(): void {
    this.consumeFamilyOpenRequest();
  }

  /** 读 AI 识别配置到面板状态 */
  async loadAIConfig(): Promise<void> {
    const cfg = await AIRecognitionService.loadConfig();
    this.aiEnabled = cfg.enabled;
    this.aiBaseUrl = cfg.baseUrl;
    this.aiApiKey = cfg.apiKey;
    this.aiModel = cfg.model;
  }

  /** 保存 AI 配置，并把面板切回个人设置 */
  async onSaveAI(): Promise<void> {
    const cfg = new AIConfig();
    cfg.enabled = this.aiEnabled;
    cfg.baseUrl = this.aiBaseUrl.trim();
    cfg.apiKey = this.aiApiKey.trim();
    cfg.model = this.aiModel.trim();
    if (cfg.enabled && (cfg.baseUrl.length === 0 || cfg.model.length === 0)) {
      DialogUtil.toast(this.getUIContext(), '开启 AI 识别需要先填接口地址和模型名称');
      return;
    }
    await AIRecognitionService.saveConfig(cfg);
    DialogUtil.toast(this.getUIContext(), cfg.enabled ? '已开启 AI 识别' : '已关闭 AI 识别');
    this.sheetKind = 'settings';
  }

  /**
   * 测一次连通性。
   * 之所以放在设置里而不是等识别失败才提示：识别流程一旦失败只能给一句
   * "连不上"，而这里能分清是地址错、Key 错、还是服务没开。
   */
  async onTestAI(): Promise<void> {
    if (this.aiTesting) {
      return;
    }
    this.aiTesting = true;
    this.aiTest = '正在测试…';
    this.aiTestOk = false;
    const base = this.aiBaseUrl.trim();
    const r = await AIRecognitionService.probe(base, this.aiApiKey.trim());
    this.aiTestOk = r.ok;
    if (r.suggest.length > 0) {
      this.aiBaseUrl = r.suggest;
      this.aiTest = `已自动改成 ${r.suggest}，点保存生效`;
    } else if (r.ok) {
      this.aiTest = r.message;
    } else {
      this.aiTest = r.message;
    }
    this.aiTesting = false;
  }

  /** 个人设置里那一行 AI 的摘要文案 */
  aiSummary(): string {
    if (!this.aiEnabled) {
      return '未开启：图片识别不可用，需先填写本地模型接口';
    }
    if (this.aiModel.length === 0) {
      return '已开启，但还没填模型名称';
    }
    return `已开启 · ${this.aiModel} · 识别后自动记账`;
  }

  aboutToDisappear(): void {
    this.cancelReopen();
    if (this.honorTimer !== -1) {
      clearTimeout(this.honorTimer);
      this.honorTimer = -1;
    }
    this.clearFamilySearchTimer();
  }

  /**
   * 只随数据版本刷新业务数据。
   * 备份文件状态只会被本页的备份/恢复操作改变，没必要每次数据变化都去读一遍
   * 可能上百 KB 的备份文件并 parse（原来每次 token 变化都会这么做）。
   */
  onTokenChange(): void {
    this.refresh();
    this.refreshBank();
  }

  /** 云端数据版本变化（登录、退出、记账同步）：只刷本地展示，不额外打网络 */
  onCloudVersion(): void {
    this.refresh();
  }

  refresh(): void {
    this.loggedIn = auth.isLoggedIn;
    this.username = auth.username;
    this.summary = carbonStore.getSummary();
    this.badges = carbonStore.getBadgeStates();
    this.redeemables = carbonStore.getRedeemStates();
    this.certificates = carbonStore.certificates();
    this.level = carbonStore.levelInfo();
    this.review = carbonStore.monthReview(0);
    this.goalInput = `${carbonStore.monthGoal}`;
    this.nick = carbonStore.nickName;
    this.refreshFamily();
  }

  /** 刷新碳普惠账户的展示态（存的是快照，必须整体替换才会触发重绘） */
  refreshBank(): void {
    const a = carbonBank.account;
    const v = new BankView();
    v.bound = a.bound;
    v.city = a.city;
    v.accountNo = a.accountNo;
    v.bankPoint = a.bankPoint;
    v.totalIn = a.totalIn;
    v.totalOut = a.totalOut;
    this.bank = v;
    this.offers = carbonBank.offers().map((o: BankOffer) => new OfferView(o, carbonBank.remain(o)));
    this.bankOrders = carbonBank.recentOrders(5);
  }

  bump(): void {
    bumpDataVersion();
  }

  @Styles
  cardStyle() {
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(18)
    .shadow({ radius: 14, color: '#081F3D12', offsetY: 4 })
  }

  /** 个人资料卡：深绿渐变，与碳账本顶部的浅色动态卡形成区分 */
  @Builder
  ProfileCard() {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        Text('🌿')
          .fontSize(26)
          .width(58)
          .height(58)
          .textAlign(TextAlign.Center)
          .backgroundColor('#33FFFFFF')
          .borderRadius(29)

        Column({ space: 4 }) {
          Text(this.nick.length > 0 ? this.nick : '低碳同学')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(this.level.code)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .padding({ left: 7, right: 7, top: 1, bottom: 1 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(6)
            Text(this.level.title)
              .fontSize(11)
              .fontColor('#D9FFFFFF')
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 1 }) {
          Text(`${this.summary.totalPoint}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text('碳积分')
            .fontSize(10)
            .fontColor('#B3FFFFFF')
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 5 }) {
        Row() {
          Text('升级进度')
            .fontSize(10)
            .fontColor('#D9FFFFFF')
          Blank()
          Text(this.level.isMax ? '已达最高等级' : `再减 ${this.level.nextNeed} kg 就升级`)
            .fontSize(10)
            .fontColor('#B3FFFFFF')
        }
        .width('100%')

        ProgressBar({ progress: this.level.progress, color: '#FFFFFF', barHeight: 6 })
      }
      .width('100%')

      Row({ space: 8 }) {
        this.ProfileStat('累计减排', 'total')
        this.ProfileStat('记录次数', 'count')
        this.ProfileStat('连续打卡', 'streak')
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .linearGradient({ angle: 135, colors: this.profileColors() })
    .borderRadius(20)
    .shadow({ radius: 16, color: this.profileShadow(), offsetY: 6 })
  }

  /** 值在构建时直接读状态；通过 @Builder 值参数传入会导致数据变化后不刷新 */
  headValue(kind: string): string {
    if (kind === 'total') {
      return `${fmtKg(this.summary.totalReduction)} kg`;
    }
    if (kind === 'count') {
      return `${this.summary.totalCount} 次`;
    }
    return `${this.summary.streakDays} 天`;
  }

  @Builder
  ProfileStat(label: string, kind: string) {
    Column({ space: 3 }) {
      Text(this.headValue(kind))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(10)
        .fontColor('#B3FFFFFF')
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#26FFFFFF')
    .borderRadius(12)
  }

  /** 徽章详情行：图标 + 名称/说明 + 进度 */
  @Builder
  BadgeDetailRow(st: BadgeState) {
    Row({ space: 12 }) {
      Text(st.unlocked ? st.badge.icon : '🔒')
        .fontSize(20)
        .width(42)
        .height(42)
        .textAlign(TextAlign.Center)
        .backgroundColor(st.unlocked ? this.pl() : '#F2F4F3')
        .borderRadius(12)
        .opacity(st.unlocked ? 1 : 0.7)

      Column({ space: 2 }) {
        Text(st.badge.name)
          .fontSize(13)
          .fontColor(st.unlocked ? Palette.text : Palette.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(st.badge.desc)
          .fontSize(10)
          .fontColor(Palette.textLight)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(st.unlocked ? '已获得' : st.progressText)
        .fontSize(10)
        .fontColor(st.unlocked ? this.p() : Palette.textLight)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor(st.unlocked ? this.pl() : '#F2F4F3')
        .borderRadius(8)

      if (st.unlocked) {
        Text('›')
          .fontSize(14)
          .fontColor(Palette.textLight)
          .margin({ left: 2 })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      this.openHonor(st);
    })
  }

  @Builder
  RedeemRow(st: BadgeState) {
    Row({ space: 12 }) {
      Text(st.badge.icon)
        .fontSize(20)
        .width(42)
        .height(42)
        .textAlign(TextAlign.Center)
        .backgroundColor(st.unlocked ? this.pl() : '#F4F7F5')
        .borderRadius(12)
        .opacity(st.unlocked ? 1 : 0.6)

      Column({ space: 2 }) {
        Text(st.badge.name)
          .fontSize(13)
          .fontColor(st.unlocked ? Palette.text : Palette.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(st.badge.desc)
          .fontSize(10)
          .fontColor(Palette.textLight)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (st.unlocked) {
        Text('已获得')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor('#F2F4F3')
          .borderRadius(9)
      } else {
        Text(`${st.badge.cost} 分兑换`)
          .fontSize(11)
          .fontColor(this.summary.totalPoint >= st.badge.cost ? '#FFFFFF' : Palette.textLight)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.summary.totalPoint >= st.badge.cost ? this.p() : '#F2F4F3')
          .borderRadius(9)
          .onClick(() => {
            this.onRedeem(st);
          })
      }
    }
    .width('100%')
  }

  /** 功能入口行：小图标 + 标题 + 箭头，点击打开对应详情面板 */
  @Builder
  MoreRow(icon: string, title: string, kind: string) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(15)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F4F7F5')
        .borderRadius(10)

      Text(title)
        .fontSize(14)
        .fontColor(Palette.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('>')
        .fontSize(14)
        .fontColor(Palette.textLight)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.openMore(kind);
    })
  }

  @Builder
  RowDivider() {
    Divider()
      .color(Palette.line)
      .margin({ left: 46 })
  }

  openMore(kind: string): void {
    // 家庭是整页覆盖式交互，不走底部面板
    if (kind === 'family') {
      this.openFamily();
      return;
    }
    this.cancelReopen();
    this.sheetKind = kind;
    this.showSheet = true;
    // 打开实况窗面板时重新问一次系统权限：用户可能刚在设置里打开/关闭了通知，
    // 只靠 aboutToAppear 那一次会一直显示旧状态（真实踩到）。
    if (kind === 'notify') {
      this.refreshNotifyState();
    }
  }

  cancelReopen(): void {
    if (this.reopenTimer >= 0) {
      clearTimeout(this.reopenTimer);
      this.reopenTimer = -1;
    }
  }

  /** 面板内容在打开时构建，直接改类型不会刷新；先关闭，等关闭动画结束后再以新类型重开 */
  reopenSheet(kind: string): void {
    this.cancelReopen();
    this.showSheet = false;
    this.reopenTimer = setTimeout(() => {
      this.reopenTimer = -1;
      this.sheetKind = kind;
      this.showSheet = true;
    }, 400);
  }

  /** 面板标题随类型变化 */
  sheetTitle(): string {
    if (this.sheetKind === 'account') {
      return this.loggedIn ? '账号与云端' : '登录 / 注册';
    }
    if (this.sheetKind === 'notify') {
      return '状态栏实况窗';
    }
    if (this.sheetKind === 'certs') {
      return '我的证书';
    }
    if (this.sheetKind === 'honors') {
      return '个人荣誉';
    }
    if (this.sheetKind === 'redeem') {
      return '积分兑换';
    }
    if (this.sheetKind === 'settings') {
      return '个人设置';
    }
    if (this.sheetKind === 'ai') {
      return 'AI 图片识别';
    }
    if (this.sheetKind === 'data') {
      return '数据管理';
    }
    if (this.sheetKind === 'bank') {
      return '城市碳普惠';
    }
    if (this.sheetKind === 'csv') {
      return '数据预览';
    }
    return '关于本应用';
  }

  /** 面板高度随内容变化 */
  sheetHeight(): number {
    if (this.sheetKind === 'account') {
      return 460;
    }
    if (this.sheetKind === 'notify') {
      return 420;
    }
    if (this.sheetKind === 'certs') {
      return 520;
    }
    if (this.sheetKind === 'honors') {
      return 560;
    }
    if (this.sheetKind === 'redeem') {
      return 520;
    }
    if (this.sheetKind === 'settings') {
      return 540;
    }
    if (this.sheetKind === 'ai') {
      // 去掉「把握下限」后内容变短，面板高度同步收紧，避免底部大片空白
      return 600;
    }
    if (this.sheetKind === 'data') {
      return 440;
    }
    if (this.sheetKind === 'bank') {
      return 700;
    }
    if (this.sheetKind === 'csv') {
      return 520;
    }
    return 420;
  }

  /** 面板内容按类型路由 */
  @Builder
  SheetBody() {
    if (this.sheetKind === 'account') {
      this.AccountSheet()
    } else if (this.sheetKind === 'notify') {
      this.NotifySheet()
    } else if (this.sheetKind === 'certs') {
      this.CertSheet()
    } else if (this.sheetKind === 'honors') {
      this.HonorsSheet()
    } else if (this.sheetKind === 'redeem') {
      this.RedeemSheet()
    } else if (this.sheetKind === 'settings') {
      this.SettingsSheet()
    } else if (this.sheetKind === 'ai') {
      this.AISheet()
    } else if (this.sheetKind === 'data') {
      this.DataSheet()
    } else if (this.sheetKind === 'bank') {
      this.BankSheet()
    } else if (this.sheetKind === 'csv') {
      this.CsvSheet()
    } else {
      this.AboutSheet()
    }
  }

  async onRedeem(st: BadgeState): Promise<void> {
    // 扣的是账号积分：未登录不进入兑换流程
    if (!(await requireLogin(this.getUIContext(), '兑换徽章'))) {
      return;
    }
    const ok = await carbonStore.redeem(st.badge.id);
    if (ok) {
      // 收起兑换面板，让全局荣誉弹层盖到「我的」页上
      this.showSheet = false;
      this.refresh();
      this.bump();
    } else {
      DialogUtil.toast(this.getUIContext(), '积分不足，继续记录低碳行为吧');
    }
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          this.ProfileCard()

          // ===== 月度复盘 =====
          this.ReviewCard()

          // ===== 功能入口：每项一行，点击查看详情 =====
          Column() {
            this.MoreRow(this.loggedIn ? '👤' : '🔑', this.loggedIn ? '账号与云端' : '登录 / 注册', 'account')
            this.RowDivider()
            this.MoreRow('🏡', '我的家庭', 'family')
            this.RowDivider()
            this.MoreRow('📜', '我的证书', 'certs')
            this.RowDivider()
            this.MoreRow('🔔', '状态栏实况窗', 'notify')
            this.RowDivider()
            this.MoreRow('🏅', '个人荣誉', 'honors')
            this.RowDivider()
            this.MoreRow('🎁', '积分兑换', 'redeem')
            this.RowDivider()
            this.MoreRow('⚙️', '个人设置', 'settings')
            this.RowDivider()
            this.MoreRow('📦', '数据管理', 'data')
            this.RowDivider()
            this.MoreRow('🏙️', '城市碳普惠', 'bank')
            this.RowDivider()
            this.MoreRow('ℹ️', '关于本应用', 'about')
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
      .bindSheet(this.showSheet, this.SheetBody(), {
        height: this.sheetHeight(),
        dragBar: true,
        showClose: true,
        title: { title: this.sheetTitle() },
        // 用返回键/下滑关闭面板时，回调不一定走我们的关闭按钮；
        // 不同步 showSheet 的话状态会停在"已打开"，之后点同一个入口
        // 因为 showSheet 仍为 true 而没有任何反应（走查时踩到过）。
        onDisappear: () => {
          this.showSheet = false;
        }
      })

      // ===== 全屏覆盖层：家庭 / 证书 / 分享成绩 =====
      if (this.showFamily) {
        this.FamilyCover()
      }
      if (this.openCertId.length > 0) {
        this.CertificateCover()
      }
      if (this.showShare) {
        this.ShareCover()
      }
    }
    .width('100%')
    .height('100%')
  }

  refreshNotifyState(): void {
    notificationService.isEnabled().then((enabled: boolean) => {
      this.notifyEnabled = enabled;
    });
  }

  /**
   * 只随数据版本刷新业务数据。
   * 备份文件状态只会被本页的备份/恢复操作改变，没必要每次数据变化都去读一遍
   * 可能上百 KB 的备份文件并 parse（原来每次 token 变化都会这么做）。
   */

  /** 家庭状态从 service 同步到页面 state；FamilyInfo 做一次拷贝，避免同引用不触发刷新 */
  refreshFamily(): void {
    this.familyJoined = familyService.hasFamily();
    this.familyMyId = familyService.myId();
    const src = familyService.family();
    const copy = new FamilyInfo();
    copy.id = src.id;
    copy.name = src.name;
    copy.inviteCode = src.inviteCode;
    copy.ownerId = src.ownerId;
    copy.createdAt = src.createdAt;
    copy.memberLimit = src.memberLimit;
    copy.members = src.members.map((m: FamilyMember) => m.copy());
    this.family = copy;
    this.familyIncoming = familyService.incoming().map((v: FamilyInvite) => v.copy());
    this.familyOutgoing = familyService.outgoing().map((v: FamilyInvite) => v.copy());
    this.familySum = familyService.summary(this.summary);
  }

  /** 拉云端家庭状态；silent=true 时失败不弹窗（进页面自动刷新用） */
  async syncFamily(silent: boolean): Promise<void> {
    if (!this.loggedIn) {
      this.refreshFamily();
      return;
    }
    if (this.familyBusy) {
      return;
    }
    this.familyBusy = true;
    const err = await familyService.refresh();
    this.familyBusy = false;
    if (err.length > 0) {
      this.familyError = err;
      if (!silent) {
        DialogUtil.toast(this.getUIContext(), err);
      }
      return;
    }
    this.familyError = '';
    this.refreshFamily();
    // 在组建页等待期间对方同意了：数据里已经有家庭，页面要自动切过去
    if (this.familyJoined && this.familyMode === 'search') {
      this.familyMode = 'home';
      this.familySearch = '';
      this.familyResults = [];
    }
  }

  // ==================== 家庭 ====================

  openFamily(): void {
    // 家庭数据跟账号绑定：未登录时先引导登录。
    // 这里读 auth 而不是 this.loggedIn：本页的 loggedIn 是上次 refresh 的快照，
    // 刚登录完还没刷新时会是 false，导致误拦。
    if (!auth.isLoggedIn) {
      this.showSheet = false;
      DialogUtil.confirm(this.getUIContext(), '组建家庭需要账号',
        '家庭数据与账号绑定，登录后可以按用户名或昵称找到家人，和家人一起看减排。', '去登录', this.p())
        .then((ok: boolean) => {
          if (ok) {
            router.pushUrl({ url: 'pages/Login' });
          }
        });
      return;
    }
    this.showFamily = true;
    this.familyMode = familyService.hasFamily() ? 'home' : 'search';
    this.familySearch = '';
    this.familyResults = [];
    this.familyError = '';
    this.familyNameInput = `${this.nick.length > 0 ? this.nick : '我们'}的低碳家庭`;
    // 先用缓存渲染，再拉云端；这样点进来不会白屏
    this.refreshFamily();
    this.syncFamily(true);
  }

  closeFamily(): void {
    this.showFamily = false;
    this.clearFamilySearchTimer();
  }

  familyBack(): void {
    if (this.familyJoined && this.familyMode !== 'home') {
      this.familyMode = 'home';
      this.familySearch = '';
      this.familyResults = [];
      this.clearFamilySearchTimer();
      return;
    }
    this.showFamily = false;
  }

  private clearFamilySearchTimer(): void {
    if (this.familySearchTimer !== -1) {
      clearTimeout(this.familySearchTimer);
      this.familySearchTimer = -1;
    }
    this.familySearching = false;
  }

  /** 输入防抖 400ms：每敲一个字就打一次接口既慢又容易被上一次结果覆盖 */
  onFamilySearch(value: string): void {
    this.familySearch = value;
    this.clearFamilySearchTimer();
    const kw = value.trim();
    if (kw.length === 0) {
      this.familyResults = [];
      return;
    }
    this.familySearching = true;
    this.familySearchTimer = setTimeout(() => {
      this.familySearchTimer = -1;
      this.runFamilySearch(kw);
    }, 400);
  }

  async runFamilySearch(keyword: string): Promise<void> {
    const list = await familyService.search(keyword);
    // 期间用户又改了输入，丢弃这次结果
    if (this.familySearch.trim() !== keyword) {
      return;
    }
    this.familyResults = list;
    this.familySearching = false;
  }

  /** 重新搜一次当前关键词（邀请成功/撤回后刷新"已邀请"状态） */
  refreshFamilyResults(): void {
    const kw = this.familySearch.trim();
    if (kw.length > 0) {
      this.runFamilySearch(kw);
    }
  }

  isInvited(userId: string): boolean {
    for (const inv of this.familyOutgoing) {
      if (inv.inviteeId === userId) {
        return true;
      }
    }
    return false;
  }

  /** 邀请前先问一句，避免误点 */
  async onInviteUser(user: DirectoryUser): Promise<void> {
    if (this.familyBusy) {
      return;
    }
    if (user.hasFamily()) {
      DialogUtil.toast(this.getUIContext(), `${user.name} 已经在别的家庭里了`);
      return;
    }
    const familyName = this.familyJoined ? this.family.name : this.familyNameInput.trim();
    if (familyName.length === 0) {
      DialogUtil.toast(this.getUIContext(), '请先给家庭起个名字');
      return;
    }
    const action = this.familyJoined ? `加入「${familyName}」` : `一起组建「${familyName}」`;
    const ok = await DialogUtil.confirm(this.getUIContext(), '邀请成员',
      `是否邀请「${user.name}」（${user.username}）${action}？\n对方同意后家庭才会建立。`,
      '发送邀请', this.p());
    if (!ok) {
      return;
    }
    this.familyBusy = true;
    const r = await familyService.invite(user.id, familyName);
    this.familyBusy = false;
    if (!r.ok) {
      DialogUtil.toast(this.getUIContext(), r.message);
      this.refreshFamily();
      return;
    }
    this.refreshFamily();
    this.refreshFamilyResults();
    DialogUtil.toast(this.getUIContext(), r.message.length > 0 ? r.message : '邀请已发送，等待对方同意');
  }

  async onAcceptInvite(inv: FamilyInvite): Promise<void> {
    if (this.familyBusy) {
      return;
    }
    const text = inv.hasFamily ?
      `「${inv.familyName}」的创建者 ${inv.nickname} 邀请你加入，同意后你将看到全家人的减排。` :
      `${inv.nickname} 想和你一起组建「${inv.familyName}」，同意后家庭即建立，对方是创建者。`;
    const ok = await DialogUtil.confirm(this.getUIContext(), '家庭邀请', text, '同意加入', this.p());
    if (!ok) {
      return;
    }
    this.familyBusy = true;
    const r = await familyService.accept(inv.inviteId);
    this.familyBusy = false;
    if (!r.ok) {
      DialogUtil.toast(this.getUIContext(), r.message);
      await this.syncFamily(true);
      return;
    }
    this.refreshFamily();
    this.familyMode = 'home';
    bumpDataVersion();
    DialogUtil.toast(this.getUIContext(), `已加入「${this.family.name}」`);
  }

  async onRejectInvite(inv: FamilyInvite): Promise<void> {
    if (this.familyBusy) {
      return;
    }
    const ok = await DialogUtil.confirm(this.getUIContext(), '拒绝邀请',
      `确定不加入「${inv.familyName}」吗？对方会看到你已拒绝。`, '拒绝', '#D9534F');
    if (!ok) {
      return;
    }
    this.familyBusy = true;
    const r = await familyService.reject(inv.inviteId);
    this.familyBusy = false;
    DialogUtil.toast(this.getUIContext(), r.ok ? '已拒绝该邀请' : r.message);
    this.refreshFamily();
  }

  async onCancelInvite(inv: FamilyInvite): Promise<void> {
    if (this.familyBusy) {
      return;
    }
    const ok = await DialogUtil.confirm(this.getUIContext(), '撤回邀请',
      `撤回发给「${inv.nickname}」的邀请？撤回后对方就不能再同意了。`, '撤回', '#D9534F');
    if (!ok) {
      return;
    }
    this.familyBusy = true;
    const r = await familyService.cancel(inv.inviteId);
    this.familyBusy = false;
    if (!r.ok) {
      DialogUtil.toast(this.getUIContext(), r.message);
      return;
    }
    this.refreshFamily();
    this.refreshFamilyResults();
    DialogUtil.toast(this.getUIContext(), '已撤回邀请');
  }

  async leaveFamily(): Promise<void> {
    const owner = familyService.isOwner();
    const confirmed = await DialogUtil.confirm(this.getUIContext(),
      owner ? '解散家庭' : '退出家庭',
      owner ? '解散后家庭成员都会被移出，家庭碳足迹不再保留，确定解散吗？' : '退出后你将看不到家庭汇总，确定退出吗？',
      owner ? '解散' : '退出', '#D9534F');
    if (!confirmed) {
      return;
    }
    this.familyBusy = true;
    const r = await familyService.leave();
    this.familyBusy = false;
    if (!r.ok) {
      DialogUtil.toast(this.getUIContext(), r.message);
      return;
    }
    this.refreshFamily();
    this.familyMode = familyService.hasFamily() ? 'home' : 'search';
    this.familySearch = '';
    this.familyResults = [];
    bumpDataVersion();
    DialogUtil.toast(this.getUIContext(),
      r.message.length > 0 ? r.message : (owner ? '家庭已解散' : '已退出家庭'));
  }
  isFamilyOwner(): boolean {
    return this.familyJoined && familyService.isOwner();
  }

  /** 某位成员本月减排：自己的数据取本地与云端的较大值，避免刚记完账还显示旧数 */
  familyMemberMonth(member: FamilyMember): number {
    if (!member.isMe) {
      return member.monthReduction;
    }
    return Math.max(member.monthReduction, this.summary.monthReduction);
  }

  familyMemberRatio(member: FamilyMember): number {
    const total = this.familySum.monthReduction;
    if (total <= 0) {
      return 0;
    }
    return Math.min(1, this.familyMemberMonth(member) / total);
  }

  familyMetricValue(kind: string): string {
    if (kind === 'month') {
      return fmtKg(this.familySum.monthReduction);
    }
    if (kind === 'today') {
      return fmtKg(this.familySum.todayReduction);
    }
    if (kind === 'total') {
      return fmtKg(this.familySum.totalReduction);
    }
    return fmtKg(this.familySum.treeCount);
  }

  familyMetricUnit(kind: string): string {
    return kind === 'tree' ? '棵·年' : 'kg';
  }

  familyMetricLabel(kind: string): string {
    if (kind === 'month') {
      return '家庭本月';
    }
    if (kind === 'today') {
      return '家庭今日';
    }
    if (kind === 'total') {
      return '家庭累计';
    }
    return '等效植树';
  }

  copyFamilyInvite(): void {
    try {
      const text = `加入我的低碳家庭「${this.family.name}」\n家庭邀请码：${this.family.inviteCode}\n一起记录低碳生活，为地球减负 🌍`;
      pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      );
      DialogUtil.toast(this.getUIContext(), '邀请信息已复制');
    } catch (e) {
      DialogUtil.toast(this.getUIContext(), '复制失败，请重试');
    }
  }

  /** 城市碳普惠入口：积分互通与权益兑换 */
  @Builder
  CityCard() {
    Row({ space: 12 }) {
      Text('🏙️')
        .fontSize(22)
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.pl())
        .borderRadius(14)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text('城市碳普惠')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text('积分互通')
            .fontSize(9)
            .fontColor(this.pd())
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor(this.pl())
            .borderRadius(5)
        }

        Text('10 碳积分 = 1 城市积分，可兑换城市权益')
          .fontSize(10)
          .fontColor(Palette.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(18)
        .fontColor(Palette.textLight)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .shadow({ radius: 12, color: '#0A1F3D14', offsetY: 3 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/CityCarbon' }).catch(() => {
        DialogUtil.toast(this.getUIContext(), '打开城市碳普惠页失败，请稍后重试');
      });
    })
  }

  @Builder
  FamilyCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('🏡')
          .fontSize(22)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFF4E2')
          .borderRadius(10)
        Column({ space: 2 }) {
          Text(this.familyJoined ? this.family.name : '我的家庭')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.familyJoined ?
            `${this.familySum.memberCount} 位成员 · 本月 ${fmtKg(this.familySum.monthReduction)} kg` :
            (this.familyIncoming.length > 0 ? `收到 ${this.familyIncoming.length} 条家庭邀请，去处理` :
              '搜索用户名或昵称，邀请家人一起记录'))
            .fontSize(10)
            .fontColor(this.familyIncoming.length > 0 && !this.familyJoined ? this.p() : Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.familyIncoming.length > 0) {
          Text(`${this.familyIncoming.length}`)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .width(16)
            .height(16)
            .textAlign(TextAlign.Center)
            .backgroundColor('#D9534F')
            .borderRadius(8)
        }

        Text(this.familyJoined ? '查看' : (this.familyIncoming.length > 0 ? '去处理' : '邀请家人'))
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.p())
          .borderRadius(9)
      }
      .width('100%')

      if (this.familyJoined) {
        Row({ space: 6 }) {
          ForEach(this.family.members.slice(0, 5), (m: FamilyMember) => {
            Text(m.avatar)
              .fontSize(15)
              .width(26)
              .height(26)
              .textAlign(TextAlign.Center)
              .backgroundColor('#F1F6F3')
              .borderRadius(13)
          }, (m: FamilyMember) => `${m.id}_${m.name}_${m.isMe}`)
          if (this.family.members.length > 5) {
            Text(`+${this.family.members.length - 5}`)
              .fontSize(10)
              .fontColor(Palette.textLight)
          }
          Blank()
          Text(`邀请码 ${this.family.inviteCode}`)
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .width('100%')
      }
    }
    .cardStyle()
    .onClick(() => {
      this.openFamily();
    })
  }

  @Builder
  HeadStat(label: string, kind: string) {
    Column({ space: 3 }) {
      Text(this.headValue(kind))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(label)
        .fontSize(9)
        .fontColor('#A9D6BE')
    }
    .layoutWeight(1)
  }

  @Builder
  BadgeCell(st: BadgeState) {
    Column({ space: 5 }) {
      Text(st.unlocked ? st.badge.icon : '🔒')
        .fontSize(24)
        .width(52)
        .height(52)
        .textAlign(TextAlign.Center)
        .backgroundColor(st.unlocked ? '#DFF2E7' : '#EDF0EE')
        .borderRadius(26)
        .opacity(st.unlocked ? 1 : 0.6)

      Text(st.badge.name)
        .fontSize(10)
        .fontColor(st.unlocked ? Palette.text : Palette.textLight)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(st.progressText)
        .fontSize(8)
        .fontColor(st.unlocked ? this.p() : Palette.textLight)
    }
    .width('25%')
    .padding({ top: 6, bottom: 6 })
  }

  /** 证书列表里的小卡片 */
  @Builder
  CertCard(info: CertificateInfo) {
    Column({ space: 4 }) {
      Text(info.badge.icon)
        .fontSize(26)
      Text(info.badge.name)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#4A3F28')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.certDate(info))
        .fontSize(9)
        .fontColor('#8C7A52')
      Text('查看证书')
        .fontSize(9)
        .fontColor(this.pd())
        .margin({ top: 2 })
    }
    .width(112)
    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
    .backgroundColor('#FBF6E9')
    .border({ width: 1, color: '#D9C79B' })
    .borderRadius(10)
    .onClick(() => {
      this.openCertificate(info.badge.id);
    })
  }

  /** 全屏证书弹层 */
  @Builder
  CertificateCover() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(28)
          .fontColor(Palette.text)
          .width(34)
          .onClick(() => {
            this.openCertId = '';
          })
        Text('我的证书')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })
      .backgroundColor('#F5F7F6')

      Scroll() {
        Column() {
          if (this.currentCertificate() !== null) {
            this.CertificatePaper(this.currentCertificate()!)
          }
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EFE9DA')
  }

  /** 证书正文：纸张、编号、颁发日期、印章 */
  @Builder
  CertificatePaper(info: CertificateInfo) {
    Column({ space: 8 }) {
      Row() {
        Text('CARBON FOOTPRINT')
          .fontSize(8)
          .letterSpacing(1.5)
          .fontColor('#8C7A52')
        Blank()
        Text(`NO. ${info.serial}`)
          .fontSize(8)
          .fontColor('#8C7A52')
      }
      .width('100%')

      Text('碳减排荣誉证书')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#2F3B2F')
        .letterSpacing(3)
      Text('CERTIFICATE OF CARBON REDUCTION')
        .fontSize(8)
        .letterSpacing(1.2)
        .fontColor('#9A8A62')

      Divider()
        .color('#D9C79B')
        .margin({ top: 4, bottom: 4 })

      Text('兹 证 明')
        .fontSize(11)
        .fontColor('#6B5E42')
        .letterSpacing(4)

      Text(carbonStore.nickName)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1F3D2A')

      Text('坚持践行低碳生活，为地球减少碳排放，')
        .fontSize(11)
        .fontColor('#5C5138')
        .lineHeight(19)
      Text(`特授予「${info.badge.name}」。`)
        .fontSize(11)
        .fontColor('#5C5138')
        .lineHeight(19)
      Text(info.badge.desc)
        .fontSize(10)
        .fontColor('#8A7A55')
        .lineHeight(17)
        .textAlign(TextAlign.Center)
        .width('100%')

      Row() {
        Column({ space: 2 }) {
          Text(fmtKg(this.summary.totalReduction))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F3D2A')
          Text('累计减排 kg')
            .fontSize(8)
            .fontColor('#8C7A52')
        }
        .layoutWeight(1)

        Column({ space: 2 }) {
          Text(this.certTreeText(info))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F3D2A')
          Text('等效植树')
            .fontSize(8)
            .fontColor('#8C7A52')
        }
        .layoutWeight(1)

        Column({ space: 2 }) {
          Text(`${this.summary.totalCount}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F3D2A')
          Text('低碳记录 条')
            .fontSize(8)
            .fontColor('#8C7A52')
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })

      Divider()
        .color('#E4D7B6')

      Row() {
        Column({ space: 2 }) {
          Text('颁发日期')
            .fontSize(8)
            .fontColor('#9A8A62')
          Text(this.certDate(info))
            .fontSize(11)
            .fontColor('#4A3F28')
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Column({ space: 2 }) {
          Text('证书编号')
            .fontSize(8)
            .fontColor('#9A8A62')
          Text(info.serial)
            .fontSize(10)
            .fontColor('#4A3F28')
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Row() {
        Blank()
        Column({ space: 1 }) {
          Text('🌿')
            .fontSize(20)
          Text('碳足迹项目组')
            .fontSize(7)
            .fontColor('#B5432F')
        }
        .width(68)
        .height(68)
        .justifyContent(FlexAlign.Center)
        .border({ width: 2, color: '#B5432F' })
        .borderRadius(34)
        .rotate({ angle: -12 })
        Blank()
      }
      .width('100%')
      .margin({ top: 8 })

      Text('本证书为「碳足迹」应用内低碳行为激励凭证，不作为碳交易或官方认证依据。')
        .fontSize(8)
        .fontColor('#A0936F')
        .textAlign(TextAlign.Center)
        .lineHeight(12)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor('#FCF8EC')
    .border({ width: 2, color: '#C9A961' })
    .borderRadius(8)
    .shadow({ radius: 16, color: '#332F1F', offsetY: 6 })
  }

  /** 复制分享文案到剪贴板（可粘贴到微信/QQ/微博） */
  async copyShareText(): Promise<void> {
    try {
      const text = carbonStore.buildShareText();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      DialogUtil.toast(this.getUIContext(), '分享文案已复制，去粘贴给朋友吧');
    } catch (e) {
      DialogUtil.toast(this.getUIContext(), '复制失败，请重试');
    }
  }

  /** 刷新实况窗；未授权时先申请，成功后同时开启 10 分钟自动推送 */
  async sendNotification(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) {
      DialogUtil.toast(this.getUIContext(), '当前环境不支持通知');
      return;
    }
    const ok = await notificationService.refreshLiveView(context);
    this.notifyEnabled = await notificationService.isEnabled();
    if (ok) {
      DialogUtil.toast(this.getUIContext(), '实况窗已刷新，每 10 分钟自动推送已开启');
      return;
    }
    // 拒绝过一次之后系统不再弹授权框，只能引导去设置里手动打开
    const go = await DialogUtil.confirm(this.getUIContext(), '通知被关闭了',
      '实况窗和状态栏灵动岛都依赖通知权限。系统不会再自动弹授权框，需要到设置里打开。',
      '去设置', this.pd());
    if (!go) {
      return;
    }
    const opened = await notificationService.openSettings(context);
    if (!opened) {
      DialogUtil.toast(this.getUIContext(),
        '打不开系统设置，请到「设置 → 通知和状态栏 → 碳足迹」手动开启');
    }
  }

  /** 打开系统通知设置（面板里的独立入口，避免用户找不到） */
  async openNotifySettings(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (context === undefined) {
      DialogUtil.toast(this.getUIContext(), '当前环境不支持通知');
      return;
    }
    const opened = await notificationService.openSettings(context);
    if (!opened) {
      DialogUtil.toast(this.getUIContext(),
        '打不开系统设置，请到「设置 → 通知和状态栏 → 碳足迹」手动开启');
    }
  }

  /** 全屏分享卡片：可截图，也可一键复制文案 */
  @Builder
  ShareCover() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(28)
          .fontColor(Palette.text)
          .width(34)
          .onClick(() => {
            this.showShare = false;
          })
        Text('分享我的减排成果')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 16 })
      .backgroundColor('#F5F7F6')

      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 8 }) {
            Row() {
              Text('🌱 碳足迹')
                .fontSize(12)
                .fontColor('#D6F0E2')
              Blank()
              Text('CARBON FOOTPRINT')
                .fontSize(8)
                .letterSpacing(1)
                .fontColor('#A9D6BE')
            }
            .width('100%')

            Text(this.nick.length > 0 ? this.nick : '低碳同学')
              .fontSize(13)
              .fontColor('#C9E4D5')
              .width('100%')

            Row({ space: 4 }) {
              Text(fmtKg(this.summary.totalReduction))
                .fontSize(48)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text('kg CO₂e')
                .fontSize(11)
                .fontColor('#C9E4D5')
                .margin({ bottom: 10 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)

            Text('累计减排')
              .fontSize(10)
              .fontColor('#A9D6BE')
              .width('100%')
            Text(`≈ ${fmtKg(this.summary.treeCount)} 棵树一年的固碳量`)
              .fontSize(10)
              .fontColor('#C9E4D5')
              .width('100%')

            Row() {
              Column({ space: 2 }) {
                Text(`${this.summary.streakDays} 天`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                Text('连续打卡')
                  .fontSize(8)
                  .fontColor('#A9D6BE')
              }
              .layoutWeight(1)

              Column({ space: 2 }) {
                Text(`${this.summary.totalCount} 条`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                Text('低碳记录')
                  .fontSize(8)
                  .fontColor('#A9D6BE')
              }
              .layoutWeight(1)

              Column({ space: 2 }) {
                Text(`${this.certificates.length} 张`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                Text('低碳证书')
                  .fontSize(8)
                  .fontColor('#A9D6BE')
              }
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .backgroundColor('#0F3D2A')
            .borderRadius(12)

            Row() {
              Text(`${this.level.code} ${this.level.title}`)
                .fontSize(10)
                .fontColor('#1B5E45')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .backgroundColor('#D6F0E2')
                .borderRadius(6)
              Blank()
              Text(`本月 ${fmtKg(this.summary.monthReduction)} kg`)
                .fontSize(10)
                .fontColor('#C9E4D5')
            }
            .width('100%')

            Divider()
              .color('#33FFFFFF')

            Text('“少开一次车，多走一段路。”')
              .fontSize(11)
              .fontColor('#D6F0E2')
              .width('100%')
            Text('碳足迹 · 全民绿色生活')
              .fontSize(9)
              .fontColor('#A9D6BE')
              .width('100%')
          }
          .width('100%')
          .padding(20)
          .borderRadius(20)
          .linearGradient({
            angle: 145,
            colors: [['#38A874', 0], ['#1B5E45', 1]]
          })

          Text('可截图保存卡片，或复制文案后粘贴到微信 / QQ / 微博')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .textAlign(TextAlign.Center)
            .width('100%')
            .lineHeight(16)
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      Row({ space: 10 }) {
        Row() {
          Text('复制分享文案')
            .fontSize(14)
            .fontColor('#FFFFFF')
        }
        .layoutWeight(1)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.p())
        .borderRadius(12)
        .onClick(() => {
          this.copyShareText();
        })

        Row() {
          Text('关闭')
            .fontSize(14)
            .fontColor(Palette.textSub)
        }
        .width(96)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#EDF0EE')
        .borderRadius(12)
        .onClick(() => {
          this.showShare = false;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 16 })
      .backgroundColor('#F5F7F6')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7F6')
  }

  // ==================== 家庭 UI ====================

  @Builder
  FamilyHeader() {
    Row({ space: 6 }) {
      Text('‹')
        .fontSize(28)
        .fontColor(Palette.text)
        .width(34)
        .onClick(() => {
          this.familyBack();
        })
      Text(this.familyMode === 'add' ? '邀请成员' : (this.familyJoined ? '我的家庭' : '组建家庭'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
      Blank()
      if (this.familyBusy) {
        Text('同步中…')
          .fontSize(9)
          .fontColor(Palette.textLight)
      } else if (this.familyJoined && this.familyMode === 'home') {
        Text(this.family.inviteCode)
          .fontSize(9)
          .fontColor(this.pd())
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(this.pl())
          .borderRadius(6)
          .onClick(() => {
            this.copyFamilyInvite();
          })
      }
      if (this.familyMode === 'home' && this.loggedIn) {
        Text('刷新')
          .fontSize(10)
          .fontColor(this.pd())
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.pl())
          .borderRadius(7)
          .onClick(() => {
            this.syncFamily(false);
          })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 12 })
    .backgroundColor('#F5F7F6')
  }

  /** 搜索结果行：右侧按"已有家庭 / 已邀请 / 邀请"三态切换 */
  @Builder
  FamilyUserRow(user: DirectoryUser) {
    Row({ space: 10 }) {
      Text(user.avatar)
        .fontSize(20)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F1F6F3')
        .borderRadius(10)
      Column({ space: 2 }) {
        Text(user.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`@${user.username}`)
          .fontSize(9)
          .fontColor(Palette.textLight)
        if (user.hasFamily()) {
          Text(user.inMyFamily ? '已和你在同一个家庭' : '已加入其他家庭')
            .fontSize(9)
            .fontColor(this.pd())
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (user.hasFamily()) {
        Text('不可邀请')
          .fontSize(9)
          .fontColor(Palette.textLight)
      } else if (this.isInvited(user.id)) {
        Text('已邀请')
          .fontSize(10)
          .fontColor(this.pd())
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.pl())
          .borderRadius(8)
      } else {
        Text('邀请')
          .fontSize(10)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.p())
          .borderRadius(8)
          .onClick(() => {
            this.onInviteUser(user);
          })
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Palette.card)
    .borderRadius(12)
  }

  /** 收到的邀请：同意 / 拒绝 */
  @Builder
  FamilyInviteRow(inv: FamilyInvite) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('✉️')
          .fontSize(18)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFF4E2')
          .borderRadius(9)
        Column({ space: 2 }) {
          Text(inv.hasFamily ? `${inv.nickname} 邀请你加入「${inv.familyName}」` :
            `${inv.nickname} 想和你一起组建「${inv.familyName}」`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
            .maxLines(2)
          Text(inv.hasFamily ? `@${inv.username} 已有家庭 · 同意后并入` :
            `@${inv.username} · 同意后家庭建立，TA 是创建者`)
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('拒绝')
          .layoutWeight(1)
          .height(34)
          .textAlign(TextAlign.Center)
          .fontSize(11)
          .fontColor('#D9534F')
          .backgroundColor('#FDECEA')
          .borderRadius(9)
          .onClick(() => {
            this.onRejectInvite(inv);
          })
        Text('同意加入')
          .layoutWeight(2)
          .height(34)
          .textAlign(TextAlign.Center)
          .fontSize(11)
          .fontColor('#FFFFFF')
          .backgroundColor(this.p())
          .borderRadius(9)
          .onClick(() => {
            this.onAcceptInvite(inv);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: '#E3EFE8' })
  }

  /** 已发出的邀请：等待对方同意，可撤回 */
  @Builder
  FamilyOutgoingRow(inv: FamilyInvite) {
    Row({ space: 8 }) {
      Text('⏳')
        .fontSize(14)
      Column({ space: 1 }) {
        Text(`已邀请 ${inv.nickname}`)
          .fontSize(11)
          .fontColor(Palette.text)
        Text(`@${inv.username} · 等待同意`)
          .fontSize(9)
          .fontColor(Palette.textLight)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('撤回')
        .fontSize(9)
        .fontColor(Palette.textLight)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor('#F1F6F3')
        .borderRadius(7)
        .onClick(() => {
          this.onCancelInvite(inv);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(Palette.card)
    .borderRadius(10)
  }

  /** 收件箱 + 已发出：家庭页和组建页都要显示（被邀请人可能还没有家庭） */
  @Builder
  FamilyInbox() {
    if (this.familyIncoming.length > 0) {
      Column({ space: 8 }) {
        Row() {
          Text(`收到 ${this.familyIncoming.length} 条邀请`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Blank()
          Text('同意后即建立家庭')
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .width('100%')

        ForEach(this.familyIncoming, (inv: FamilyInvite) => {
          this.FamilyInviteRow(inv)
        }, (inv: FamilyInvite) => inv.inviteId)
      }
      .width('100%')
    }

    if (this.familyOutgoing.length > 0) {
      Column({ space: 6 }) {
        Text(`已发出的邀请（${this.familyOutgoing.length}）`)
          .fontSize(11)
          .fontColor(Palette.textLight)
          .width('100%')
        ForEach(this.familyOutgoing, (inv: FamilyInvite) => {
          this.FamilyOutgoingRow(inv)
        }, (inv: FamilyInvite) => inv.inviteId)
      }
      .width('100%')
    }
  }

  @Builder
  FamilyMetricCell(kind: string) {
    Column({ space: 2 }) {
      Row({ space: 2 }) {
        Text(this.familyMetricValue(kind))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pd())
        Text(this.familyMetricUnit(kind))
          .fontSize(9)
          .fontColor(Palette.textLight)
          .margin({ bottom: 2 })
      }
      .alignItems(VerticalAlign.Bottom)
      Text(this.familyMetricLabel(kind))
        .fontSize(9)
        .fontColor(Palette.textLight)
    }
    .layoutWeight(1)
  }

  @Builder
  FamilyHome() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Row() {
          Text('🏡')
            .fontSize(28)
          Blank()
          Text(`${this.familySum.memberCount} / ${this.family.memberLimit} 位成员`)
            .fontSize(10)
            .fontColor('#D6F0E2')
        }
        .width('100%')

        Text(this.family.name)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')
        Text(`创建者 ${this.family.ownerName()} · 邀请码 ${this.family.inviteCode}`)
          .fontSize(9)
          .fontColor('#C9E4D5')
          .width('100%')
        Text('把每个人的低碳足迹，汇成一家人的绿色成绩')
          .fontSize(10)
          .fontColor('#A9D6BE')
          .width('100%')
      }
      .width('100%')
      .padding(20)
      .borderRadius(20)
      .linearGradient({
        angle: 145,
        colors: [['#38A874', 0], ['#1B5E45', 1]]
      })

      Column({ space: 10 }) {
        Row() {
          this.FamilyMetricCell('month')
          this.FamilyMetricCell('today')
        }
        .width('100%')
        Divider().color('#EDF0EE')
        Row() {
          this.FamilyMetricCell('total')
          this.FamilyMetricCell('tree')
        }
        .width('100%')
      }
      .cardStyle()

      this.FamilyInbox()

      Column({ space: 10 }) {
        Row() {
          Text('家庭成员')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Blank()
          Text('本月贡献')
            .fontSize(9)
            .fontColor(Palette.textLight)
        }
        .width('100%')

        ForEach(this.family.members, (m: FamilyMember) => {
          Column({ space: 5 }) {
            Row({ space: 8 }) {
              Text(m.avatar)
                .fontSize(18)
                .width(32)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F1F6F3')
                .borderRadius(16)
              Column({ space: 1 }) {
                Row({ space: 4 }) {
                  Text(m.name)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text)
                  if (m.isMe) {
                    Text('我')
                      .fontSize(8)
                      .fontColor(this.pd())
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .backgroundColor(this.pl())
                      .borderRadius(4)
                  }
                  if (m.isOwner) {
                    Text('创建者')
                      .fontSize(8)
                      .fontColor('#8A6A20')
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .backgroundColor('#FFF4E2')
                      .borderRadius(4)
                  }
                }
                Text(`${m.username.length > 0 ? '@' + m.username + ' · ' : ''}${fmtKg(this.familyMemberMonth(m))} kg`)
                  .fontSize(9)
                  .fontColor(Palette.textLight)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(`${Math.round(this.familyMemberRatio(m) * 100)}%`)
                .fontSize(10)
                .fontColor(this.p())
            }
            .width('100%')
            ProgressBar({
              progress: this.familyMemberRatio(m),
              color: this.p(),
              barHeight: 5
            })
              .width('100%')
          }
          .width('100%')
        }, (m: FamilyMember) => `${m.id}_${m.name}_${m.isMe}_${this.familyMemberMonth(m)}`)

        Text('家庭汇总 = 每位成员本月减排之和，数据来自云端记账统计')
          .fontSize(9)
          .fontColor(Palette.textLight)
          .width('100%')
      }
      .cardStyle()

      Row({ space: 10 }) {
        if (this.isFamilyOwner()) {
          Text('邀请成员')
            .layoutWeight(1)
            .height(42)
            .textAlign(TextAlign.Center)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.p())
            .borderRadius(11)
            .onClick(() => {
              this.familyMode = 'add';
              this.familySearch = '';
              this.familyResults = [];
            })
        }
        Text(this.isFamilyOwner() ? '解散家庭' : '退出家庭')
          .layoutWeight(1)
          .height(42)
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor('#D9534F')
          .backgroundColor('#FDECEA')
          .borderRadius(11)
          .onClick(() => {
            this.leaveFamily();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
  }

  /** 没有家庭时的入口：搜人 → 邀请 → 对方同意后建家庭 */
  @Builder
  FamilyJoinCreate() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text('👨‍👩‍👧‍👦')
          .fontSize(34)
        Text('搜到家人，邀请他一起记录')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Text('输入对方的用户名或昵称，发出邀请。对方在「我的家庭」里点同意后，家庭才会建立。')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .textAlign(TextAlign.Center)
          .lineHeight(16)
        Text(auth.username.length > 0 ? `我的账号：${auth.username}` : '')
          .fontSize(10)
          .fontColor(this.pd())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.pl())
          .borderRadius(6)
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#E8F4EE')
      .borderRadius(18)

      this.FamilyInbox()

      Column({ space: 8 }) {
        Text('给新家庭起个名字')
          .fontSize(11)
          .fontColor(Palette.textLight)
          .width('100%')
        TextInput({ placeholder: '如：我们家的低碳家庭', text: this.familyNameInput })
          .height(40)
          .fontSize(12)
          .backgroundColor(Palette.card)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.familyNameInput = value;
          })
      }
      .width('100%')

      TextInput({ placeholder: '输入用户名或昵称，如 lyr02', text: this.familySearch })
        .height(44)
        .fontSize(12)
        .backgroundColor(Palette.card)
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => {
          this.onFamilySearch(value);
        })

      Row() {
        Text(this.familySearching ? '搜索中…' :
          (this.familySearch.trim().length === 0 ? '搜索家人' : `搜索结果（${this.familyResults.length}）`))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
        Blank()
        if (this.familyOutgoing.length > 0) {
          Text(`已邀请 ${this.familyOutgoing.length} 人`)
            .fontSize(9)
            .fontColor(this.p())
        }
      }
      .width('100%')

      if (this.familySearch.trim().length > 0 && !this.familySearching && this.familyResults.length === 0) {
        Text('没有找到匹配的账号，确认对方已注册（用户名要完全对得上）')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .width('100%')
          .padding(14)
          .backgroundColor(Palette.card)
          .borderRadius(12)
      } else {
        ForEach(this.familyResults, (u: DirectoryUser) => {
          this.FamilyUserRow(u)
        }, (u: DirectoryUser) => `${u.id}_${this.isInvited(u.id)}`)
      }
    }
    .width('100%')
    .padding(16)
  }

  /** 家庭内邀请新成员 */
  @Builder
  FamilyAdd() {
    Column({ space: 12 }) {
      Text('邀请新成员')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
        .width('100%')
      Text(`搜索用户名或昵称，把家人加进「${this.family.name}」。对方同意后即加入。`)
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(16)

      TextInput({ placeholder: '输入用户名或昵称', text: this.familySearch })
        .height(44)
        .fontSize(12)
        .backgroundColor(Palette.card)
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => {
          this.onFamilySearch(value);
        })

      if (this.familySearching) {
        Text('搜索中…')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .width('100%')
      }

      ForEach(this.familyResults, (u: DirectoryUser) => {
        this.FamilyUserRow(u)
      }, (u: DirectoryUser) => `${u.id}_${this.isInvited(u.id)}_add`)

      if (this.familyOutgoing.length > 0) {
        Column({ space: 6 }) {
          Text(`已发出的邀请（${this.familyOutgoing.length}）`)
            .fontSize(11)
            .fontColor(Palette.textLight)
            .width('100%')
          ForEach(this.familyOutgoing, (inv: FamilyInvite) => {
            this.FamilyOutgoingRow(inv)
          }, (inv: FamilyInvite) => `out_${inv.inviteId}`)
        }
        .width('100%')
      }

      Text('返回家庭')
        .width('100%')
        .height(42)
        .textAlign(TextAlign.Center)
        .fontSize(13)
        .fontColor(this.pd())
        .backgroundColor(this.pl())
        .borderRadius(11)
        .onClick(() => {
          this.familyMode = 'home';
        })
    }
    .width('100%')
    .padding(16)
  }

  @Builder
  FamilyCover() {
    Column() {
      this.FamilyHeader()
      // 云端失败时常驻一行，比一闪而过的 toast 更容易被看到
      if (this.familyError.length > 0) {
        Row({ space: 6 }) {
          Text('⚠️')
            .fontSize(12)
          Text(this.familyError)
            .fontSize(10)
            .fontColor('#9A3B33')
            .layoutWeight(1)
          Text('重试')
            .fontSize(10)
            .fontColor('#9A3B33')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('#F6DEDB')
            .borderRadius(6)
            .onClick(() => {
              this.syncFamily(false);
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#FDECEA')
      }
      Scroll() {
        if (this.familyMode === 'add' && this.familyJoined) {
          this.FamilyAdd()
        } else if (this.familyJoined) {
          this.FamilyHome()
        } else {
          this.FamilyJoinCreate()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7F6')
  }

  @Builder
  GuestTemplate() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 10 }) {
          Text('🌱')
            .fontSize(42)
          Text('欢迎使用碳足迹')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text('登录后同步你的碳账本、成就徽章与证书')
            .fontSize(11)
            .fontColor(Palette.textSub)
            .textAlign(TextAlign.Center)
            .lineHeight(17)
          Text('登录 / 注册')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
            .backgroundColor(this.p())
            .borderRadius(11)
            .margin({ top: 4 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/Login' }).catch(() => {
                DialogUtil.toast(this.getUIContext(), '打开登录页失败，请稍后重试');
              });
            })
          Text('登录后才能记账、领取任务奖励与兑换徽章')
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .width('100%')
        .padding(20)
        .backgroundColor(Palette.card)
        .borderRadius(18)
        .shadow({ radius: 12, color: '#0A1F3D14', offsetY: 3 })

        // 家庭是账号能力，但入口始终可见：未登录时点击引导去登录/注册
        this.GuestFamilyCard()

        this.GuestPlaceholder('成就徽章', '账号解锁的徽章将展示在这里')
        this.GuestPlaceholder('证书中心', '达成减排目标后获得电子证书')
        this.GuestPlaceholder('碳账本摘要', '累计减排、记录条数与连续打卡')

        Text('登录后，本页会显示该账号的积分、勋章、证书与数据管理')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .textAlign(TextAlign.Center)
          .width('100%')
          .lineHeight(16)
          .padding({ top: 4 })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  /** 未登录时的家庭入口：家庭属于账号数据，点击引导登录 / 注册 */
  @Builder
  GuestFamilyCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('🏡')
          .fontSize(22)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFF4E2')
          .borderRadius(10)
        Column({ space: 2 }) {
          Text('我的家庭')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text('组建或加入家庭，和家人一起看减排')
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('组建 / 加入')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.p())
          .borderRadius(9)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('🔒')
          .fontSize(10)
        Text('家庭数据需要账号：登录后可搜索家人 ID / 昵称')
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .width('100%')
    }
    .cardStyle()
    .onClick(() => {
      router.pushUrl({ url: 'pages/Login' }).catch(() => {
        DialogUtil.toast(this.getUIContext(), '打开登录页失败，请稍后重试');
      });
    })
  }

  /** 未登录时的骨架占位卡 */
  @Builder
  GuestPlaceholder(title: string, desc: string) {
    Column({ space: 10 }) {
      Row() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.textSub)
        Blank()
        Text('🔒')
          .fontSize(12)
          .opacity(0.5)
      }
      .width('100%')

      Row({ space: 10 }) {
        this.GuestSkeleton()
        this.GuestSkeleton()
        this.GuestSkeleton()
      }
      .width('100%')

      Text(desc)
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .opacity(0.85)
  }

  @Builder
  GuestSkeleton() {
    Column({ space: 6 }) {
      Text('')
        .width(44)
        .height(44)
        .backgroundColor('#EDF1EF')
        .borderRadius(22)
      Text('')
        .width(48)
        .height(8)
        .backgroundColor('#EDF1EF')
        .borderRadius(4)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  MetricCell(label: string, kind: string, unit: string, color: string) {
    Column({ space: 3 }) {
      Row({ space: 2 }) {
        Text(this.metricValue(kind))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(color)
        Text(unit)
          .fontSize(9)
          .fontColor(Palette.textLight)
          .margin({ bottom: 3 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(10)
        .fontColor(Palette.textSub)
    }
    .layoutWeight(1)
  }

  metricValue(kind: string): string {
    if (kind === 'month') {
      return fmtKg(this.summary.monthReduction);
    }
    if (kind === 'week') {
      return fmtKg(this.summary.weekReduction);
    }
    return `${this.summary.treeCount}`;
  }

  openCertificate(badgeId: string): void {
    if (carbonStore.certificateOf(badgeId) === null) {
      DialogUtil.toast(this.getUIContext(), '还没有获得这张证书');
      return;
    }
    this.openCertId = badgeId;
  }

  currentCertificate(): CertificateInfo | null {
    if (this.openCertId.length === 0) {
      return null;
    }
    return carbonStore.certificateOf(this.openCertId);
  }

  certDate(info: CertificateInfo): string {
    return info.issuedAt > 0 ? formatDate(info.issuedAt) : '早期获得';
  }

  /** 证书上的植树量：植树类证书按档位展示，其它证书按累计减排折算 */
  certTreeText(info: CertificateInfo): string {
    if (info.badge.id === 'c_tree1') {
      return '1 棵';
    }
    if (info.badge.id === 'c_tree5') {
      return '5 棵';
    }
    if (info.badge.id === 'c_tree10') {
      return '10 棵';
    }
    return `${round(this.summary.treeCount, 1)} 棵·年`;
  }

  async confirmLogout(): Promise<void> {
    const ok = await DialogUtil.confirm(this.getUIContext(), '退出登录？',
      '退出后本机将回到未登录模板，账号数据仍保存在云端。', '退出', Palette.danger);
    if (!ok) {
      return;
    }
    await cloudAccount.logout();
    // 城市账号 token 属于上一个账号，退出时必须一并清除，避免下个账号复用
    await cityService.clearBinding();
    this.refresh();
    this.bump();
    DialogUtil.toast(this.getUIContext(), '已退出登录');
  }


  /** 账号与云端：未登录时引导登录，登录后展示账号信息与退出入口 */
  @Builder
  AccountSheet() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Text(this.loggedIn ? '☁️' : '🔑')
          .fontSize(30)
        Text(this.loggedIn ? (this.username.length > 0 ? this.username : '已登录') : '还没有登录')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
        Text(this.loggedIn ?
          '碳账本会随记录自动同步到云端，换设备登录同一账号即可恢复' :
          '登录后可以云端同步碳账本、组建家庭、获得电子证书')
          .fontSize(11)
          .fontColor(Palette.textSub)
          .textAlign(TextAlign.Center)
          .lineHeight(16)
          .padding({ left: 12, right: 12 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      Column({ space: 10 }) {
        if (this.loggedIn) {
          Button('退出登录')
            .width('100%')
            .height(42)
            .fontSize(14)
            .fontColor(Palette.danger)
            .backgroundColor('#FDF0EE')
            .borderRadius(12)
            .onClick(async () => {
              this.showSheet = false;
              await this.confirmLogout();
            })
        } else {
          Button('登录 / 注册')
            .width('100%')
            .height(42)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(this.p())
            .borderRadius(12)
            .onClick(() => {
              this.showSheet = false;
              router.pushUrl({ url: 'pages/Login' });
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  /** 状态栏实况窗：授权 / 刷新 / 发一条测试通知 */
  @Builder
  NotifySheet() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text(this.notifyEnabled ? '🔔' : '🔕')
          .fontSize(24)
        Column({ space: 3 }) {
          Text(this.notifyEnabled ? '实况窗已开启' : '实况窗未开启')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text('在状态栏常驻显示今日待打卡与本月减排进度，每 10 分钟自动刷新。'
            + '系统通知被关闭时，实况窗和状态栏灵动岛都不会显示。')
            .fontSize(11)
            .fontColor(Palette.textSub)
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Button(this.notifyEnabled ? '立即刷新实况窗' : '开启实况窗')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.p())
        .borderRadius(12)
        .onClick(async () => {
          await this.sendNotification();
        })

      // 权限被永久拒绝时系统不再弹框，必须给一个直达设置页的入口
      if (!this.notifyEnabled) {
        Text('通知被系统关闭了？点这里去设置里打开')
          .fontSize(11.5)
          .fontColor(this.pd())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
          .onClick(async () => {
            await this.openNotifySettings();
          })
      }

      Row({ space: 10 }) {
        Button('刷新实况窗')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.pd())
          .backgroundColor(this.pl())
          .borderRadius(12)
          .onClick(async () => {
            // 不能无条件提示成功：通知没开时 updateLiveView 直接返回 false，
            // 过去这里照样弹"实况窗已刷新"，用户会以为已经生效（真实踩到）。
            const ok = await notificationService.updateLiveView();
            this.notifyEnabled = await notificationService.isEnabled();
            if (ok) {
              DialogUtil.toast(this.getUIContext(), '实况窗已刷新');
            } else if (!this.notifyEnabled) {
              DialogUtil.toast(this.getUIContext(), '通知未开启，先点上面的“开启实况窗”');
            } else {
              DialogUtil.toast(this.getUIContext(), '实况窗刷新失败，请稍后重试');
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  /** 我的证书：已获得的证书列表，点开看全屏证书 */
  @Builder
  CertSheet() {
    Column({ space: 10 }) {
      if (this.certificates.length === 0) {
        EmptyBox('🧾', '还没有证书', '达成减排目标或兑换证书类徽章后，这里会生成电子证书')
      } else {
        ForEach(this.certificates, (info: CertificateInfo) => {
          this.CertCard(info)
        }, (info: CertificateInfo) => info.badge.id + '_' + info.serial)
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  /** 月度复盘卡：本月 vs 上月、活跃天数、最佳分类、最佳记录 */
  @Builder
  ReviewCard() {
    Column({ space: 12 }) {
      Row({ space: 6 }) {
        Text('🗓️')
          .fontSize(14)
        Text('本月小结')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text(this.changeText())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.changeUp() ? this.pd() : Palette.warn)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.changeUp() ? this.pl() : '#FBEDD8')
          .borderRadius(7)
      }
      .width('100%')

      Row() {
        this.ReviewItem('本月减排', 'reduction')
        this.ReviewItem('有记录的天数', 'days')
        this.ReviewItem('本月记录', 'records')
      }
      .width('100%')

      Divider().color(Palette.line)

      // 最佳分类
      Row({ space: 10 }) {
        Text(this.review.bestCategoryName.length === 0 ? '—' : this.review.bestCategoryIcon)
          .fontSize(18)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F4F7F5')
          .borderRadius(10)
        Column({ space: 2 }) {
          Text('减排最多的类别')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Text(this.review.bestCategoryName.length === 0 ? '本月还没有记录' :
            `${this.review.bestCategoryName} · ${this.review.bestCategoryDesc}`)
            .fontSize(12)
            .fontColor(Palette.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 单条最高减排
      if (this.review.hasBestRecord) {
        Row({ space: 10 }) {
          Text('⭐')
            .fontSize(16)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .backgroundColor('#F1F5F2')
            .borderRadius(10)
          Column({ space: 2 }) {
            Text('一次减排最多')
              .fontSize(10)
              .fontColor(Palette.textLight)
            Text(`${this.review.bestRecordName} · ${this.review.bestRecordValue} kg`)
              .fontSize(12)
              .fontColor(Palette.text)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
      }

      // 本周与种树合并成一条，替代原来单独的一张数据概览卡
      Row({ space: 8 }) {
        Row({ space: 5 }) {
          Text('本周')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Text(`${fmtKg(this.summary.weekReduction)} kg`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.blue)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Divider().vertical(true).height(18).color(Palette.line)

        Row({ space: 5 }) {
          Text('相当于种树')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Text(`${this.summary.treeCount} 棵·年`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .backgroundColor('#F6F9F7')
      .borderRadius(12)

      Text(this.reviewTip())
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(16)
    }
    .width('100%')
    .cardStyle()
  }

  reviewValue(kind: string): string {
    if (kind === 'reduction') {
      return `${fmtKg(this.review.reduction)} kg`;
    }
    if (kind === 'days') {
      return `${this.review.activeDays} 天`;
    }
    return `${this.review.recordCount} 条`;
  }

  @Builder
  ReviewItem(label: string, kind: string) {
    Column({ space: 3 }) {
      Text(this.reviewValue(kind))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
      Text(label)
        .fontSize(10)
        .fontColor(Palette.textLight)
    }
    .layoutWeight(1)
  }

  /** 环比方向：无上月数据时按正向展示（不报警） */
  changeUp(): boolean {
    return !this.review.hasPrev || this.review.changeRate >= 0;
  }

  changeText(): string {
    if (!this.review.hasPrev) {
      return '上月无记录';
    }
    const r = this.review.changeRate;
    if (r > 0) {
      return `环比 +${round(r * 100, 1)}%`;
    }
    if (r < 0) {
      return `环比 ${round(r * 100, 1)}%`;
    }
    return '与上月持平';
  }

  reviewTip(): string {
    if (this.summary.totalCount === 0) {
      return '还没有任何记录。点下方"记一笔"，从今天开始记碳账。';
    }
    if (this.review.activeDays < 5) {
      return `本月只有 ${this.review.activeDays} 天有记录，坚持比一次记很多更重要。`;
    }
    return `本月有 ${this.review.activeDays} 天在记碳账，累计 ${this.review.recordCount} 条。继续把这个习惯保持下去。`;
  }

  /** 个人荣誉：徽章 / 证书 / 奖状 三类，点已获得的可以放大查看 */
  @Builder
  HonorsSheet() {
    Column({ space: 12 }) {
      Text(`已获得 ${this.honorEarnedAll()}/${this.honorTotalAll()} 项 · 徽章靠记录达成，证书和奖状可在「积分兑换」用积分换取`)
        .fontSize(10)
        .fontColor(Palette.textSub)
        .width('100%')
        .lineHeight(16)

      Row({ space: 6 }) {
        this.HonorTabBtn('badge')
        this.HonorTabBtn('cert')
        this.HonorTabBtn('award')
      }
      .width('100%')
      .padding(4)
      .backgroundColor('#F2F4F3')
      .borderRadius(12)

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.honorList(this.honorTab), (st: BadgeState) => {
            this.BadgeDetailRow(st)
          }, (st: BadgeState) => `${this.honorTab}_${st.badge.id}_${st.unlocked}_${st.progressText}`)
        }
        .width('100%')
        .padding({ right: 6 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** 分类按钮：名称和计数都在这里读状态，避免 @Builder 值参数被缓存 */
  @Builder
  HonorTabBtn(kind: string) {
    Row() {
      Text(`${this.honorKindName(kind)} ${this.honorEarned(kind)}/${this.honorList(kind).length}`)
        .fontSize(11)
        .fontColor(this.honorTab === kind ? '#FFFFFF' : Palette.textSub)
        .fontWeight(this.honorTab === kind ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.honorTab === kind ? this.p() : Color.Transparent)
    .borderRadius(9)
    .onClick(() => {
      if (this.honorTab === kind) {
        return;
      }
      this.honorTab = kind;
    })
  }

  honorKindName(kind: string): string {
    if (kind === 'cert') {
      return '证书';
    }
    if (kind === 'award') {
      return '奖状';
    }
    return '徽章';
  }

  /** 按分类取荣誉：徽章 = 成就徽章 + 兑换徽章；证书、奖状各取各的类型 */
  honorList(kind: string): BadgeState[] {
    if (kind === 'cert') {
      return this.redeemables.filter((st: BadgeState) => st.badge.type === 'cert');
    }
    if (kind === 'award') {
      return this.redeemables.filter((st: BadgeState) => st.badge.type === 'award');
    }
    const list: BadgeState[] = this.badges.slice();
    for (const st of this.redeemables) {
      if (st.badge.type === 'redeem') {
        list.push(st);
      }
    }
    return list;
  }

  honorEarned(kind: string): number {
    return this.honorList(kind).filter((st: BadgeState) => st.unlocked).length;
  }

  honorEarnedAll(): number {
    return this.honorEarned('badge') + this.honorEarned('cert') + this.honorEarned('award');
  }

  honorTotalAll(): number {
    return this.honorList('badge').length + this.honorList('cert').length + this.honorList('award').length;
  }

  /** 点已获得的荣誉：先收起面板，等关闭动画结束再请求全局放大弹层 */
  openHonor(st: BadgeState): void {
    if (!st.unlocked) {
      return;
    }
    if (this.honorTimer !== -1) {
      clearTimeout(this.honorTimer);
    }
    this.showSheet = false;
    const id = st.badge.id;
    this.honorTimer = setTimeout(() => {
      this.honorTimer = -1;
      requestHonorView(id);
    }, 420);
  }

  /** 积分兑换面板 */
  @Builder
  RedeemSheet() {
    Column({ space: 12 }) {
      Text(`可用 ${this.summary.totalPoint} 分 · 徽章、证书与奖状都只是本机记录，不涉及真实交易`)
        .fontSize(10)
        .fontColor(Palette.textSub)
        .width('100%')
        .lineHeight(16)

      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.redeemables, (st: BadgeState) => {
            this.RedeemRow(st)
          }, (st: BadgeState) => `${st.badge.id}_${st.unlocked}_${this.summary.totalPoint}`)
        }
        .width('100%')
        .padding({ right: 6 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** 个人设置面板：上半部分是个人信息，下半部分是皮肤 */
  @Builder
  SettingsSheet() {
    Column({ space: 12 }) {
      Text('个人信息')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.textSub)
        .width('100%')

      Row({ space: 8 }) {
        Text('昵称')
          .fontSize(13)
          .fontColor(Palette.text)
          .width(78)
        TextInput({ text: this.nick, placeholder: '输入昵称' })
          .fontSize(13)
          .height(36)
          .maxLength(16)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.nick = v;
          })
        Text('保存')
          .fontSize(11)
          .fontColor(this.skinDef().primaryDark)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.skinDef().primaryLight)
          .borderRadius(9)
          .onClick(() => {
            this.onSaveNick();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('月减排目标')
          .fontSize(13)
          .fontColor(Palette.text)
          .width(78)
        TextInput({ text: this.goalInput, placeholder: 'kg' })
          .type(InputType.Number)
          .fontSize(13)
          .height(36)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.goalInput = v;
          })
        Text('kg')
          .fontSize(11)
          .fontColor(Palette.textLight)
        Text('保存')
          .fontSize(11)
          .fontColor(this.skinDef().primaryDark)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.skinDef().primaryLight)
          .borderRadius(9)
          .onClick(() => {
            this.onSaveGoal();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('昵称显示在“我的”页顶部；月目标用于碳账本首页的进度展示。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(16)

      Divider().color(Palette.line).margin({ top: 2 })

      Row() {
        Text('皮肤')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.textSub)
        Blank()
        Text(`当前：${Palette.skinById(this.skinId).name}`)
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .width('100%')

      Row({ space: 6 }) {
        ForEach(SKINS, (s: SkinDef) => {
          this.SkinSwatch(s)
        }, (s: SkinDef) => `skin_${s.id}_${this.skinId === s.id}`)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Text('皮肤只换主色，底色和文字保持浅色；选择后立即生效，下次打开应用仍然保留。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(16)

      Divider().color(Palette.line).margin({ top: 2 })

      Row({ space: 10 }) {
        Text('🤖')
          .fontSize(18)
        Column({ space: 3 }) {
          Text('AI 图片识别')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text(this.aiSummary())
            .fontSize(10)
            .fontColor(Palette.textLight)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('设置 ›')
          .fontSize(11)
          .fontColor(this.skinDef().primaryDark)
      }
      .width('100%')
      .padding(11)
      .backgroundColor('#F7F9F8')
      .borderRadius(10)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.sheetKind = 'ai';
      })

      Blank()

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** AI 图片识别配置面板 */
  @Builder
  AISheet() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('用视觉模型判定')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text('开启后，「记一笔」里选一张照片就交给模型判定；确认有低碳行为时自动记账加分，不用再点确认。图片只发给你填的模型接口，App 不保存图片。关闭时图片识别不可用。')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .lineHeight(15)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.aiEnabled })
          .selectedColor(this.skinDef().primary)
          .onChange((on: boolean) => {
            this.aiEnabled = on;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Divider().color(Palette.line)

      Row({ space: 8 }) {
        Text('接口地址')
          .fontSize(12)
          .fontColor(Palette.text)
          .width(64)
        TextInput({ text: this.aiBaseUrl, placeholder: 'https://api.deepseek.com' })
          .fontSize(12)
          .height(36)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.aiBaseUrl = v;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('模型名称')
          .fontSize(12)
          .fontColor(Palette.text)
          .width(64)
        TextInput({ text: this.aiModel, placeholder: 'deepseek-flash' })
          .fontSize(12)
          .height(36)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.aiModel = v;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('API Key')
          .fontSize(12)
          .fontColor(Palette.text)
          .width(64)
        TextInput({ text: this.aiApiKey, placeholder: '本地模型可留空' })
          .fontSize(12)
          .height(36)
          .type(InputType.Password)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.aiApiKey = v;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('填 OpenAI 兼容地址，末尾不要带 /chat/completions。手机/模拟器里的 127.0.0.1 指它自己：模拟器用 http://10.0.2.2:11434/v1，真机用电脑的局域网 IP（http://192.168.x.x:11434/v1）。模型名与 ollama list 一致，Key 只存在本机。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(15)

      Text('模型只判两件事：画面里有没有低碳行为、具体是哪一条。类别、减排量、积分都按内置清单计算，不让模型自己算。自动记账：同一张照片 24 小时只记一次；每个行为每天最多自动记 3 次。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(15)

      Row({ space: 8 }) {
        Text(this.aiTesting ? '测试中…' : '测试连接')
          .fontSize(12)
          .fontColor(this.skinDef().primaryDark)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.skinDef().primaryLight)
          .borderRadius(9)
          .onClick(() => {
            this.onTestAI();
          })

        if (this.aiTest.length > 0 && !this.aiTesting) {
          Text(this.aiTest)
            .fontSize(10)
            .fontColor(this.aiTestOk ? '#2E7D53' : '#B3452F')
            .layoutWeight(1)
            .maxLines(3)
            .lineHeight(14)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Blank()

      Row({ space: 10 }) {
        Text('保存')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.skinDef().primaryDark)
          .layoutWeight(1)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.skinDef().primaryLight)
          .borderRadius(10)
          .onClick(() => {
            this.onSaveAI();
          })
        Text('取消')
          .fontSize(12)
          .fontColor(Palette.textSub)
          .layoutWeight(1)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F0F2F1')
          .borderRadius(10)
          .onClick(() => {
            this.sheetKind = 'settings';
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** 皮肤切换后主色是运行时变量，面板不在页面 build 里，必须靠 skinId 这个被观察的值取色 */
  skinDef(): SkinDef {
    return Palette.skinById(this.skinId);
  }

  /** 资料卡渐变：调用时读 skinId，切换皮肤后该节点才会重绘 */
  profileColors(): [ResourceColor, number][] {
    const s = this.skinDef();
    return [[s.primary, 0], [s.primaryDark, 1]];
  }

  profileShadow(): string {
    return Palette.rgba(this.skinDef().primaryDark, 0.2);
  }

  p(): string {
    return this.skinDef().primary;
  }

  pd(): string {
    return this.skinDef().primaryDark;
  }

  pl(): string {
    return this.skinDef().primaryLight;
  }

  /** 单个皮肤色块：选中时加深色外圈并打勾 */
  @Builder
  SkinSwatch(s: SkinDef) {
    Column({ space: 5 }) {
      Stack() {
        Circle()
          .width(30)
          .height(30)
          .fill(s.primary)
        if (this.skinId === s.id) {
          Text('✓')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(Palette.card)
      .border({ width: 2, color: this.skinId === s.id ? s.primary : Palette.line })

      Text(s.name)
        .fontSize(10)
        .fontColor(this.skinId === s.id ? Palette.text : Palette.textLight)
        .fontWeight(this.skinId === s.id ? FontWeight.Medium : FontWeight.Normal)
    }
    .padding({ left: 2, right: 2 })
    .onClick(() => {
      if (this.skinId === s.id) {
        return;
      }
      SkinService.select(s.id);
    })
  }

  /** 数据管理面板：备份、导出、清空都收进这里，避免页面堆叠过多卡片 */
  @Builder
  DataSheet() {
    Column({ space: 12 }) {
      Text('数据只存在这台手机上，不联网也能用；卸载应用会一起删掉，建议定期备份。')
        .fontSize(11)
        .fontColor(Palette.textSub)
        .width('100%')
        .lineHeight(18)

      Row({ space: 8 }) {
        Text(this.backupInfo())
          .fontSize(10)
          .fontColor(this.backupExists ? this.p() : Palette.textLight)
          .layoutWeight(1)
        if (this.backupExists) {
          Text('恢复')
            .fontSize(11)
            .fontColor(Palette.blue)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('#EEF4FC')
            .borderRadius(8)
            .onClick(() => {
              this.confirmRestore();
            })
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#F6F9F7')
      .borderRadius(10)

      Row({ space: 10 }) {
        Text('备份数据')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(this.p())
          .borderRadius(11)
          .onClick(() => {
            this.doBackup();
          })

        Text('导出报表')
          .fontSize(12)
          .fontColor(this.p())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(this.pl())
          .borderRadius(11)
          .onClick(() => {
            this.doCsv();
          })

        Text('导出文本')
          .fontSize(12)
          .fontColor(Palette.blue)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor('#EEF4FC')
          .borderRadius(11)
          .onClick(() => {
            this.doText();
          })
      }
      .width('100%')

      Text('清空所有数据')
        .fontSize(12)
        .fontColor(Palette.danger)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 10, bottom: 10 })
        .backgroundColor('#FDF0EE')
        .borderRadius(11)
        .onClick(() => {
          this.confirmClear();
        })

      Text('备份和报表默认存在应用内部；导出时会弹出系统保存窗口，位置由你选。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
        .lineHeight(16)

      Blank()

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** 关于面板 */
  @Builder
  AboutSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('🌿')
          .fontSize(22)
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .linearGradient({ angle: 135, colors: [[this.p(), 0], [this.pd(), 1]] })
          .borderRadius(24)
        Column({ space: 2 }) {
          Text('碳足迹')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text('全民绿色生活碳积分与减排指南')
            .fontSize(10)
            .fontColor(Palette.textSub)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider().color(Palette.line)

      this.AboutLine('运行环境', 'OpenHarmony / ArkTS · 单机离线运行 · API 12+')
      this.AboutLine('数据存储', '全部保存在本机，不申请网络权限，卸载即删除')
      this.AboutLine('减排因子', '参考生态环境部公开指南、IPCC 报告与行业研究估算')
      this.AboutLine('城市碳普惠', '模拟城市平台接口，积分与权益只在本机记账')

      Blank()

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  @Builder
  AboutLine(label: string, value: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(10)
        .fontColor(Palette.textLight)
        .width('100%')
      Text(value)
        .fontSize(12)
        .fontColor(Palette.text)
        .width('100%')
        .lineHeight(18)
    }
    .width('100%')
  }

  @Builder
  CsvSheet() {
    Column({ space: 10 }) {
      Scroll() {
        Text(this.csvText)
          .fontSize(10)
          .fontColor(Palette.textSub)
          .lineHeight(16)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      .padding(12)
      .backgroundColor('#F7F9F8')
      .borderRadius(10)

      Row({ space: 10 }) {
        Text('保存到文件')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor(this.p())
          .borderRadius(10)
          .onClick(() => {
            this.saveCsvToFile();
          })

        Text('关闭')
          .fontSize(12)
          .fontColor(Palette.textSub)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 9, bottom: 9 })
          .backgroundColor('#F0F2F1')
          .borderRadius(10)
          .onClick(() => {
            this.showSheet = false;
          })
      }
      .width('100%')

      Text('以上内容可长按复制，粘贴到备忘录或表格中留存')
        .fontSize(10)
        .fontColor(Palette.textLight)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  @Builder
  BankMetric(value: string, label: string, color: string, unit: string) {
    Column({ space: 3 }) {
      Row({ space: 2 }) {
        Text(value)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(color)
        Text(unit)
          .fontSize(9)
          .fontColor(Palette.textLight)
          .margin({ bottom: 3 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(10)
        .fontColor(Palette.textSub)
    }
    .layoutWeight(1)
  }

  /** 权益兑换按钮文案 */
  offerActionText(item: OfferView): string {
    if (item.remain <= 0) {
      return '已兑完';
    }
    return `${item.offer.cost} 分`;
  }

  /** 碳普惠面板：账户信息 + 积分转入 + 权益兑换 + 流水 */
  @Builder
  BankSheet() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('🏙️')
          .fontSize(20)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor('#EFF6F1')
          .borderRadius(12)
        Column({ space: 3 }) {
          Text(this.bank.bound ? `${this.bank.city}碳普惠账户` : '碳普惠账户未开通')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
          Text(this.bank.bound ? `账号 ${this.bank.accountNo}` : '开通后可与城市平台互通积分')
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.bank.bound) {
          Text(`${this.bank.bankPoint}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p())
        } else {
          Text(this.bankBusy ? '开通中' : '立即开通')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.p())
            .borderRadius(9)
            .opacity(this.bankBusy ? 0.6 : 1)
            .onClick(() => {
              this.doBind();
            })
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F5F9F6')
      .borderRadius(12)

      if (this.bank.bound) {
        Row({ space: 8 }) {
          TextInput({ text: this.transferInput, placeholder: '输入要转入的积分数' })
            .type(InputType.Number)
            .fontSize(12)
            .height(36)
            .backgroundColor('#F5F7F6')
            .borderRadius(10)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.transferInput = v;
            })
          Text('全部')
            .fontSize(11)
            .fontColor(Palette.blue)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor('#EEF4FC')
            .borderRadius(9)
            .onClick(() => {
              this.fillAll();
            })
          Text(this.bankBusy ? '处理中' : '转入')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.p())
            .borderRadius(9)
            .opacity(this.bankBusy ? 0.6 : 1)
            .onClick(() => {
              this.doTransfer();
            })
        }
        .width('100%')

        Text(`可用碳积分 ${this.summary.totalPoint} 分 · 1 碳积分 = 1 碳普惠积分 · 单次 10~5000 分`)
          .fontSize(10)
          .fontColor(Palette.textLight)
          .width('100%')
      } else {
        Text('开通后可用碳积分 1:1 转入城市碳普惠账户，再兑换地铁券、共享单车等权益。')
          .fontSize(10)
          .fontColor(Palette.textLight)
          .width('100%')
          .lineHeight(16)
      }

      Scroll() {
        Column({ space: 10 }) {
          Text('权益兑换')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
            .width('100%')

          ForEach(this.offers, (item: OfferView) => {
            Row({ space: 10 }) {
              Text(item.offer.icon)
                .fontSize(18)
                .width(40)
                .height(40)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F4F7F5')
                .borderRadius(10)
              Column({ space: 3 }) {
                Text(item.offer.name)
                  .fontSize(12)
                  .fontColor(Palette.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${item.offer.sponsor} · 剩余 ${item.remain}`)
                  .fontSize(10)
                  .fontColor(Palette.textLight)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(this.offerActionText(item))
                .fontSize(11)
                .fontColor(item.remain <= 0 ? Palette.textLight :
                  (this.bank.bankPoint >= item.offer.cost ? this.p() : Palette.textSub))
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(item.remain <= 0 ? '#F2F4F3' :
                  (this.bank.bankPoint >= item.offer.cost ? this.pl() : '#F2F4F3'))
                .borderRadius(9)
                .opacity(this.bankBusy ? 0.6 : 1)
                .onClick(() => {
                  this.doRedeem(item);
                })
            }
            .width('100%')
          }, (item: OfferView) => `${item.offer.id}_${item.remain}_${this.bank.bankPoint}`)

          if (this.bankOrders.length > 0) {
            Text('最近兑换记录')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
              .width('100%')
              .margin({ top: 4 })

            ForEach(this.bankOrders, (o: BankOrder) => {
              Row({ space: 8 }) {
                Text(o.icon)
                  .fontSize(13)
                  .width(24)
                  .textAlign(TextAlign.Center)
                Text(o.title)
                  .fontSize(11)
                  .fontColor(Palette.text)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(o.type === 'in' ? `+${o.amount}` : `-${o.amount}`)
                  .fontSize(11)
                  .fontColor(o.type === 'in' ? this.p() : Palette.warn)
                Text(formatDateTime(o.time))
                  .fontSize(9)
                  .fontColor(Palette.textLight)
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }, (o: BankOrder) => o.id)
          }

          Text('碳积分按 1:1 换成碳普惠积分，一次转 10~5000 分；权益数量和兑换记录都保存在本机，不联网。')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .width('100%')
            .lineHeight(16)
            .margin({ top: 4 })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Text('关闭')
        .fontSize(12)
        .fontColor(Palette.textSub)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor('#F0F2F1')
        .borderRadius(10)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /** 备份状态描述 */
  backupInfo(): string {
    if (!this.backupExists) {
      return '暂无本地备份';
    }
    return `已有备份 · ${this.backupSizeText()} · ${this.backupTime}`;
  }

  backupSizeText(): string {
    const n = this.backupBytes;
    if (n < 1024) {
      return `${n} B`;
    }
    return `${(n / 1024).toFixed(1)} KB`;
  }

  /** 执行备份：写入沙箱文件 */
  doBackup(): void {
    const payload = carbonStore.buildBackupPayload();
    const path = fileService.backup(payload);
    if (path.length === 0) {
      DialogUtil.toast(this.getUIContext(), '备份失败，请检查存储空间');
      return;
    }
    this.refreshBackupState();
    DialogUtil.toast(this.getUIContext(), `已备份 ${carbonStore.records.length} 条记录到本机`);
  }

  /** 刷新备份相关状态 */
  refreshBackupState(): void {
    this.backupExists = fileService.hasBackup();
    this.backupBytes = fileService.backupSize();
    if (this.backupExists) {
      const raw = fileService.readBackup();
      try {
        const pack = JSON.parse(raw) as BackupPreview;
        this.backupTime = pack.exportedAt === undefined ? '' : `${pack.exportedAt}`;
      } catch (e) {
        this.backupTime = '';
      }
    } else {
      this.backupTime = '';
    }
  }

  /** 生成报表并弹出预览（可长按复制，也可另存到用户目录） */
  doCsv(): void {
    const csv = carbonStore.buildCsvReport();
    this.csvText = csv;
    if (carbonStore.records.length === 0) {
      DialogUtil.toast(this.getUIContext(), '还没有记录，报表是空的');
    }
    this.reopenSheet('csv');
  }

  /** 把预览中的 CSV 通过系统保存框写到用户选择的目录 */
  async saveCsvToFile(): Promise<void> {
    if (this.csvText.length === 0) {
      DialogUtil.toast(this.getUIContext(), '还没有可导出的内容');
      return;
    }
    const uri = await fileService.exportCsvToUser(this.csvText);
    if (uri.length === 0) {
      DialogUtil.toast(this.getUIContext(), '未选择保存位置，已取消导出');
      return;
    }
    this.showSheet = false;
    DialogUtil.toast(this.getUIContext(), '报表已保存到你选的文件夹');
  }

  /** 导出可读文本摘要到用户目录 */
  async doText(): Promise<void> {
    if (carbonStore.records.length === 0) {
      DialogUtil.toast(this.getUIContext(), '还没有记录，暂时没有可导出的内容');
      return;
    }
    const uri = await fileService.exportTextToUser(carbonStore.buildTextReport(), TEXT_REPORT_FILE);
    if (uri.length === 0) {
      DialogUtil.toast(this.getUIContext(), '未选择保存位置，已取消导出');
      return;
    }
    DialogUtil.toast(this.getUIContext(), '文本已保存到你选的文件夹');
  }

  /** 开通碳普惠账户（模拟接口调用） */
  async doBind(): Promise<void> {
    // 碳普惠账户挂在账号上，未登录不开户
    if (!(await requireLogin(this.getUIContext(), '开通碳普惠账户'))) {
      return;
    }
    if (this.bankBusy) {
      return;
    }
    this.bankBusy = true;
    const r = await carbonBank.bind('示例市');
    this.bankBusy = false;
    this.refreshBank();
    DialogUtil.toast(this.getUIContext(), r.message);
  }

  /** 一键填入当前可转入的碳积分（自动按单次上限截断） */
  fillAll(): void {
    const avail = this.summary.totalPoint;
    if (avail <= 0) {
      DialogUtil.toast(this.getUIContext(), '没有可转入的碳积分');
      return;
    }
    this.transferInput = `${avail > 5000 ? 5000 : avail}`;
  }

  /** 碳积分转入碳普惠账户（1:1） */
  async doTransfer(): Promise<void> {
    // 转出的是账号碳积分，未登录没有可转出的积分
    if (!(await requireLogin(this.getUIContext(), '转入碳普惠'))) {
      return;
    }
    if (this.bankBusy) {
      return;
    }
    const v = Number(this.transferInput);
    if (isNaN(v) || v <= 0) {
      DialogUtil.toast(this.getUIContext(), '请输入要转入的碳积分数量');
      return;
    }
    this.bankBusy = true;
    const r = await carbonBank.transferIn(v);
    this.bankBusy = false;
    if (r.code === 1006) {
      DialogUtil.toast(this.getUIContext(), `碳积分余额不足，当前 ${this.summary.totalPoint} 分`);
      return;
    }
    if (r.code === 0) {
      // 碳积分被扣减，需要同步刷新账户卡与全局数据版本
      this.refresh();
      this.bump();
    }
    this.refreshBank();
    DialogUtil.toast(this.getUIContext(), r.message);
  }

  /** 兑换权益：先确认，再调接口 */
  async doRedeem(item: OfferView): Promise<void> {
    if (this.bankBusy) {
      return;
    }
    if (item.remain <= 0) {
      DialogUtil.toast(this.getUIContext(), '这个权益已经兑完了');
      return;
    }
    const ok = await DialogUtil.confirm(this.getUIContext(), `兑换${item.offer.name}？`,
      `将花掉 ${item.offer.cost} 碳普惠积分，兑换后不能撤销。`, '兑换', this.p());
    if (!ok) {
      return;
    }
    this.bankBusy = true;
    const r = await carbonBank.redeemOffer(item.offer.id);
    this.bankBusy = false;
    this.refreshBank();
    DialogUtil.toast(this.getUIContext(), r.message);
  }

  /** 从备份恢复 */
  async confirmRestore(): Promise<void> {
    const ok = await DialogUtil.confirm(this.getUIContext(), '从备份恢复数据？',
      `现有 ${carbonStore.records.length} 条记录会被备份内容替换，请确认不再需要当前数据。`, '恢复', Palette.blue);
    if (ok) {
      this.doRestore();
    }
  }

  async doRestore(): Promise<void> {
    const raw = fileService.readBackup();
    if (raw.length === 0) {
      DialogUtil.toast(this.getUIContext(), '没有可用的备份文件');
      return;
    }
    const count = await carbonStore.restoreFromPayload(raw);
    if (count < 0) {
      DialogUtil.toast(this.getUIContext(), '备份文件损坏，或来自更新版本，暂时无法恢复');
      return;
    }
    this.refresh();
    this.refreshBackupState();
    this.bump();
    DialogUtil.toast(this.getUIContext(), `已恢复 ${count} 条记录`);
  }

  async onSaveNick(): Promise<void> {
    const n = this.nick.trim();
    if (n.length === 0) {
      DialogUtil.toast(this.getUIContext(), '昵称不能为空');
      return;
    }
    await carbonStore.setNickName(n);
    this.refresh();
    this.bump();
    DialogUtil.toast(this.getUIContext(), '昵称已保存');
  }

  async onSaveGoal(): Promise<void> {
    const v = Number(this.goalInput);
    if (isNaN(v) || v <= 0) {
      DialogUtil.toast(this.getUIContext(), '请输入一个有效的目标');
      return;
    }
    await carbonStore.setMonthGoal(v);
    this.refresh();
    this.bump();
    DialogUtil.toast(this.getUIContext(), `月目标已设为 ${round(v, 0)} kg`);
  }

  async confirmClear(): Promise<void> {
    const ok = await DialogUtil.confirm(this.getUIContext(), '确定清空所有数据？',
      '所有低碳记录、积分、徽章都会被删除，且无法恢复。', '清空', Palette.danger);
    if (ok) {
      this.doClear();
    }
  }

  async doClear(): Promise<void> {
    await carbonStore.clearAll();
    this.refresh();
    this.bump();
    DialogUtil.toast(this.getUIContext(), '数据已清空');
  }
}

/** 备份文件的最小预览结构（仅用于展示备份时间） */
class BackupPreview {
  exportedAt: string = '';
  version: number = 1;
}
