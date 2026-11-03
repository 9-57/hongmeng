import { Article } from '../model/CarbonModels';
import { ARTICLES, SECTIONS, Section } from '../model/ArticleData';
import { carbonStore } from '../viewmodel/CarbonStore';
import { Palette } from '../common/Theme';
import { EmptyBox } from '../common/Widgets';

@Component
export struct LearnTab {
  @State @Watch('applyFilter') section: string = 'all';
  @State @Watch('applyFilter') keyword: string = '';
  @State openId: string = '';
  /** 筛选结果缓存：原来 build 里 filtered() 被调两次，每次全量过滤 */
  @State list: Article[] = [];

  aboutToAppear(): void {
    this.applyFilter();
  }

  applyFilter(): void {
    const kw = this.keyword.trim();
    this.list = ARTICLES.filter((a: Article) => {
      const okSec = this.section === 'all' || a.section === this.section;
      const okKw = kw.length === 0 || a.title.includes(kw) || a.summary.includes(kw) ||
        a.tags.some((t: string) => t.includes(kw));
      return okSec && okKw;
    });
  }

  /** 当前展开的文章（统一走 store 的索引，不在页面里再 filter 一遍） */
  openArticle(): Article | null {
    if (this.openId.length === 0) {
      return null;
    }
    const hit = carbonStore.getArticleById(this.openId);
    return hit === undefined ? null : hit;
  }

  @Builder
  ArticleCard(a: Article) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(a.icon)
          .fontSize(18)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor(Palette.primaryLight)
          .borderRadius(11)

        Column({ space: 3 }) {
          Text(a.title)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(this.sectionName(a.section))
              .fontSize(9)
              .fontColor(Palette.primary)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(Palette.primaryLight)
              .borderRadius(4)
            Text(`${a.readMinutes} 分钟`)
              .fontSize(9)
              .fontColor(Palette.textLight)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Text(a.summary)
        .fontSize(11)
        .fontColor(Palette.textSub)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(17)

      Row({ space: 5 }) {
        ForEach(a.tags, (t: string) => {
          Text(`#${t}`)
            .fontSize(9)
            .fontColor(Palette.textLight)
        }, (t: string) => `${a.id}_${t}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.card)
    .borderRadius(16)
    .shadow({ radius: 10, color: '#0A1F3D10', offsetY: 2 })
    .onClick(() => {
      // 搜索框有焦点时点文章，键盘不会自动消失，会把详情挤掉半屏
      this.getUIContext().getFocusController().clearFocus();
      this.openId = a.id;
    })
  }

  sectionName(id: string): string {
    const hit = SECTIONS.filter((s: Section) => s.id === id);
    return hit.length > 0 ? hit[0].name : '';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: 12 }) {
          // 头部
          Column({ space: 10 }) {
            Row() {
              Column({ space: 3 }) {
                Text('双碳科普')
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                Text('搞懂减碳这件事，比打卡更重要')
                  .fontSize(11)
                  .fontColor('#C9E4D5')
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              Text('📚')
                .fontSize(34)
            }
            .width('100%')

            Row({ space: 8 }) {
              Text('🔍')
                .fontSize(13)
              TextInput({ text: this.keyword, placeholder: '搜标题、标签，如"光盘""碳中和"' })
                .placeholderFont({ size: 12 })
                .placeholderColor('#8FA79A')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .backgroundColor(Color.Transparent)
                .padding(0)
                .height(34)
                .maxLength(20)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.keyword = v;
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
            .backgroundColor('#1FFFFFFF')
            .borderRadius(12)
          }
          .width('100%')
          .padding(16)
          .borderRadius(18)
          .linearGradient({
            angle: 150,
            colors: [['#3AAE7A', 0], ['#1E6B4A', 1]]
          })

          // 栏目切换
          Row({ space: 8 }) {
            Text('全部')
              .fontSize(12)
              .fontColor(this.section === 'all' ? '#FFFFFF' : Palette.textSub)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.section === 'all' ? Palette.primary : Palette.card)
              .borderRadius(10)
              .onClick(() => {
                this.section = 'all';
              })
            ForEach(SECTIONS, (s: Section) => {
              Text(`${s.icon} ${s.name}`)
                .fontSize(12)
                .fontColor(this.section === s.id ? '#FFFFFF' : Palette.textSub)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.section === s.id ? Palette.primary : Palette.card)
                .borderRadius(10)
                .onClick(() => {
                  this.section = s.id;
                })
            }, (s: Section) => `${s.id}_${this.section === s.id}`)
          }
          .width('100%')

          if (this.list.length === 0) {
            EmptyBox('📖', '没有找到相关内容', '换个关键词试试')
          } else {
            ForEach(this.list, (a: Article) => {
              this.ArticleCard(a)
            }, (a: Article) => a.id)
          }

          Divider().height(6).color(Color.Transparent)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 20 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 详情浮层
      if (this.openId.length > 0) {
        ArticleDetail(this.openArticle(), () => {
          this.openId = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 科普文章详情浮层（纯展示，无独立状态，用 @Builder 省一层组件） */
@Builder
export function ArticleDetail(article: Article | null, onClose: () => void) {
  Column() {
    // 顶栏
    Row({ space: 8 }) {
      Text('‹')
        .fontSize(26)
        .fontColor(Palette.text)
        .width(30)
        .onClick(() => {
          onClose();
        })
      Text('科普详情')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.text)
      Blank()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Palette.card)

    Scroll() {
      Column({ space: 14 }) {
        if (article !== null) {
          Column({ space: 10 }) {
            Text(article!.icon)
              .fontSize(38)
            Text(article!.title)
              .fontSize(21)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
              .lineHeight(30)
            Row({ space: 8 }) {
              Text(`${article!.readMinutes} 分钟阅读`)
                .fontSize(10)
                .fontColor(Palette.textLight)
              ForEach(article!.tags, (t: string) => {
                Text(`#${t}`)
                  .fontSize(10)
                  .fontColor(Palette.primary)
              }, (t: string) => `d_${t}`)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 摘要
          Text(article!.summary)
            .fontSize(12)
            .fontColor(Palette.textSub)
            .lineHeight(21)
            .width('100%')
            .padding(14)
            .backgroundColor(Palette.primaryLight)
            .borderRadius(12)

          // 正文
          ForEach(article!.paragraphs, (p: string, i: number) => {
            Text(p)
              .fontSize(14)
              .fontColor('#333F3A')
              .lineHeight(26)
              .width('100%')
          }, (p: string, i: number) => `p_${i}`)

          // 要点
          Column({ space: 8 }) {
            Text('📌 划重点')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.text)
            ForEach(article!.keyPoints, (k: string, i: number) => {
              Row({ space: 8 }) {
                Row()
                  .width(5)
                  .height(5)
                  .backgroundColor(Palette.primary)
                  .borderRadius(3)
                  .margin({ top: 7 })
                Text(k)
                  .fontSize(12)
                  .fontColor(Palette.textSub)
                  .lineHeight(20)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (k: string, i: number) => `k_${i}`)
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#F7F9F8')
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Text('内容为公开资料整理，用于科普与竞赛演示')
            .fontSize(10)
            .fontColor(Palette.textLight)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8, bottom: 20 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }
  .width('100%')
  .height('100%')
  .backgroundColor(Palette.bg)
}
