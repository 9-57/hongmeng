import { hilog } from '@kit.PerformanceAnalysisKit';
import { Badge, FamilyInvite } from '../model/CarbonModels';
import { carbonStore } from '../viewmodel/CarbonStore';
import { auth } from '../service/AuthService';
import { notificationService } from '../service/NotificationService';
import { familyService } from '../service/FamilyService';
import { inviteWatcher, INVITE_POLL_MS } from '../service/FamilyInviteWatcher';
import { inviteAlertText, inviteAlertWho } from '../common/InviteAlert';
import { honorTypeName } from '../common/Utils';
import { Palette } from '../common/Theme';
import { DialogUtil } from '../common/DialogUtil';
import { ShareService, ShareOutcome } from '../service/ShareService';
import { HomeTab } from '../view/HomeTab';
import { RecordTab } from '../view/RecordTab';
import { ChartTab } from '../view/ChartTab';
import { LearnTab } from '../view/LearnTab';
import { MineTab } from '../view/MineTab';

/** 空荣誉：弹层只在 honorQueue 非空时挂载，这里只为让取值方法有确定返回 */
const EMPTY_HONOR: Badge = new Badge('', '', '', '', 0, '', '', '', 0);
/** 家庭邀请浮层的展示时长（毫秒）：到点自动消失，只留家庭页里的收件箱 */
const INVITE_ALERT_MS: number = 4000;

@Entry
@Component
struct Index {
  @State current: number = 0;
  /** 登录态：只影响顶栏标签与「我的」页形态，数据刷新统一走 carbonVersion */
  @State loggedIn: boolean = false;
  /**
   * 数据版本号：每次写入数据后 +1。
   * @StorageLink 只能感知首层赋值，故子页面通过 @Watch 监听此值变化并刷新，
   * 避免"记完账首页不更新"的问题。
   */
  @StorageLink('carbonVersion') @Watch('onVersionChange') version: number = 0;
  /** 皮肤切换计数：变化即让各页重绘（主色是运行时变量，不重绘会停在旧颜色） */
  @StorageProp('skinTick') @Watch('onSkinChange') skinTick: number = 0;
  /** 当前皮肤：标题栏主色都经下面的方法取色，读它才会在切换后重绘 */
  @StorageProp('skinId') skinId: string = 'original';
  /** 荣誉放大弹层：新获得的徽章/证书/奖状排队展示；honorFresh 区分"刚获得"和"主动查看" */
  @State honorQueue: Badge[] = [];
  @State showHonor: boolean = false;
  @State honorFresh: boolean = false;
  /** 家庭邀请浮层：有人邀请我时弹 4 秒，可同意 / 取消 / 点卡片进家庭页手动处理 */
  @State inviteVisible: boolean = false;
  @State inviteId: string = '';
  @State inviteName: string = '';
  @State inviteText: string = '';
  /** 底部倒计时条宽度（100 → 0，配合 4 秒动画） */
  @State inviteBar: number = 100;
  private inviteCloseTimer: number = -1;
  @StorageProp('honorViewTick') @Watch('onHonorView') honorViewTick: number = 0;
  @StorageProp('honorViewId') honorViewId: string = '';
  /** 状态栏通知点进来时带的目标分类；切到「记一笔」后由 RecordTab 消费并清空 */
  @StorageLink('pendingCategory') @Watch('onPendingCategory') pendingCategory: string = '';
  /** 多张荣誉排队时，用它把"关掉再用下一张重开"的定时器登记下来 */
  private honorReopen: number = -1;
  // 各 Tab 页的独立刷新令牌，切换页面时递增以触发重新计算
  @State homeToken: number = 0;
  @State recordToken: number = 0;
  @State chartToken: number = 0;
  @State mineToken: number = 0;
  private tabsController: TabsController = new TabsController();
  private titles: string[] = ['碳账本', '记一笔', '数据看板', '低碳科普', '我的'];

  aboutToAppear(): void {
    // UIAbility 里通常已经加载完；这里兜底一次并显式处理失败，避免未捕获的 Promise 拒绝
    carbonStore.load().catch((err: Error) => {
      hilog.error(0x0000, 'carbon', 'store load failed: %{public}s', err.message);
    });
    this.loggedIn = auth.isLoggedIn;
    // 冷启动由通知拉起时，Storage 里的值在页面构造前就已存在，Watch 不会触发，这里补一次
    this.onPendingCategory();
    // 有人邀请我加入家庭：定时问云端，弹一个 4 秒的浮层
    inviteWatcher.start((inv: FamilyInvite) => {
      this.showInvite(inv);
    });
  }

  aboutToDisappear(): void {
    inviteWatcher.stop();
    this.clearInviteTimer();
  }

