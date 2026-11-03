import { router } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CityOrder, CityReward, cityService, CITY_DEFAULT_BASE } from '../service/CityService';
import { auth } from '../service/AuthService';
import { carbonStore } from '../viewmodel/CarbonStore';
import { DialogUtil } from '../common/DialogUtil';
import { Palette } from '../common/Theme';

/**
 * 城市碳普惠页。
 * 负责：连接模拟城市平台、绑定城市账号、碳积分转出（10:1）、
 * 城市权益兑换与券码查看。所有平台调用都会在电脑端控制台留痕。
 */
@Entry
@Component
struct CityCarbon {
  @State inited: boolean = false;
  @State loading: boolean = false;
  @State loggedIn: boolean = false;
  @State lastLoggedIn: boolean = false;

  /** 平台连接 */
  @State baseUrl: string = '';
  @State baseInput: string = '';
  @State editingBase: boolean = false;
  @State online: boolean = false;
  @State checking: boolean = false;
  @State savingBase: boolean = false;

  /** 城市账号 */
  @State bound: boolean = false;
  @State cityNo: string = '';
  @State cityPoints: number = 0;
  @State appPointsIn: number = 0;
  @State boundAt: string = '';
  @State rate: number = 10;

  /** 碳积分互通 */
  @State appPoint: number = 0;
  @State amountInput: string = '';

  /** 权益与订单 */
  @State rewards: CityReward[] = [];
  @State orders: CityOrder[] = [];
  @State rewardsError: string = '';
  @State ordersError: string = '';

