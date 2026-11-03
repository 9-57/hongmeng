import { Palette } from './Theme';

/**
 * 跨页面复用的纯展示结构。
 * 这些内容原来在 Home/Chart/Learn/Mine 四个页面里各抄了一份 @Builder，
 * 改一处样式要同步改四遍，抽到公共文件后只保留一份。
 *
 * 重要：@Builder 的值参数只在构建时求值一次，把进度、统计值这类**会变的状态**
 * 当参数传进去，界面不会跟着刷新（真机上表现为"数字一直是 0"）。所以
 * 需要随状态更新的进度条做成 @Component + @Prop，由框架在数据变化时更新。
 */

/** 空状态占位（内容为常量，用 @Builder 即可） */
@Builder
export function EmptyBox(icon: string, text: string, sub: string) {
  Column({ space: 6 }) {
    Text(icon)
      .fontSize(40)
    Text(text)
      .fontSize(13)
      .fontColor(Palette.textSub)
    if (sub.length > 0) {
      Text(sub)
        .fontSize(11)
        .fontColor(Palette.textLight)
    }
  }
  .width('100%')
  .padding({ top: 28, bottom: 28 })
  .justifyContent(FlexAlign.Center)
}

/** 进度条（背景槽 + 前景条），progress 取 0~1；@Prop 保证数据变化时宽度重算 */
@Component
export struct ProgressBar {
  @Prop progress: number = 0;
  @Prop color: string = Palette.primary;
  @Prop barHeight: number = 6;

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(this.barHeight)
        .backgroundColor('#EFF2F0')
        .borderRadius(this.barHeight / 2)
      Row()
        .width(`${Math.max(2, Math.min(100, this.progress * 100))}%`)
        .height(this.barHeight)
        .backgroundColor(this.color)
        .borderRadius(this.barHeight / 2)
    }
    .width('100%')
  }
}

/** 卡片小标题：左侧竖色条 + 标题 + 可选副标题（内容为常量） */
@Builder
export function SectionTitle(title: string, sub: string) {
  Row() {
    Divider()
      .vertical(false)
      .width(4)
      .height(15)
      .backgroundColor(Palette.primary)
      .borderRadius(2)
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor(Palette.text)
      .margin({ left: 8 })
    if (sub.length > 0) {
      Text(sub)
        .fontSize(11)
        .fontColor(Palette.textLight)
        .margin({ left: 6 })
    }
    Blank()
  }
  .width('100%')
  .padding({ left: 12, right: 12, top: 2, bottom: 2 })
}