  /** 页面重新可见时（例如登录页返回）同步登录态，避免顶栏标签停在旧值 */
  onPageShow(): void {
    const now = auth.isLoggedIn;
    if (now !== this.loggedIn) {
      this.loggedIn = now;
      this.homeToken += 1;
      this.recordToken += 1;
      this.chartToken += 1;
      this.mineToken += 1;
    }
    // 回到前台（含登录页返回）立刻查一次邀请，不必等满一个轮询间隔
    inviteWatcher.checkNow();
  }

  /** 数据变化后刷新系统实况窗内容（未开启通知时内部直接跳过） */
  private refreshLiveView(): void {
    notificationService.updateLiveView().catch((err: Error) => {
      hilog.warn(0x0000, 'carbon', 'live view update failed: %{public}s', err.message);
    });
  }

  /** 通知点进来：直接切到「记一笔」，分类由 RecordTab 读取 pendingCategory 后选中 */
  onPendingCategory(): void {
    if (this.pendingCategory.length === 0) {
      return;
    }
    this.current = 1;
    this.tabsController.changeIndex(1);
    this.recordToken += 1;
  }

  /** 首页点「为你推荐」：记住要记的分类，切到「记一笔」并让页面选中它 */
  openRecordFor(categoryId: string): void {
    if (categoryId.length > 0) {
      AppStorage.setOrCreate('pendingCategory', categoryId);
    }
    this.current = 1;
    this.tabsController.changeIndex(1);
    this.recordToken += 1;
  }

  onVersionChange(): void {
    this.loggedIn = auth.isLoggedIn;
    this.homeToken += 1;
    this.recordToken += 1;
    this.chartToken += 1;
    this.mineToken += 1;
    // 记录 / 领取 / 兑换之后实时刷新实况窗的进度与文案
    this.refreshLiveView();
    // 记录 / 领取 / 兑换之后检查有没有新荣誉
    this.checkNewHonors();
  }

  /** 数据变化后看看有没有新荣誉；有就排队，一次一张地放大展示 */
  checkNewHonors(): void {
    const list = carbonStore.takeNewHonors();
    if (list.length === 0) {
      return;
    }
    this.honorFresh = true;
    this.honorQueue = this.honorQueue.concat(list);
    this.showHonor = true;
  }

  /** 从「我的 → 个人荣誉」点开已有荣誉时走这条通道 */
  onHonorView(): void {
    if (this.honorViewId.length === 0) {
      return;
    }
    const b = carbonStore.badgeById(this.honorViewId);
    if (b === undefined) {
      return;
    }
    this.honorFresh = false;
    this.honorQueue = [b];
    this.showHonor = true;
  }

  currentHonor(): Badge {
    return this.honorQueue.length > 0 ? this.honorQueue[0] : EMPTY_HONOR;
  }

  /** 点 × 关闭当前这张；还有排队的就关掉，稍后用下一张重开 */
  closeHonor(): void {
    const rest = this.honorQueue.slice(1);
    this.honorQueue = rest;
    if (rest.length === 0) {
      this.showHonor = false;
      this.honorFresh = false;
      return;
    }
    // content cover 的内容在打开时构建，直接换 badge 不会刷新：
    // 先关掉，等一帧再用队列里的下一张重开，保证每一张都是新内容
    this.showHonor = false;
    if (this.honorReopen !== -1) {
      clearTimeout(this.honorReopen);
    }
    this.honorReopen = setTimeout(() => {
      this.honorReopen = -1;
      this.showHonor = true;
    }, 120);
  }

  honorNote(): string {
    const b = this.currentHonor();
    return b.type === 'achievement' ? `达成条件 · ${b.conditionText}` : '已收入「我的 · 个人荣誉」';
  }

  // ==================== 家庭邀请浮层 ====================

  /** 弹出邀请提示：4 秒后自动关；同一条邀请的去重由 inviteWatcher 负责 */
  showInvite(inv: FamilyInvite): void {
    this.clearInviteTimer();
    this.inviteId = inv.inviteId;
    this.inviteName = inviteAlertWho(inv);
    this.inviteText = inviteAlertText(inv);
    this.inviteBar = 100;
    this.inviteVisible = true;
    this.getUIContext().animateTo({ duration: INVITE_ALERT_MS, curve: Curve.Linear }, () => {
      this.inviteBar = 0;
    });
    this.inviteCloseTimer = setTimeout(() => {
      this.inviteCloseTimer = -1;
      this.inviteVisible = false;
    }, INVITE_ALERT_MS);
  }

  private clearInviteTimer(): void {
    if (this.inviteCloseTimer !== -1) {
      clearTimeout(this.inviteCloseTimer);
      this.inviteCloseTimer = -1;
    }
  }

  /** 取消 = 先不看，邀请还在「我的家庭 → 收到的邀请」里，随时可以手动同意 */
  closeInvite(): void {
    this.clearInviteTimer();
    this.inviteVisible = false;
  }

