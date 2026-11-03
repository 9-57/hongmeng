import { router } from '@kit.ArkUI';
import { cloudAccount } from '../service/CloudAccount';
import { DialogUtil } from '../common/DialogUtil';
import { Palette } from '../common/Theme';
import { auth } from '../service/AuthService';

/**
 * 登录 / 注册页。
 * 账号保存在 Supabase 自建 users 表，登录成功后由 CloudAccount 拉取该账号的全量数据；
 * 未登录只能浏览空白模板，记账、领取奖励与兑换都属于账号数据，必须先登录。
 */
@Entry
@Component
struct Login {
  /** 0 = 登录，1 = 注册 */
  /** 主色跟随皮肤 */
  @StorageProp('skinId') skinId: string = 'original';
  @State mode: number = 0;
  @State username: string = '';
  @State password: string = '';
  @State nickname: string = '';
  @State busy: boolean = false;
  @State errorText: string = '';

  aboutToAppear(): void {
    // 已登录时直接返回，避免重复登录
    if (auth.isLoggedIn) {
      router.back();
    }
  }

  private switchMode(next: number): void {
    if (this.busy || this.mode === next) {
      return;
    }
    this.mode = next;
    this.errorText = '';
  }

  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const name = this.username.trim();
    if (name.length < 3 || name.length > 32) {
      this.errorText = '用户名需为 3-32 位';
      return;
    }
    if (this.password.length < 6) {
      this.errorText = '密码至少 6 位';
      return;
    }
    this.errorText = '';
    this.busy = true;
    const res = this.mode === 0
      ? await cloudAccount.login(name, this.password)
      : await cloudAccount.register(name, this.password, this.nickname);
    this.busy = false;
    if (!res.ok) {
      this.errorText = res.message.length > 0 ? res.message : '操作失败，请稍后重试';
      return;
    }
    DialogUtil.toast(this.getUIContext(),
      res.message.length > 0 ? res.message : (this.mode === 0 ? '登录成功' : '注册成功'));
    router.back();
  }

  @Builder
  FieldLabel(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(Palette.textSub)
      .width('100%')
  }

  build() {
    Column({ space: 0 }) {
      // 顶部返回
      Stack() {
        Text(this.mode === 0 ? '登录' : '注册')
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
        }
        .width('100%')
      }
      .width('100%')
      .height(52)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column({ space: 14 }) {
          // 品牌区
          Column({ space: 8 }) {
            Text('🌱')
              .fontSize(44)
            Text('碳足迹')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
            Text('登录后同步你的碳账本、勋章与证书')
              .fontSize(12)
              .fontColor(Palette.textSub)
          }
          .width('100%')
          .padding({ top: 18, bottom: 10 })

          // 表单卡
          Column({ space: 16 }) {
            Column({ space: 6 }) {
              this.FieldLabel('用户名')
              TextInput({ text: this.username, placeholder: '3-32 位，字母或数字' })
                .fontSize(14)
                .height(44)
                .maxLength(32)
                .backgroundColor('#F5F7F6')
                .borderRadius(12)
                .onChange((v: string) => {
                  this.username = v;
                  this.errorText = '';
                })
            }
            .width('100%')

            Column({ space: 6 }) {
              this.FieldLabel('密码')
              TextInput({ text: this.password, placeholder: '至少 6 位' })
                .type(InputType.Password)
                .fontSize(14)
                .height(44)
                .maxLength(64)
                .backgroundColor('#F5F7F6')
                .borderRadius(12)
                .onChange((v: string) => {
                  this.password = v;
                  this.errorText = '';
                })
            }
            .width('100%')

            if (this.mode === 1) {
              Column({ space: 6 }) {
                this.FieldLabel('昵称（可选）')
                TextInput({ text: this.nickname, placeholder: '默认：低碳同学' })
                  .fontSize(14)
                  .height(44)
                  .maxLength(16)
                  .backgroundColor('#F5F7F6')
                  .borderRadius(12)
                  .onChange((v: string) => {
                    this.nickname = v;
                  })
              }
              .width('100%')
            }

            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(11)
                .fontColor(Palette.danger)
                .width('100%')
            }

            Text(this.busy ? '处理中…' : (this.mode === 0 ? '登录' : '注册并登录'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(this.busy ? '#9CCDB4' : Palette.skinById(this.skinId).primary)
              .borderRadius(12)
              .onClick(() => {
                this.submit();
              })

            Row({ space: 4 }) {
              Text(this.mode === 0 ? '还没有账号？' : '已有账号？')
                .fontSize(11)
                .fontColor(Palette.textLight)
              Text(this.mode === 0 ? '注册一个' : '去登录')
                .fontSize(11)
                .fontColor(Palette.skinById(this.skinId).primary)
                .onClick(() => {
                  this.switchMode(this.mode === 0 ? 1 : 0);
                })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor(Palette.card)
          .borderRadius(18)
          .shadow({ radius: 12, color: '#0A1F3D14', offsetY: 3 })

          // 继续以访客身份浏览
          Text('暂不登录，先浏览')
            .fontSize(12)
            .fontColor(Palette.textSub)
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              router.back();
            })

          Text('积分、记录与勋章都跟随账号；未登录时无法记账、领取奖励或兑换勋章')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .textAlign(TextAlign.Center)
            .lineHeight(16)
            .width('100%')
            .padding({ left: 8, right: 8 })
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 24 })
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