  /** 通用忙状态：绑定 / 转出 / 兑换 */
  @State busy: boolean = false;
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    this.start().catch((err: Error) => {
      this.loading = false;
      hilog.error(0x0000, 'carbon-city', 'page init failed: %{public}s', err.message);
    });
  }

  /** 从登录页返回时检查登录态是否变化，必要时重新初始化 */
  onPageShow(): void {
    if (!this.inited) {
      return;
    }
    if (auth.isLoggedIn !== this.lastLoggedIn) {
      this.start().catch((err: Error) => {
        hilog.error(0x0000, 'carbon-city', 'page reload failed: %{public}s', err.message);
      });
      return;
    }
    this.syncState();
  }

  private async start(): Promise<void> {
    this.loading = true;
    await cityService.init();
    // 换账号后不能沿用上一个账号的城市 token
    if (auth.isLoggedIn && auth.user !== null) {
      await cityService.ensureOwner(auth.user.id);
    }
    this.syncState();
    this.lastLoggedIn = auth.isLoggedIn;
    await this.checkPlatform();
    await this.loadRewards();
    if (cityService.isBound) {
      await this.refreshBalance(false);
      await this.loadOrders();
    } else {
      this.orders = [];
    }
    this.loading = false;
    this.inited = true;
  }

  private syncState(): void {
    this.loggedIn = auth.isLoggedIn;
    this.baseUrl = cityService.baseUrl;
    if (!this.editingBase) {
      this.baseInput = cityService.baseUrl;
    }
    this.bound = cityService.isBound;
    const acc = cityService.account;
    this.cityNo = acc.cityNo;
    this.cityPoints = acc.cityPoints;
    this.appPointsIn = acc.appPointsIn;
    this.boundAt = acc.boundAt;
    this.rate = acc.rate > 0 ? acc.rate : 10;
    this.appPoint = carbonStore.getSummary().totalPoint;
  }

  private async checkPlatform(): Promise<void> {
    this.checking = true;
    const res = await cityService.health();
    this.checking = false;
    this.online = res.online;
    if (res.rate > 0) {
      this.rate = res.rate;
    }
  }

  private async loadRewards(): Promise<void> {
    const res = await cityService.fetchRewards();
    if (res.ok) {
      this.rewards = res.rewards;
      this.rewardsError = '';
      if (res.rate > 0) {
        this.rate = res.rate;
      }
    } else {
      this.rewardsError = res.message;
    }
  }

  private async loadOrders(): Promise<void> {
    if (!cityService.isBound) {
      this.orders = [];
      return;
    }
    const res = await cityService.fetchOrders();
    if (res.ok) {
      this.orders = res.orders;
      this.ordersError = '';
    } else {
      this.ordersError = res.message;
    }
  }

  private async refreshBalance(showToast: boolean): Promise<void> {
    const res = await cityService.refresh();
    this.syncState();
    if (showToast) {
      DialogUtil.toast(this.getUIContext(), res.ok ? '城市积分已刷新' : res.message);
    }
  }

  private async refreshAll(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    await this.checkPlatform();
    await this.loadRewards();
    if (cityService.isBound) {
      await this.refreshBalance(false);
      await this.loadOrders();
    }
    this.refreshing = false;
    this.syncState();
    DialogUtil.toast(this.getUIContext(), this.online ? '已刷新' : '平台未连接，请检查地址与网络');
  }

  private async onSaveBase(): Promise<void> {
    if (this.savingBase) {
      return;
    }
    const ok = await DialogUtil.confirm(this.getUIContext(), '保存平台地址？',
      this.bound
        ? '修改地址会清除本机绑定，需要在新平台重新绑定城市账号。'
        : '请确认手机与电脑连接同一个 Wi-Fi，且电脑端服务已启动。',
      '保存', Palette.primary);
    if (!ok) {
      return;
    }
    this.savingBase = true;
    const res = await cityService.setBaseUrl(this.baseInput);
    this.savingBase = false;
    if (!res.ok) {
      DialogUtil.toast(this.getUIContext(), res.message);
      return;
    }
    this.editingBase = false;
    this.syncState();
    await this.checkPlatform();
    await this.loadRewards();
    await this.loadOrders();
    DialogUtil.toast(this.getUIContext(), res.message);
  }

  private async onBind(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!auth.isLoggedIn) {
      this.goLogin();
      return;
    }
    this.busy = true;
    const userId = auth.user === null ? auth.username : auth.user.id;
    const res = await cityService.bind(userId, auth.username);
    this.busy = false;
    this.syncState();
    DialogUtil.toast(this.getUIContext(), res.message);
    if (res.ok) {
      await this.refreshBalance(false);
      await this.loadOrders();
    }
  }

  private async onUnbind(): Promise<void> {
    const ok = await DialogUtil.confirm(this.getUIContext(), '解绑城市账号？',
      '只清除本机绑定，平台上的城市积分与订单不会丢失；重新绑定会恢复同一个城市账号。',
      '解绑', Palette.danger);
    if (!ok) {
      return;
    }
    await cityService.clearBinding();
    this.orders = [];
    this.ordersError = '';
    this.syncState();
    DialogUtil.toast(this.getUIContext(), '已解绑城市账号');
  }

  private async onTransfer(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.loggedIn) {
      this.goLogin();
      return;
    }
    if (!this.bound) {
      DialogUtil.toast(this.getUIContext(), '请先绑定城市碳普惠账号');
      return;
    }
    const amount = Number(this.amountInput);
    if (!isFinite(amount) || amount <= 0) {
      DialogUtil.toast(this.getUIContext(), '请输入要转出的碳积分');
      return;
    }
    if (amount % this.ratio() !== 0) {
      DialogUtil.toast(this.getUIContext(), `转出积分需为 ${this.ratio()} 的倍数`);
      return;
    }
    if (amount > this.appPoint) {
      DialogUtil.toast(this.getUIContext(), `可用碳积分不足（当前 ${this.appPoint} 分）`);
      return;
    }
    const gain = Math.floor(amount / this.ratio());
    const ok = await DialogUtil.confirm(this.getUIContext(), '确认转出碳积分？',
      `将转出 ${amount} 碳积分，按 ${this.ratio()}:1 兑换为 ${gain} 城市积分。转出后本地碳积分立即扣除，不可撤回。`,
      '确认转出', Palette.primary);
    if (!ok) {
      return;
    }
    this.busy = true;
    const res = await cityService.transfer(amount);
    this.busy = false;
    this.syncState();
    DialogUtil.toast(this.getUIContext(), res.message);
    if (res.ok) {
      this.amountInput = '';
    }
  }

  private async onRedeem(reward: CityReward): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.bound) {
      DialogUtil.toast(this.getUIContext(), '请先绑定城市碳普惠账号');
      return;
    }
    if (reward.stock <= 0) {
      DialogUtil.toast(this.getUIContext(), '该权益已兑完');
      return;
    }
    if (this.cityPoints < reward.cost) {
      DialogUtil.toast(this.getUIContext(),
        `城市积分不足，还需 ${reward.cost - this.cityPoints} 分`);
      return;
    }
    const ok = await DialogUtil.confirm(this.getUIContext(), '确认兑换权益？',
      `将使用 ${reward.cost} 城市积分兑换「${reward.name}」，兑换成功后生成唯一券码。`,
      '确认兑换', Palette.primary);
    if (!ok) {
      return;
    }
    this.busy = true;
    const res = await cityService.redeem(reward.id);
    this.busy = false;
    this.syncState();
    if (res.ok) {
      await this.loadRewards();
      await this.loadOrders();
      DialogUtil.toast(this.getUIContext(), `兑换成功，券码 ${res.voucherCode}`);
    } else {
      DialogUtil.toast(this.getUIContext(), res.message);
    }
  }

  private copyVoucher(code: string): void {
    if (code.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        DialogUtil.toast(this.getUIContext(), '券码已复制');
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, 'carbon-city', 'copy failed: %{public}s', JSON.stringify(err));
        DialogUtil.toast(this.getUIContext(), '复制失败，请长按券码手动复制');
      });
    } catch (e) {
      hilog.warn(0x0000, 'carbon-city', 'pasteboard threw');
      DialogUtil.toast(this.getUIContext(), '复制失败，请长按券码手动复制');
    }
  }

  private goLogin(): void {
    router.pushUrl({ url: 'pages/Login' }).catch(() => {
      DialogUtil.toast(this.getUIContext(), '打开登录页失败，请稍后重试');
    });
  }

  private ratio(): number {
    return this.rate > 0 ? this.rate : 10;
  }

  private gainText(): string {
    const amount = Number(this.amountInput);
    if (!isFinite(amount) || amount <= 0) {
      return `按 ${this.ratio()}:1 兑换`;
    }
    return `预计获得 ${Math.floor(amount / this.ratio())} 城市积分`;
  }

  private orderStatusText(status: string): string {
    if (status === 'paid') {
      return '已支付';
    }
    if (status === 'cancelled') {
      return '已取消';
    }
    return status.length > 0 ? status : '已完成';
  }

  @Styles
  cardStyle() {
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .shadow({ radius: 12, color: '#0A1F3D14', offsetY: 3 })
  }

  @Builder
  TopBar() {
    Stack() {
      Text('城市碳普惠')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
      Row() {
        Text('←')
          .fontSize(20)
          .fontColor(Palette.text)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Blank()
        Text(this.checking ? '检测中…' : (this.online ? '平台在线' : '平台离线'))
          .fontSize(10)
          .fontColor(this.online ? Palette.primaryDark : Palette.textLight)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.online ? Palette.primaryLight : '#EEF1EF')
          .borderRadius(8)
      }
      .width('100%')
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 14 })
  }

  @Builder
  LoadingCard() {
    Row({ space: 10 }) {
      Text('🏙️')
        .fontSize(22)
      Text('正在连接城市碳普惠平台…')
        .fontSize(12)
        .fontColor(Palette.textSub)
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Palette.card)
    .borderRadius(16)
  }

  @Builder
  ConnectionCard() {
    Column({ space: 10 }) {
      Row() {
        Text('平台连接')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text(this.refreshing ? '刷新中…' : '刷新')
          .fontSize(11)
          .fontColor(Palette.primary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(Palette.primaryLight)
          .borderRadius(8)
          .onClick(() => {
            this.refreshAll();
          })
      }
      .width('100%')

      Row() {
        Text('服务地址')
          .fontSize(11)
          .fontColor(Palette.textSub)
          .width(62)
        Text(this.baseUrl)
          .fontSize(11)
          .fontColor(Palette.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.editingBase ? '收起' : '修改')
          .fontSize(11)
          .fontColor(Palette.primary)
          .padding({ left: 10 })
          .onClick(() => {
            this.editingBase = !this.editingBase;
            if (this.editingBase) {
              this.baseInput = this.baseUrl;
            }
          })
      }
      .width('100%')

      Row() {
        Text('可用碳积分')
          .fontSize(11)
          .fontColor(Palette.textSub)
          .width(62)
        Text(`${this.appPoint} 分`)
          .fontSize(11)
          .fontColor(Palette.primaryDark)
        Blank()
        Text(`兑换比例 ${this.ratio()}:1`)
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .width('100%')

      if (this.editingBase) {
        Column({ space: 8 }) {
          TextInput({ text: this.baseInput, placeholder: 'http://192.168.0.161:8080' })
            .fontSize(12)
            .height(40)
            .backgroundColor('#F5F7F6')
            .borderRadius(10)
            .onChange((v: string) => {
              this.baseInput = v;
            })

          Row({ space: 8 }) {
            Text(this.savingBase ? '保存中…' : '保存地址')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .padding({ top: 9, bottom: 9 })
              .backgroundColor(this.savingBase ? '#9CCDB4' : Palette.primary)
              .borderRadius(10)
              .onClick(() => {
                this.onSaveBase();
              })

            Text('恢复默认')
              .fontSize(12)
              .fontColor(Palette.textSub)
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .backgroundColor('#F1F4F2')
              .borderRadius(10)
              .onClick(() => {
                this.baseInput = CITY_DEFAULT_BASE;
              })
          }
          .width('100%')
        }
        .width('100%')
      }

      Text('手机与电脑需连接同一 Wi-Fi。电脑先运行 D:\\hongmeng_qianduan\\start.bat，启动日志里的局域网地址就是这里要填的地址。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
    }
    .cardStyle()
  }

  @Builder
  LoginCard() {
    Column({ space: 10 }) {
      Text('登录后绑定城市账号')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
      Text('城市碳普惠账号会绑定到你的碳足迹账号，城市积分、兑换订单与你的碳账本一一对应。')
        .fontSize(11)
        .fontColor(Palette.textSub)
        .lineHeight(17)
      Text('去登录 / 注册')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 11, bottom: 11 })
        .backgroundColor(Palette.primary)
        .borderRadius(11)
        .onClick(() => {
          this.goLogin();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .cardStyle()
  }

  @Builder
  BindCard() {
    Column({ space: 10 }) {
      Text('绑定城市碳普惠账号')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
      Text('绑定后平台会为你开立城市碳账户，用于接收碳积分、兑换城市权益。同一碳足迹账号重复绑定会恢复原城市账号。')
        .fontSize(11)
        .fontColor(Palette.textSub)
        .lineHeight(17)
      Row({ space: 6 }) {
        Text('当前碳足迹账号')
          .fontSize(10)
          .fontColor(Palette.textLight)
        Text(auth.username.length > 0 ? auth.username : '已登录')
          .fontSize(10)
          .fontColor(Palette.textSub)
      }
      .width('100%')

      Text(this.busy ? '绑定中…' : (this.online ? '立即绑定' : '平台离线，仍可尝试绑定'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 11, bottom: 11 })
        .backgroundColor(this.busy ? '#9CCDB4' : Palette.primary)
        .borderRadius(11)
        .onClick(() => {
          this.onBind();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .cardStyle()
  }

  @Builder
  AccountCard() {
    Column({ space: 12 }) {
      Row() {
        Text('城市碳账户')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text('解绑')
          .fontSize(10)
          .fontColor(Palette.danger)
          .onClick(() => {
            this.onUnbind();
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('🏙️')
          .fontSize(24)
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor(Palette.primaryLight)
          .borderRadius(24)
        Column({ space: 2 }) {
          Text(this.cityNo.length > 0 ? this.cityNo : '城市账号')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
          Text(this.boundAt.length > 0 ? `绑定于 ${this.boundAt}` : '已绑定')
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('刷新')
          .fontSize(11)
          .fontColor(Palette.primary)
          .onClick(() => {
            this.refreshBalance(true);
          })
      }
      .width('100%')

      Row() {
        this.StatCell('城市积分', 'city')
        this.StatCell('累计转入', 'in')
        this.StatCell('兑换比例', 'rate')
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .backgroundColor('#F6F9F7')
      .borderRadius(12)
    }
    .cardStyle()
  }

  /** 数值直接在这里读状态：@Builder 的值参数不会随状态变化重新计算 */
  private statValue(kind: string): string {
    if (kind === 'city') {
      return `${this.cityPoints}`;
    }
    if (kind === 'in') {
      return `${this.appPointsIn} 分`;
    }
    return `${this.ratio()}:1`;
  }

  @Builder
  StatCell(label: string, kind: string) {
    Column({ space: 3 }) {
      Text(this.statValue(kind))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.primaryDark)
      Text(label)
        .fontSize(9)
        .fontColor(Palette.textLight)
    }
    .layoutWeight(1)
  }

  @Builder
  TransferCard() {
    Column({ space: 12 }) {
      Row() {
        Text('积分互通')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text(this.gainText())
          .fontSize(10)
          .fontColor(Palette.primary)
      }
      .width('100%')

      Row() {
        this.BalanceCell('可用碳积分', 'app', Palette.primaryDark)
        Text('→')
          .fontSize(16)
          .fontColor(Palette.textLight)
          .width(30)
          .textAlign(TextAlign.Center)
        this.BalanceCell('城市积分', 'city', Palette.blue)
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.amountInput, placeholder: '输入转出碳积分（10 的倍数）' })
          .type(InputType.Number)
          .fontSize(12)
          .height(40)
          .maxLength(6)
          .backgroundColor('#F5F7F6')
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.amountInput = v;
          })
        Text(this.busy ? '处理中…' : '确认转出')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(this.busy ? '#9CCDB4' : Palette.primary)
          .borderRadius(10)
          .onClick(() => {
            this.onTransfer();
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        this.QuickAmount(10)
        this.QuickAmount(50)
        this.QuickAmount(100)
        Text('全部')
          .fontSize(11)
          .fontColor(Palette.textSub)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor('#F1F4F2')
          .borderRadius(8)
          .onClick(() => {
            const usable = Math.floor(this.appPoint / this.ratio()) * this.ratio();
            this.amountInput = usable > 0 ? `${usable}` : '';
          })
      }
      .width('100%')

      Text('转出先在本地记账扣分，再调用城市平台加分；平台调用失败会自动退回本地积分，不会丢失。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
    }
    .cardStyle()
  }

  private balanceValue(kind: string): string {
    return kind === 'app' ? `${this.appPoint}` : `${this.cityPoints}`;
  }

  @Builder
  BalanceCell(label: string, kind: string, color: string) {
    Column({ space: 3 }) {
      Text(this.balanceValue(kind))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(9)
        .fontColor(Palette.textLight)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  QuickAmount(amount: number) {
    Text(`${amount}`)
      .fontSize(11)
      .fontColor(Palette.textSub)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor('#F1F4F2')
      .borderRadius(8)
      .onClick(() => {
        this.amountInput = `${amount}`;
      })
  }

  @Builder
  RewardsCard() {
    Column({ space: 10 }) {
      Row() {
        Text('城市权益')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        if (this.rewards.length > 0) {
          Text(`${this.rewards.length} 项可兑换`)
            .fontSize(10)
            .fontColor(Palette.textLight)
        }
      }
      .width('100%')

      if (this.rewards.length === 0) {
        Text(this.rewardsError.length > 0 ? this.rewardsError : '暂无可兑换权益')
          .fontSize(11)
          .fontColor(this.rewardsError.length > 0 ? Palette.danger : Palette.textLight)
          .lineHeight(17)
          .width('100%')
      } else {
        ForEach(this.rewards, (reward: CityReward) => {
          this.RewardRow(reward)
        }, (reward: CityReward) => `${reward.id}_${reward.stock}_${this.cityPoints}_${this.bound}`)
      }

      Text('权益由模拟城市碳普惠平台提供，仅用于演示积分互通与兑换闭环，不涉及真实交易。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
    }
    .cardStyle()
  }

  @Builder
  RewardRow(reward: CityReward) {
    Row({ space: 10 }) {
      Text(reward.icon.length > 0 ? reward.icon : '🎁')
        .fontSize(22)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .backgroundColor('#F4F7F5')
        .borderRadius(12)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(reward.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (reward.category.length > 0) {
            Text(reward.category)
              .fontSize(9)
              .fontColor(Palette.primaryDark)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(Palette.primaryLight)
              .borderRadius(5)
          }
        }
        .width('100%')

        Text(reward.desc)
          .fontSize(10)
          .fontColor(Palette.textSub)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(15)

        Row({ space: 10 }) {
          Text(`${reward.cost} 城市积分`)
            .fontSize(10)
            .fontColor(Palette.primaryDark)
          Text(`库存 ${reward.stock}`)
            .fontSize(10)
            .fontColor(reward.stock > 0 ? Palette.textLight : Palette.danger)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.rewardActionText(reward))
        .fontSize(11)
        .fontColor(this.rewardActionColor(reward))
        .textAlign(TextAlign.Center)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.rewardActionBg(reward))
        .borderRadius(8)
        .onClick(() => {
          this.onRedeem(reward);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  private rewardActionText(reward: CityReward): string {
    if (!this.bound) {
      return '未绑定';
    }
    if (reward.stock <= 0) {
      return '已兑完';
    }
    if (this.cityPoints < reward.cost) {
      return '积分不足';
    }
    return '兑换';
  }

  private rewardActionColor(reward: CityReward): string {
    if (!this.bound || reward.stock <= 0 || this.cityPoints < reward.cost) {
      return Palette.textLight;
    }
    return '#FFFFFF';
  }

  private rewardActionBg(reward: CityReward): string {
    if (!this.bound || reward.stock <= 0 || this.cityPoints < reward.cost) {
      return '#EFF2F0';
    }
    return Palette.primary;
  }

  @Builder
  OrdersCard() {
    Column({ space: 10 }) {
      Row() {
        Text('兑换记录')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.text)
        Blank()
        Text(this.orders.length > 0 ? `共 ${this.orders.length} 单` : '')
          .fontSize(10)
          .fontColor(Palette.textLight)
      }
      .width('100%')

      if (this.orders.length === 0) {
        Text(this.ordersError.length > 0 ? this.ordersError : '还没有兑换记录，去选一项权益试试')
          .fontSize(11)
          .fontColor(this.ordersError.length > 0 ? Palette.danger : Palette.textLight)
          .lineHeight(17)
          .width('100%')
      } else {
        ForEach(this.orders, (order: CityOrder) => {
          this.OrderRow(order)
        }, (order: CityOrder) => order.orderNo)
      }
    }
    .cardStyle()
  }

  @Builder
  OrderRow(order: CityOrder) {
    Column({ space: 6 }) {
      Row() {
        Text(order.rewardName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(`${order.cost} 城市积分`)
          .fontSize(10)
          .fontColor(Palette.textSub)
      }
      .width('100%')

      Row() {
        Text(order.createdAt)
          .fontSize(9)
          .fontColor(Palette.textLight)
        Blank()
        Text(this.orderStatusText(order.status))
          .fontSize(9)
          .fontColor(Palette.primary)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(order.voucherCode)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.primaryDark)
          .letterSpacing(0.5)
          .copyOption(CopyOptions.LocalDevice)
          .layoutWeight(1)
        Text('复制')
          .fontSize(10)
          .fontColor(Palette.blue)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#EEF4FC')
          .borderRadius(7)
          .onClick(() => {
            this.copyVoucher(order.voucherCode);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .backgroundColor('#F6F9F7')
      .borderRadius(9)

      Text(`订单号 ${order.orderNo}`)
        .fontSize(9)
        .fontColor(Palette.textLight)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({
      width: { bottom: 0.5 },
      color: Palette.line
    })
  }

  @Builder
  AboutCard() {
    Column({ space: 8 }) {
      Text('对接说明')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.text)
        .width('100%')
      Text(`接口地址：${this.baseUrl}/api/v1`)
        .fontSize(10)
        .fontColor(Palette.textSub)
        .width('100%')
      Text(`兑换比例：${this.ratio()} 碳积分 = 1 城市积分；转出与兑换都带请求编号，重复请求不会重复扣分或出券。`)
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
      Text('电脑端打开平台控制台可以实时查看本页发起的每一次调用、互通账号、积分流水与兑换订单。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
      Text('本平台为课程演示用的模拟城市碳普惠服务，所有积分与权益均为虚拟数据。')
        .fontSize(10)
        .fontColor(Palette.textLight)
        .lineHeight(16)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .cardStyle()
  }

  build() {
    Column({ space: 0 }) {
      this.TopBar()

      Scroll() {
        Column({ space: 12 }) {
          if (this.loading && !this.inited) {
            this.LoadingCard()
          } else {
            this.ConnectionCard()

            if (!this.loggedIn) {
              this.LoginCard()
            } else if (!this.bound) {
              this.BindCard()
            } else {
              this.AccountCard()
              this.TransferCard()
            }

            this.RewardsCard()

            if (this.bound) {
              this.OrdersCard()
            }

            this.AboutCard()
          }

          Divider().height(6).color(Color.Transparent)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.bg)
  }
}