  /** 点卡片本体：直接进家庭页，手动看详情再决定 */
  openInviteInFamily(): void {
    this.closeInvite();
    this.openFamilyPage();
  }

  /** 在浮层上直接同意：走和家庭页同一条 accept 通道 */
  async acceptInviteFromAlert(): Promise<void> {
    const id = this.inviteId;
    this.closeInvite();
    if (id.length === 0) {
      return;
    }
    const r = await familyService.accept(id);
    DialogUtil.toast(this.getUIContext(), r.ok ? '已加入家庭' : r.message);
    if (r.ok) {
      this.version += 1;
    }
    this.openFamilyPage();
  }

  /** 切到「我的」并把家庭页打开（MineTab 收到 familyOpenTick 后自行 openFamily） */
  openFamilyPage(): void {
    this.current = 4;
    this.tabsController.changeIndex(4);
    this.mineToken += 1;
    let tick: number = 0;
    const cur = AppStorage.get<number>('familyOpenTick');
    if (cur !== undefined) {
      tick = cur;
    }
    AppStorage.setOrCreate('familyOpenPending', true);
    AppStorage.setOrCreate('familyOpenTick', tick + 1);
  }

  /** 皮肤变了：让每个页面都重新走一遍 build，主色才会刷新 */
  onSkinChange(): void {
    this.homeToken += 1;
    this.recordToken += 1;
    this.chartToken += 1;
    this.mineToken += 1;
  }

  p(): string {
    return Palette.skinById(this.skinId).primary;
  }

  pd(): string {
    return Palette.skinById(this.skinId).primaryDark;
  }

  pl(): string {
    return Palette.skinById(this.skinId).primaryLight;
  }

  /** 切换页面时也让目标页重新取数，保证看到的都是最新数据 */
  onTabChange(index: number): void {
    this.current = index;
    if (index === 0) {
      this.homeToken += 1;
    } else if (index === 1) {
      this.recordToken += 1;
    } else if (index === 2) {
      this.chartToken += 1;
    } else if (index === 4) {
      this.mineToken += 1;
    }
  }

  /** 分享减排成果：优先系统分享面板，不支持时降级为剪贴板 */
  async doShare(): Promise<void> {
    if (carbonStore.records.length === 0) {
      DialogUtil.toast(this.getUIContext(), '先记录一条低碳行为，再来分享吧');
      return;
    }
    const outcome = await ShareService.shareText(this.getUIContext(), carbonStore.buildShareText());
    if (outcome === ShareOutcome.PANEL) {
      return;
    }
    if (outcome === ShareOutcome.CLIPBOARD) {
      DialogUtil.toast(this.getUIContext(), '这台手机不支持系统分享，内容已复制，可直接粘贴');
      return;
    }
    DialogUtil.toast(this.getUIContext(), '分享失败，请稍后重试');
  }

  @Builder
  TabItem(index: number, label: string, icon: string) {
    // 单独拆成组件：tabBar 的内容不会随 Index 重建，只有自己观察皮肤变化才会换色
    TabBarItem({ active: this.current === index, label: label, icon: icon })
  }

  /** 荣誉放大弹层：大图标 + 名称 + 说明，下方圆形 × 关闭；内容盖在当前页面之上 */
  @Builder
  HonorLayer() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#B31F2A26')
        .onClick(() => {
          // 吞掉背景点击，只允许下方 × 关闭
        })

      Column({ space: 16 }) {
        Column({ space: 8 }) {
          Text(this.honorFresh ? '获得新荣誉' : '个人荣誉')
            .fontSize(10)
            .fontColor(Palette.textLight)
          Text(this.currentHonor().icon)
            .fontSize(64)
            .width(108)
            .height(108)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.pl())
            .borderRadius(54)
          Text(honorTypeName(this.currentHonor().type))
            .fontSize(10)
            .fontColor(this.pd())
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
            .backgroundColor(this.pl())
            .borderRadius(7)
            .margin({ top: 6 })
          Text(this.currentHonor().name)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
            .textAlign(TextAlign.Center)
          Text(this.currentHonor().desc)
            .fontSize(12)
            .fontColor(Palette.textSub)
            .textAlign(TextAlign.Center)
            .lineHeight(19)
          Text(this.honorNote())
            .fontSize(10)
            .fontColor(Palette.textLight)
            .textAlign(TextAlign.Center)
            .margin({ top: 2 })
        }
        .width('80%')
        .padding({ left: 20, right: 20, top: 20, bottom: 22 })
        .backgroundColor(Palette.card)
        .borderRadius(24)
        .alignItems(HorizontalAlign.Center)
        .shadow({ radius: 24, color: '#40101C16', offsetY: 10 })

        Text('×')
          .fontSize(28)
          .fontColor('#FFFFFF')
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor('#26FFFFFF')
          .border({ width: 1, color: '#66FFFFFF' })
          .borderRadius(24)
          .onClick(() => {
            this.closeHonor();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 家庭邀请浮层：顶部卡片，4 秒倒计时，可同意 / 取消 / 点卡片进家庭页 */
  @Builder
  InviteCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('🌿')
          .fontSize(18)
        Column({ space: 2 }) {
          Text('家庭邀请')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text(`${this.inviteName} · 轻点卡片进入家庭页`)
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('×')
          .fontSize(16)
          .fontColor(Palette.textLight)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.closeInvite();
          })
      }
      .width('100%')

      Text(this.inviteText)
        .fontSize(12)
        .fontColor(Palette.textSub)
        .lineHeight(19)
        .width('100%')

      Row({ space: 10 }) {
        Text('同意')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .height(36)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor(this.p())
          .onClick(() => {
            this.acceptInviteFromAlert();
          })
        Text('取消')
          .fontSize(13)
          .fontColor(Palette.textSub)
          .height(36)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor('#F1F4F2')
          .onClick(() => {
            this.closeInvite();
          })
      }
      .width('100%')

      // 4 秒倒计时条：和自动关闭同一个时长，看得见还剩多久
      Row() {
        Row()
          .width(`${this.inviteBar}%`)
          .height(3)
          .backgroundColor(this.p())
          .borderRadius(2)
      }
      .width('100%')
      .height(3)
      .backgroundColor(Palette.line)
      .borderRadius(2)
    }
    .width('92%')
    .padding(14)
    .margin({ top: 56 })
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .shadow({ radius: 18, color: '#33101C16', offsetY: 6 })
    .onClick(() => {
      this.openInviteInFamily();
    })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        // 顶部标题栏
        Row() {
          Row({ space: 6 }) {
            Text('🌱')
              .fontSize(17)
            Text(this.titles[this.current])
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
          }

          Blank()

          if (this.current === 0) {
            Row({ space: 8 }) {
              Text(this.loggedIn ? '云端同步' : '未登录')
                .fontSize(10)
                .fontColor(this.loggedIn ? this.p() : Palette.textSub)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(this.loggedIn ? this.pl() : '#EEF1EF')
                .borderRadius(8)

              // 分享入口：碳账本页右上角的小图标
              Text('↗')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.p())
                .width(34)
                .height(34)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.pl())
                .borderRadius(17)
                .onClick(() => {
                  this.doShare();
                })
            }
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Palette.bg)

        Tabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.current }) {
          TabContent() {
            HomeTab({
              token: this.homeToken,
              goRecord: (categoryId: string) => {
                this.openRecordFor(categoryId);
              }
            })
          }
          .tabBar(this.TabItem(0, '碳账本', '🏠'))

          TabContent() {
            RecordTab({ token: this.recordToken })
          }
          .tabBar(this.TabItem(1, '记一笔', '➕'))

          TabContent() {
            ChartTab({ token: this.chartToken })
          }
          .tabBar(this.TabItem(2, '数据', '📊'))

          TabContent() {
            LearnTab()
          }
          .tabBar(this.TabItem(3, '科普', '📖'))

          TabContent() {
            MineTab({ token: this.mineToken })
          }
          .tabBar(this.TabItem(4, '我的', '👤'))
        }
        .barHeight(58)
        .barBackgroundColor(Palette.card)
        .scrollable(false)
        .animationDuration(200)
        .layoutWeight(1)
        .onChange((index: number) => {
          this.onTabChange(index);
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Palette.bg)
      .bindContentCover(this.showHonor, this.HonorLayer(), {
        modalTransition: ModalTransition.NONE,
        onDisappear: () => {
          // 关掉后用下一张重开的间隙不要清队列，否则后面几张就丢了
          if (this.honorReopen !== -1) {
            return;
          }
          this.showHonor = false;
          this.honorQueue = [];
          this.honorFresh = false;
        }
      })

      // 家庭邀请浮层：盖在所有 Tab 之上
      if (this.inviteVisible) {
        this.InviteCard()
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 底部标签：自己订阅皮肤计数，切换皮肤后能立即换主色 */
@Component
struct TabBarItem {
  @Prop active: boolean = false;
  @Prop label: string = '';
  @Prop icon: string = '';
  /** 必须读 skinId 本身：主色是静态变量，只有依赖被观察状态才会重绘 */
  @StorageProp('skinId') skinId: string = 'original';

  build() {
    Column({ space: 3 }) {
      Text(this.icon)
        .fontSize(this.active ? 21 : 19)
        .opacity(this.active ? 1 : 0.5)
      Text(this.label)
        .fontSize(10)
        .fontColor(this.active ? Palette.skinById(this.skinId).primary : Palette.textLight)
        .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
