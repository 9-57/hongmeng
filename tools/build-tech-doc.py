#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成《碳足迹 · 全民绿色生活碳积分与减排指南》技术文档（DOCX）。

数据来源：直接解析仓库里的真实源码（CarbonData / ArticleData / 文件行数），
避免文档与实现脱节。运行：

    python tools/build-tech-doc.py
产物：
    docs/碳足迹_技术文档_v1.0.docx
"""
import re
from pathlib import Path

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry" / "src" / "main" / "ets"
OUT = ROOT / "docs" / "碳足迹_技术文档_v1.0.docx"

BODY_CN = "宋体"
HEAD_CN = "黑体"
WEST = "Times New Roman"
INK = RGBColor(0x1F, 0x2A, 0x26)
MUTED = RGBColor(0x5A, 0x66, 0x62)
GREEN = RGBColor(0x2F, 0x9E, 0x68)
HEAD_FILL = "E8F4EE"


# ---------------------------------------------------------------- 数据解析
def read(name: str) -> str:
    return (ETS / name).read_text(encoding="utf-8")


def parse_categories():
    text = read("model/CarbonData.ets")
    pat = re.compile(r"new Category\('([^']+)', '([^']+)', '([^']+)', '([^']+)', '([^']+)'\)")
    return [{"id": m[0], "name": m[1], "icon": m[2], "color": m[3], "desc": m[4]} for m in pat.findall(text)]


def parse_activities():
    text = read("model/CarbonData.ets")
    pat = re.compile(
        r"new Activity\('([^']+)', '([^']+)', '([^']+)', '([^']+)', '([^']+)', "
        r"([0-9.]+), ([0-9]+),"
    )
    rows = []
    for m in pat.findall(text):
        rows.append({
            "id": m[0], "cat": m[1], "name": m[2], "icon": m[3], "unit": m[4],
            "factor": float(m[5]), "point": int(m[6]),
        })
    return rows


def parse_articles():
    text = read("model/ArticleData.ets")
    pat = re.compile(r"new Article\('([^']+)', '([^']+)', '([^']+)'")
    return [{"id": m[0], "title": m[1], "section": m[2]} for m in pat.findall(text)]


CATS = parse_categories()
ACTS = parse_activities()
ARTICLES = parse_articles()
CAT_NAME = {c["id"]: c["name"] for c in CATS}
CAT_ICON = {c["id"]: c["icon"] for c in CATS}
SECTION_NAME = {"policy": "政策", "knowledge": "知识", "tips": "技巧"}

FILES = sorted(
    ((p.relative_to(ETS).as_posix(), len(p.read_text(encoding="utf-8").splitlines()))
     for p in ETS.rglob("*.ets")),
    key=lambda x: -x[1],
)
TOTAL_LINES = sum(n for _, n in FILES)

RESP = {
    "entryability/EntryAbility.ets": "应用入口：初始化存储/文件服务、恢复会话、加载首屏",
    "entrybackupability/EntryBackupAbility.ets": "系统备份扩展：把 preferences 纳入系统备份",
    "workscheduler/CarbonWorkScheduler.ets": "后台周期任务扩展：进程退出后仍能推送实况窗",
    "pages/Index.ets": "主框架：5 个 Tab、荣誉弹层、实况窗刷新、皮肤广播",
    "pages/Login.ets": "登录 / 注册页（自建 Supabase 账号）",
    "pages/CityCarbon.ets": "城市碳普惠：绑定、积分转入转出、订单",
    "model/CarbonModels.ets": "纯数据类型：行为、记录、徽章、任务、统计",
    "model/CarbonData.ets": "碳因子库 33 条行为 + 18 枚徽章 + 6 个每日任务 + 等级表",
    "model/ArticleData.ets": "双碳科普文章",
    "viewmodel/CarbonStore.ets": "业务中心：记录增删、积分、统计、任务、徽章、备份",
    "view/HomeTab.ets": "碳账本：总览、目标、任务、趋势、构成、最近记录",
    "view/RecordTab.ets": "记一笔：选择行为、试算、保存；图片识别入口与结果面板",
    "view/ChartTab.ets": "数据看板：日/周/月/年趋势、分类对比、占比、TOP5、历史",
    "view/LearnTab.ets": "科普：搜索、栏目、文章详情",
    "view/MineTab.ets": "我的：等级、复盘、荣誉、兑换、证书、家庭、设置、备份",
    "components/Charts.ets": "自绘图表：折线面积图、圆角柱、环形图（Canvas）",
    "common/Theme.ets": "配色与皮肤（5 套主色）",
    "common/Utils.ets": "日期、格式化、CSV 转义、ID、数据版本广播",
    "common/Widgets.ets": "跨页复用组件：空态、进度条、分组标题",
    "common/DialogUtil.ets": "Toast / 确认框（UIContext 新接口）",
    "service/StorageService.ets": "preferences 键值持久化",
    "service/FileService.ets": "沙箱文件读写：备份 JSON、CSV 报表",
    "service/AuthService.ets": "会话 token 与账号信息管理",
    "service/SupabaseClient.ets": "Supabase RPC 调用（anon key + RLS）",
    "service/CloudAccount.ets": "云端业务：登录、快照、记账、任务、兑换、清空、恢复",
    "service/FamilyService.ets": "家庭减碳：建家、加入、邀请、退出、汇总",
    "service/CityService.ets": "城市碳普惠平台对接（含模拟模式）",
    "service/CarbonBankService.ets": "碳普惠账户与商品兑换（本地模拟）",
    "service/InsightService.ets": "个性化推荐与建议规则",
    "service/NotificationService.ets": "通知权限、实况窗、周期推送、WorkScheduler",
    "service/ShareService.ets": "系统分享 / 剪贴板降级",
    "service/SkinService.ets": "皮肤持久化",
    "service/AccountGate.ets": "未登录拦截：会改动账号数据的操作先引导登录",
    "service/AIRecognitionService.ets": "视觉模型调用：提示词、HTTP、解析、容错",
    "service/ImageRecognitionService.ets": "选图、AI 判定转候选（端侧兜底已删除）",
    "service/AutoRecordPolicy.ets": "自动记账策略：同图去重、单行为日上限（纯函数）",
    "service/AutoRecordService.ets": "图片指纹、台账、本地/云端落库",
}


# ---------------------------------------------------------------- 排版工具
def cn_font(run, name=BODY_CN, size=12, bold=False, color=INK):
    run.font.name = WEST
    run.font.size = Pt(size)
    run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color
    rpr = run._element.get_or_add_rPr()
    fonts = rpr.find(qn("w:rFonts"))
    if fonts is None:
        fonts = OxmlElement("w:rFonts")
        rpr.append(fonts)
    fonts.set(qn("w:ascii"), WEST)
    fonts.set(qn("w:hAnsi"), WEST)
    fonts.set(qn("w:eastAsia"), name)


def body(text, indent=True, size=12, space_after=6, align=None, color=INK):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = 1.5
    pf.space_before = Pt(0)
    pf.space_after = Pt(space_after)
    if indent:
        pf.first_line_indent = Pt(size * 2)
    if align is not None:
        p.alignment = align
    run = p.add_run(text)
    cn_font(run, BODY_CN, size, False, color)
    return p


def bullet(text, size=12):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = 1.5
    pf.left_indent = Pt(24)
    pf.first_line_indent = Pt(-12)
    pf.space_after = Pt(3)
    run = p.add_run("· " + text)
    cn_font(run, BODY_CN, size)
    return p


def code(text):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = 1.15
    pf.left_indent = Cm(0.6)
    pf.space_before = Pt(3)
    pf.space_after = Pt(6)
    run = p.add_run(text)
    cn_font(run, "Consolas", 9.5, False, RGBColor(0x24, 0x3B, 0x33))
    return p


def h1(text):
    p = doc.add_heading(level=1)
    p.paragraph_format.page_break_before = True
    run = p.add_run(text)
    cn_font(run, HEAD_CN, 16, True, INK)
    return p


def h2(text):
    p = doc.add_heading(level=2)
    run = p.add_run(text)
    cn_font(run, HEAD_CN, 13.5, True, INK)
    return p


def h3(text):
    p = doc.add_heading(level=3)
    run = p.add_run(text)
    cn_font(run, HEAD_CN, 12, True, RGBColor(0x2B, 0x3A, 0x34))
    return p


def shade(cell, hex_fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_fill)
    tc_pr.append(shd)


def repeat_header(row):
    tr_pr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader")
    el.set(qn("w:val"), "true")
    tr_pr.append(el)


def set_table_widths(t, widths):
    """把列宽写死：tblLayout=fixed + tblW + gridCol + 每个单元格宽度。

    python-docx 只设 cell.width 时，Word/LibreOffice 仍会按内容自动分配，
    表格会变成等宽两列——必须同时改 tblGrid 并锁定布局。
    """
    tbl = t._tbl
    tbl_pr = tbl.tblPr
    total = sum(widths)
    for el in tbl_pr.findall(qn("w:tblW")):
        tbl_pr.remove(el)
    tbl_w = OxmlElement("w:tblW")
    tbl_w.set(qn("w:w"), str(int(total / 2.54 * 1440)))
    tbl_w.set(qn("w:type"), "dxa")
    tbl_pr.append(tbl_w)
    layout = OxmlElement("w:tblLayout")
    layout.set(qn("w:type"), "fixed")
    tbl_pr.append(layout)
    grid = tbl.find(qn("w:tblGrid"))
    if grid is not None:
        for col, w in zip(grid.findall(qn("w:gridCol")), widths):
            col.set(qn("w:w"), str(int(w / 2.54 * 1440)))
    for i, w in enumerate(widths):
        t.columns[i].width = Cm(w)
        for cell in t.columns[i].cells:
            cell.width = Cm(w)


def table(headers, rows, widths=None, size=10.5, caption=None, align_right=()):
    if caption:
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(6)
        p.paragraph_format.space_after = Pt(2)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        cn_font(p.add_run(caption), HEAD_CN, 9.5, False, MUTED)
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    hdr = t.rows[0]
    repeat_header(hdr)
    for i, text in enumerate(headers):
        cell = hdr.cells[i]
        cell.text = ""
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(2)
        p.paragraph_format.space_after = Pt(2)
        cn_font(p.add_run(str(text)), HEAD_CN, size, True, RGBColor(0x1B, 0x3A, 0x2C))
        shade(cell, HEAD_FILL)
    for row in rows:
        cells = t.add_row().cells
        for i, text in enumerate(row):
            cells[i].text = ""
            cells[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_before = Pt(1)
            p.paragraph_format.space_after = Pt(1)
            if i in align_right:
                p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
            cn_font(p.add_run(str(text)), BODY_CN, size)
    if widths:
        set_table_widths(t, widths)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def caption(text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(10)
    cn_font(p.add_run(text), HEAD_CN, 9.5, False, MUTED)


def picture(name, width_cm=6.6, cap=None):
    path = ROOT / "docs" / "verify" / name
    if not path.exists():
        return
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.keep_with_next = True
    p.add_run().add_picture(str(path), width=Cm(width_cm))
    if cap:
        caption(cap)


def compose_pair(left_name, right_name, out_name, gap=60, bg=(255, 255, 255)):
    """把两张竖版截图横向拼成一张，避免用表格排版（表格边框在不同渲染器里表现不一致）。"""
    from PIL import Image

    out = ROOT / "docs" / "verify" / out_name
    left = ROOT / "docs" / "verify" / left_name
    right = ROOT / "docs" / "verify" / right_name
    if out.exists() or not left.exists() or not right.exists():
        return
    a, b = Image.open(left).convert("RGB"), Image.open(right).convert("RGB")
    h = max(a.height, b.height)
    canvas = Image.new("RGB", (a.width + gap + b.width, h), bg)
    canvas.paste(a, (0, 0))
    canvas.paste(b, (a.width + gap, 0))
    canvas.save(out, quality=92)


def image_row(items):
    """并排两图：拼成一张再插入，版本兼容性最好。"""
    left = ROOT / "docs" / "verify" / items[0][0]
    right = ROOT / "docs" / "verify" / items[1][0]
    if not left.exists() or not right.exists():
        return
    compose_pair(items[0][0], items[1][0], "ai-pair.png")
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(2)
    p.add_run().add_picture(str(ROOT / "docs" / "verify" / "ai-pair.png"), width=Cm(14.2))
    caption(items[0][1] + "；右：" + items[1][1])


def add_page_field(paragraph):
    run = paragraph.add_run()
    fld_begin = OxmlElement("w:fldChar")
    fld_begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = " PAGE "
    fld_sep = OxmlElement("w:fldChar")
    fld_sep.set(qn("w:fldCharType"), "separate")
    txt = OxmlElement("w:t")
    txt.text = "1"
    fld_end = OxmlElement("w:fldChar")
    fld_end.set(qn("w:fldCharType"), "end")
    run._r.append(fld_begin)
    run._r.append(instr)
    run._r.append(fld_sep)
    run._r.append(txt)
    run._r.append(fld_end)


def quote(text):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = 1.4
    pf.left_indent = Cm(0.8)
    pf.right_indent = Cm(0.5)
    pf.space_before = Pt(4)
    pf.space_after = Pt(8)
    cn_font(p.add_run(text), BODY_CN, 10.5, False, RGBColor(0x3F, 0x4C, 0x47))
    pPr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), "12")
    left.set(qn("w:space"), "8")
    left.set(qn("w:color"), "2F9E68")
    borders.append(left)
    pPr.append(borders)


# ---------------------------------------------------------------- 文档骨架
doc = Document()

sec = doc.sections[0]
sec.page_width = Cm(21)
sec.page_height = Cm(29.7)
sec.top_margin = Cm(2.54)
sec.bottom_margin = Cm(2.54)
sec.left_margin = Cm(3.0)
sec.right_margin = Cm(3.0)

normal = doc.styles["Normal"]
normal.font.name = WEST
normal.font.size = Pt(12)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_CN)

# 页眉页脚
# 封面不要页眉页脚，从第二页开始才是正文版式
sec.different_first_page_header_footer = True
hdr_p = sec.header.paragraphs[0]
hdr_p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
cn_font(hdr_p.add_run("碳足迹 · 技术文档  v1.0"), BODY_CN, 9, False, MUTED)
ftr_p = sec.footer.paragraphs[0]
ftr_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(ftr_p.add_run("第 "), BODY_CN, 9, False, MUTED)
add_page_field(ftr_p)
cn_font(ftr_p.add_run(" 页"), BODY_CN, 9, False, MUTED)

doc.core_properties.title = "碳足迹 · 全民绿色生活碳积分与减排指南 技术文档"
doc.core_properties.subject = "HarmonyOS / ArkTS 应用技术设计说明书"
doc.core_properties.author = "项目组"

# ---------------------------------------------------------------- 封面
p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(150)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("碳足迹"), HEAD_CN, 34, True, GREEN)

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("全民绿色生活碳积分与减排指南"), HEAD_CN, 20, True, INK)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(10)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("技 术 文 档"), HEAD_CN, 26, True, INK)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(6)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("基于 HarmonyOS / ArkTS（Stage 模型）"), BODY_CN, 12, False, MUTED)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(90)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("版本 1.0    2026 年 11 月"), BODY_CN, 12, False, MUTED)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(4)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
cn_font(p.add_run("第三届河南省高等学校信息技术应用创新大赛（开源鸿蒙）· 赛题二"), BODY_CN, 10.5, False, MUTED)

# ---------------------------------------------------------------- 文档信息
h1("文档信息")
table(
    ["项目", "内容"],
    [
        ["文档名称", "《碳足迹 · 全民绿色生活碳积分与减排指南》技术文档"],
        ["文档版本", "v1.0"],
        ["对应应用版本", "1.0.0（versionCode 1000000）"],
        ["适用平台", "HarmonyOS 6.0.1(21)，phone / tablet"],
        ["编写日期", "2026 年 11 月 1 日"],
        ["文档状态", "已随代码同步：构建、静态检查、逻辑回归、模拟器走查均已执行"],
    ],
    widths=[3.4, 11.6],
)

h2("修订记录")
table(
    ["版本", "日期", "修订内容"],
    [
        ["v0.9", "2026-10-28", "初稿：功能对照、数据模型、构建说明"],
        ["v1.0", "2026-11-01", "补充图片识别自动记账（两值协议）、实况窗/灵动岛、"
                                "自动记账策略、44 项逻辑回归与本次走查结论"],
    ],
    widths=[2.0, 3.0, 10.0],
)

h2("阅读指引")
body("本文档面向三类读者：评审与验收人员可先读第 2、5、10 章；开发人员重点看第 3、4、6 章；"
     "部署与演示人员看第 9 章。文中所有数值（行为条数、积分公式、阈值、接口名）均从仓库源码"
     "或数据库脚本中直接提取，与代码保持一致。")

# ---------------------------------------------------------------- 目录
h1("目 录")
toc = [
    ("1  引言", "编写目的、项目背景、术语、参考资料"),
    ("2  系统概述", "产品定位、功能清单、运行环境、设计原则"),
    ("3  总体设计", "分层架构、模块划分、状态管理、关键设计决策"),
    ("4  数据设计", "本地存储、核心数据结构、云端表与接口、一致性"),
    ("5  功能设计", "五个主页面 + 账号、家庭、碳普惠、通知、图片识别"),
    ("6  关键算法", "积分公式、统计口径、去重指纹、策略闸门、提示词与解析"),
    ("7  界面设计", "信息架构、识别交互状态机、主题与可读性"),
    ("8  安全与隐私", "权限、云端安全模型、凭据、图片数据流"),
    ("9  构建与部署", "环境、构建命令、签名、安装、辅助脚本"),
    ("10  测试与验证", "构建、静态检查、逻辑回归、模拟器走查、缺陷记录"),
    ("11  已知限制与规划", "当前边界与后续可做项"),
    ("附录 A", "低碳行为与碳因子清单（33 条）"),
    ("附录 B", "科普文章清单（10 篇）"),
]
table(["章节", "主要内容"], toc, widths=[4.2, 10.8])

# ---------------------------------------------------------------- 1 引言
h1("1  引言")

h2("1.1  编写目的")
body("本文档描述「碳足迹 · 全民绿色生活碳积分与减排指南」的技术设计，说明系统由哪些模块组成、"
     "数据如何流动、关键业务规则如何计算，以及如何构建、签名、部署与验证。文档面向赛题评审、"
     "后续维护者与二次开发者，力求做到“看完能跑起来、改动能定位到文件”。")

h2("1.2  项目背景")
body("项目对应第三届河南省高等学校信息技术应用创新大赛（开源鸿蒙）赛题二：以 HarmonyOS 为平台，"
     "实现低碳行为核算、数据可视化、碳积分激励、双碳科普与本地数据管理五项主要功能，并鼓励在"
     "端侧 AI、云端同步、社交化等方向做拓展。")
body("应用以“个人碳账本”为核心：用户把日常低碳行为记进账本，系统按内置碳排放因子换算出减排量，"
     "折算成碳积分，再用等级、徽章、证书、每日任务与家庭榜单形成正反馈。在此基础上，"
     "本项目接入了本地部署的视觉模型（千问 VL 系列，OpenAI 兼容接口），实现"
     "“选一张照片 → 模型判定 → 自动记账加分”的零点击录入。")

h2("1.3  术语与缩写")
table(
    ["术语", "说明"],
    [
        ["碳排放因子", "单位活动量对应的温室气体排放量，本系统统一为 kgCO₂e"],
        ["减排量", "行为数量 × 排放因子，单位 kgCO₂e"],
        ["碳积分", "本系统内的激励单位，由基础分与减排量折算而来"],
        ["快照（snapshot）", "服务端按账号返回的全量数据包：用户、记录、徽章、领奖、证书"],
        ["RPC", "Supabase 的数据库函数调用，客户端只被授权调用函数，不能直接读写表"],
        ["实况窗", "HarmonyOS 通知体系中的常驻卡片，可显示进度并在状态栏呈现胶囊（俗称灵动岛）"],
        ["两值协议", "本项目与视觉模型的约定：只返回 hasLowCarbon 与 activityId 两个字段"],
        ["dHash", "差异哈希，将图片缩为 9×8 灰度后按相邻像素比较得到 64 位指纹"],
    ],
    widths=[3.4, 11.6],
)

h2("1.4  参考资料")
for t in [
    "《中国产品全生命周期温室气体排放系数集》及生态环境部公开指南（排放因子取值口径）",
    "IPCC AR6 相关排放因子说明",
    "HarmonyOS 开发者文档：ArkTS / ArkUI、Image Kit、Notification Kit、Background Tasks Kit",
    "Supabase 文档：PostgREST RPC、行级安全（RLS）",
    "仓库内 README.md、supabase/schema.sql、tools/verify-logic.mjs",
]:
    bullet(t)

# ---------------------------------------------------------------- 2 系统概述
h1("2  系统概述")

h2("2.1  产品定位")
body("一款可离线使用的个人碳账本应用：不登录也能浏览数据与科普，登录后叠加云端同步、家庭减碳、"
     "城市碳普惠与电子证书。核心卖点是“记一笔足够快”——既能手动三步记账，也能用一张照片"
     "由本地视觉模型自动判定并直接入账。")

h2("2.2  功能清单")
table(
    ["序号", "功能", "实现位置", "说明"],
    [
        ["1", "低碳行为核算", "RecordTab + CarbonData", f"{len(ACTS)} 条行为、{len(CATS)} 大类，内置碳因子，自动算减排量与积分"],
        ["2", "数据可视化看板", "ChartTab + Charts", "日/周/月/年折线、分类柱状、占比环形、行为 TOP5、历史筛选"],
        ["3", "碳积分激励体系", "MineTab + CarbonStore", "每日任务、18 枚徽章、10 级成长、证书"],
        ["4", "双碳科普专栏", "LearnTab + ArticleData", f"{len(ARTICLES)} 篇图文、3 个栏目、关键词搜索、划重点"],
        ["5", "本地数据管理", "StorageService + FileService", "preferences 持久化、CSV 导出、JSON 备份与恢复"],
        ["6", "账号与云同步", "CloudAccount + Supabase", "自建注册登录、会话 token、全量快照拉取"],
        ["7", "图片识别自动记账", "AIRecognitionService + AutoRecordService", "本地视觉模型判定，命中直接入账，零点击"],
        ["8", "通知 / 实况窗", "NotificationService", "状态栏常驻卡片 + 胶囊、10 分钟周期推送、后台兜底"],
        ["9", "家庭减碳", "FamilyService", "组建/加入家庭、邀请码、成员减排汇总"],
        ["10", "城市碳普惠", "CityService + CarbonBankService", "绑定城市账户、积分转入转出、权益兑换（含模拟模式）"],
    ],
    widths=[1.2, 3.6, 4.6, 6.2],
)

h2("2.3  运行环境")
table(
    ["项目", "配置"],
    [
        ["开发工具", "DevEco Studio 6.0.1"],
        ["SDK", "HarmonyOS 6.0.1(21)，compatibleSdkVersion 6.0.1(21)"],
        ["语言 / 模型", "ArkTS，Stage 模型，ArkUI 声明式"],
        ["目标设备", "phone / tablet"],
        ["第三方依赖", "无。仅使用系统 Kit：ArkData、CoreFileKit、ImageKit、MediaLibraryKit、"
                       "NetworkKit、NotificationKit、BackgroundTasksKit、ArkUI、ArkTS"],
        ["权限", "ohos.permission.INTERNET（登录、云同步、模型推理）"],
        ["本地存储", "preferences（键值）+ 应用沙箱 filesDir（备份/报表）"],
    ],
    widths=[3.4, 11.6],
)

h2("2.4  设计原则")
for t in [
    "先正确、再好看：积分与减排量必须账实一致，宁可少加分也不给虚假积分。",
    "离线优先：不登录也是完整单机版，云端只做增强，任何网络失败都不能让核心功能不可用。",
    "诚实交互：界面文案必须与实际能力一致，例如“AI 未启用”时不能承诺自动记账。",
    "不引第三方库：图表、表单、弹层全部自绘或使用系统组件，保证零依赖与可审计。",
    "可回归：把纯业务逻辑抽成不依赖 UI 的函数，用 Node 脚本直接转译真实源码做断言。",
]:
    bullet(t)

# ---------------------------------------------------------------- 3 总体设计
h1("3  总体设计")

h2("3.1  分层架构")
body("应用采用“页面 → 视图 → 业务中心 → 服务 → 数据模型”的五层结构，依赖方向单一，"
     "上层可以调用下层，下层不反向依赖 UI。")
table(
    ["层次", "组成", "职责"],
    [
        ["页面层", "pages/Index、Login、CityCarbon", "承载 5 个 Tab、登录页与碳普惠页，负责生命周期与跳转"],
        ["视图层", "view/*Tab、components/Charts", "页面级组件与自绘图表，只做展示与交互编排"],
        ["业务中心", "viewmodel/CarbonStore", "唯一的数据真相来源：记录、积分、统计、任务、徽章、备份"],
        ["服务层", "service/*", "持久化、文件、网络、账号、家庭、城市、通知、AI 识别与自动记账"],
        ["数据模型", "model/*", "纯数据类与内置数据表（碳因子、徽章、任务、文章）"],
    ],
    widths=[2.4, 5.0, 8.2],
)
body("这种划分的直接收益是：页面里不出现业务公式，服务里不出现 UI 代码，"
     "因此同一套规则既能在端上运行，也能被 Node 回归脚本直接转译执行。")

h2("3.2  模块划分")
body(f"工程共 {len(FILES)} 个 .ets 源文件，约 {TOTAL_LINES / 10000:.2f} 万行（含空行与注释，"
     f"不含构建产物与依赖）。核心模块如下表（完整清单见工程目录）：")
rows = []
for path, lines in FILES[:22]:
    rows.append([path, f"{lines}", RESP.get(path, "—")])
table(["文件", "行数", "职责"], rows, widths=[6.2, 1.4, 8.0], size=9.5, align_right=(1,))
body(f"其余 {max(0, len(FILES) - 22)} 个文件为较小的服务/工具/扩展，职责见源码头部注释。", indent=True)

h2("3.3  状态管理与刷新机制")
body("ArkUI 的状态传递有两个坑：@StorageLink 只能感知首层赋值，对象内部变化不会触发刷新；"
     "跨页面直接传对象容易出现“记完账首页不刷新”。本项目采用“版本号 + 令牌”的间接刷新：")
for t in [
    "数据变更后调用 bumpDataVersion()，把 AppStorage 里的 carbonVersion 自增。",
    "主框架 Index 通过 @StorageLink + @Watch 监听版本号，收到变化后把 homeToken / recordToken / "
    "chartToken / mineToken 各自自增。",
    "各 Tab 用 @Prop @Watch('onTokenChange') 接收令牌，值变化即重新取数；切换 Tab 时也主动自增一次。",
    "派生数据（汇总、月度复盘、倒序列表）按版本缓存，写操作统一 invalidate()，避免一次渲染扫十几遍全量记录。",
]:
    bullet(t)
quote("经验：凡是“点了没反应”的问题，先检查 ForEach 的 key 是否包含界面依赖的状态；"
      "ArkUI 会复用旧节点，key 不变则子构建不会重新执行。项目里分类高亮、历史筛选、"
      "任务进度、识别候选的“已记账”标记都吃过这个亏，现已把状态并入 key。")

h2("3.4  关键设计决策")
table(
    ["决策", "选择", "理由"],
    [
        ["图表实现", "Canvas 自绘（LinePainter / BarPainter / RingPainter）", "零依赖、离线可用；绘制逻辑抽成类，便于在 @Builder 中复用"],
        ["账号体系", "自建 Supabase + RPC", "赛题要求可离线；又需要跨设备同步，自建后端可控且成本低"],
        ["积分归属", "账号资产，未登录不产生记录", "避免把积分记到“没有归属”的本机，换账号时串号"],
        ["图片识别", "本地视觉模型 + 两值协议", "模型只判“有没有 / 是哪条”，名称与分值本地查表，减少模型出错面"],
        ["端侧色彩识别", "已删除", "只是没接模型时的演示占位，按颜色猜行为不可靠，不能自动记账"],
        ["实况窗", "系统 Live View + WorkScheduler", "状态栏常驻 + 进程退出后仍能刷新，无需常驻后台服务"],
    ],
    widths=[3.0, 5.4, 7.2],
)

# ---------------------------------------------------------------- 4 数据设计
h1("4  数据设计")

h2("4.1  本地存储")
body("本地持久化基于 preferences，统一使用名为 carbon_store 的存储实例，共 9 个键：")
table(
    ["键", "内容", "写入方"],
    [
        ["records_json", "全部碳记录数组（CarbonRecord[]）", "CarbonStore"],
        ["meta_json", "账户元信息（昵称、月目标、已兑换、领奖 key、消费积分、证书）", "CarbonStore"],
        ["session_token", "云端会话 token", "AuthService"],
        ["city_base_url", "城市碳普惠平台地址", "CityService"],
        ["city_token", "城市平台下发的 token", "CityService"],
        ["city_account", "城市账户快照（编号/积分/绑定时间）", "CityService"],
        ["family_json", "家庭状态（成员、邀请码）", "FamilyService"],
        ["ai_config_json", "视觉模型配置（地址、模型名、Key、开关）", "AIRecognitionService"],
        ["auto_record_ledger", "自动记账台账（图片指纹、当日各行为次数）", "AutoRecordService"],
    ],
    widths=[4.2, 8.6, 2.8],
)
body("设计要点：记录与账户元信息始终落本地，未登录时完全离线可用；登录后由云端快照整体覆盖，"
     "保证换设备能拉回账号数据。自动记账台账刻意与业务记录分离——它只是“防重复/防刷分”的辅助状态，"
     "跨设备同步没有意义。")

h2("4.2  核心数据结构")
h3("4.2.1  碳记录 CarbonRecord")
table(
    ["字段", "类型", "说明"],
    [
        ["id", "string", "记录唯一 id（客户端生成）"],
        ["activityId", "string", "行为 id，对应 CarbonData 中的定义"],
        ["activityName / categoryId / unit", "string", "冗余存储，避免行为库调整后历史记录显示错乱"],
        ["qty", "number", "数量（次 / km / kg / 个 …）"],
        ["factor", "number", "单位减排因子（kgCO₂e）"],
        ["reduction", "number", "减排量 = qty × factor，保留 3 位小数"],
        ["point", "number", "本条获得的积分"],
        ["date", "string", "业务日期 yyyy-MM-dd（统计口径以此为准）"],
        ["time", "number", "写入时间戳；补记时平移到业务日期"],
        ["note", "string", "备注（手动备注或“AI识别自动记账：行为名”）"],
    ],
    widths=[4.4, 2.4, 8.8],
)
h3("4.2.2  账户元信息 AccountMeta")
table(
    ["字段", "类型", "说明"],
    [
        ["exchanged", "string[]", "已兑换徽章/证书 id"],
        ["spentPoint", "number", "已消费积分；领取任务奖励以负数抵消，净额 = 累计获得 − spentPoint"],
        ["claimedTasks", "string[]", "已领奖的每日任务 key：yyyy-MM-dd#taskId（只保留当天）"],
        ["nickName", "string", "昵称"],
        ["monthGoal", "number", "月减排目标（kg）"],
        ["certificates", "CertificateIssue[]", "已颁发证书：badgeId + 证书编号 + 颁发时间"],
    ],
    widths=[4.0, 4.0, 7.6],
)

h2("4.3  云端表结构")
body("云端为 Supabase（PostgreSQL）。业务表全部开启 RLS 且不配置任何 policy，anon key 只能调用"
     "显式授权的 RPC，函数内部再用会话 token 校验用户身份，因此密钥可以安全打进客户端。")
table(
    ["表", "用途", "关键字段"],
    [
        ["users", "账号", "id、username、password_hash、nickname、month_goal、spent_point"],
        ["carbon_records", "碳记录", "id、user_id、activity_id、qty、reduction、point、record_date"],
        ["user_badges", "徽章/证书兑换记录", "user_id、badge_id、kind、cost、obtained_at"],
        ["task_claims", "每日任务领奖记录", "user_id、claim_date、task_id、reward"],
        ["certificates", "电子证书", "user_id、cert_no、title、level、issued_at"],
        ["sessions", "登录会话", "token、user_id、created_at"],
    ],
    widths=[4.0, 5.0, 6.6],
)

h2("4.4  云端接口")
body("客户端只调用 RPC。schema.sql 中已定义的接口如下：")
table(
    ["函数", "入参", "作用"],
    [
        ["register_user", "username, password, nickname", "注册并直接返回会话"],
        ["login_user", "username, password", "登录，返回 token 与用户信息"],
        ["logout_user", "token", "销毁会话"],
        ["get_snapshot", "token", "返回该账号全量快照（用户/记录/徽章/领奖/证书）"],
        ["add_record", "token, record(jsonb)", "新增一条记录，按 (user_id, id) 幂等"],
        ["delete_record", "token, record_id", "删除记录"],
        ["claim_task", "token, task_id, claim_date, reward", "领取每日任务奖励，返回最新消费积分"],
        ["redeem_badge", "token, badge_id, cost", "兑换徽章/证书，返回最新消费积分"],
        ["update_profile", "token, nickname, month_goal", "保存资料"],
    ],
    widths=[3.6, 6.2, 5.8],
)
body("另有 3 个接口在客户端 CloudAccount 中被调用（revoke_claim 任务回滚、clear_records 清空数据、"
     "replace_snapshot 备份恢复），但当前仓库的 schema.sql 尚未收录，属已知不同步项，见第 11 章。")

h2("4.5  数据一致性")
for t in [
    "写记录：登录后先 RPC 成功、再写本地；网络失败时本地不会多出一条服务端不存在的记录。",
    "删记录：先删服务端，再删本地；若因此导致当日任务不再达标，逐个调用回滚接口，保证积分账实一致。",
    "领奖/兑换：以服务端返回的 spentPoint 为准回写本地，避免本地与服务端各记一套账。",
    "备份恢复：把备份整体推给 replace_snapshot，再重新拉取快照，不直接改本地。",
    "自动记账：云端失败时退回本地写入，并在界面标注“已记到本机，云端未同步”，不让云端抖动中断记账。",
]:
    bullet(t)

# ---------------------------------------------------------------- 5 功能设计
h1("5  功能设计")

h2("5.1  记一笔（RecordTab）")
body("页面自上而下是：分类横条（6 类）→ 图片识别入口 → 当前分类下的行为列表。"
     "点击某条行为会在该行下方展开录入区，包含数量加减、快捷倍数、备注、记账日期与试算面板；"
     "试算面板实时显示“预计减排 / 预计积分”，点「一键记录」才真正落库。")
for t in [
    "数量会被 clamp 到 [1, maxQty]；快捷倍数只渲染不超过上限的档位（如高铁上限 4 次时没有 ×5/×10）。",
    "记账日期可选历史日期（补记），上限为今天；补记时把 time 平移到那一天，保证列表与统计一致。",
    "未登录点保存会先走登录引导（AccountGate），因为积分属于账号资产。",
    "图片识别成功时会自动记账，不再要求用户点候选、点保存（详见 5.11）。",
]:
    bullet(t)

h2("5.2  碳账本（HomeTab）")
body("首页把“今天的状态”放在最前面：记录节奏点阵（近 7 天每天记了几笔）、累计减排、"
     "今日/本周/连续/积分四格统计，随后是本月目标、今日任务、记录日历、减排来源、最近记录与等级。"
     "所有数字来自 CarbonStore 的汇总缓存，数据变更后统一失效重算。")

h2("5.3  数据看板（ChartTab）")
body("看板提供四维趋势（日/周/月/年）与三种区间筛选（全部/本月/本周），并用柱状图做分类对比、"
     "环形图做占比、列表做行为 TOP5 与历史记录。图表全部 Canvas 自绘：")
for t in [
    "折线图：渐变面积 + 数据点 + 峰值标注 + X 轴标签抽稀。",
    "柱状图：圆角柱 + 底槽 + 数值标注。",
    "环形图：分段 + 中心文字，无数据时显示占位。",
]:
    bullet(t)
body("绘制逻辑封装为 LinePainter / BarPainter / RingPainter，页面只负责在 @Watch、"
     "onVisibleAreaChange 与延迟重绘里调用 repaint，避免切换区间后图停在旧数据。")

h2("5.4  碳积分体系（MineTab + CarbonStore）")
h3("5.4.1  每日任务")
body("6 个任务分别对应 6 个分类，当天记录达到数量即完成，领取后以“负消费”计入账户；"
     "删除记录导致不再达标时会自动回收奖励（见 6.3）。")
h3("5.4.2  成就徽章与兑换")
body("成就徽章按记录数、累计减排、连续天数、分类覆盖、夜间记录等条件自动判定，共 10 枚；"
     "可兑换项共 8 个（3 枚纪念徽章 + 5 张证书），消耗积分。证书会生成编号（CF-yyyyMMdd-6位）"
     "与颁发时间，可在“个人荣誉”中放大展示。")
h3("5.4.3  等级成长")
body("等级由累计减排量决定，共 10 级（阈值 0 / 1 / 5 / 15 / 30 / 60 / 120 / 250 / 500 / 1000 kg），"
     "阈值与称号收敛在 CarbonData，UI 只读 LevelInfo，避免两处各维护一份。")

h2("5.5  双碳科普（LearnTab）")
body(f"共 {len(ARTICLES)} 篇文章，分政策 / 知识 / 技巧 3 个栏目，支持关键词搜索与详情页；"
     "详情页包含“划重点”区块，长文分段排版，返回时可关闭并自动收起键盘。")

h2("5.6  数据管理")
table(
    ["能力", "实现", "产物"],
    [
        ["CSV 报表导出", "CarbonStore.buildCsvReport + FileService", "carbon_report.csv（RFC4180 转义）"],
        ["JSON 备份", "buildBackupPayload → 沙箱文件", "carbon_backup.json（含记录、徽章、任务、家庭）"],
        ["备份恢复", "restoreFromPayload / replace_snapshot", "版本校验 + 字段归一化 + 重复 id 重新生成"],
        ["清空数据", "clearBusinessData 或云端 clear_records", "保留昵称与月目标"],
    ],
    widths=[3.2, 7.2, 5.2],
)

h2("5.7  账号与云同步")
body("账号体系自建在 Supabase 上：注册/登录拿到 token，登录成功后先清空本机旧账号数据，"
     "再拉取快照覆盖；退出登录时销毁服务端会话并回到未登录模板。token 失效（unauthorized）时"
     "自动清会话并提示重新登录，避免界面停在半登录状态。")

h2("5.8  家庭减碳")
body("家庭支持创建、邀请、加入、退出与解散，成员减排量汇总成家庭碳足迹。"
     "当前成员目录来自本地演示数据（DirectoryUser），用于演示“搜索同学 → 邀请 → 家庭榜单”的完整链路，"
     "不涉及真实社交关系。")

h2("5.9  城市碳普惠")
body("城市碳普惠按“个人积分 ⇄ 城市账户”设计：先在 Supabase 记账扣分，再调用平台接口加分；"
     "反向操作则先平台扣分、成功后再回滚本地账目，避免出现“平台已加分、本地没扣”的双花。"
     "平台地址可配置，默认指向本地模拟服务（http://192.168.0.161:8080），未接入真实城市平台时"
     "由 CarbonBankService 在本地模拟权益兑换。")

h2("5.10  通知、实况窗与灵动岛")
body("实况窗把“今日减排 / 本月目标进度”做成状态栏常驻卡片，并在状态栏左侧呈现胶囊（灵动岛）。"
     "刷新有三条链路：")
for t in [
    "应用启动：申请通知权限 → 发实况窗 + 第一条个性化任务 → 启动 10 分钟定时器。",
    "进程存活：setInterval 每 10 分钟刷新实况窗并推送一条新任务（旧任务自动 cancel，避免堆叠）。",
    "进程退出：WorkScheduler 每 20 分钟拉起 CarbonWorkScheduler 扩展，重新加载本地数据后推送。",
]:
    bullet(t)
body("权限是硬前提：通知被关闭时实况窗与胶囊都不会显示。由于系统在用户拒绝后不再弹授权框"
     "（requestEnableNotification 返回 1600004），应用在“我的 → 状态栏实况窗”提供了直达系统"
     "通知设置页的入口，并在面板里说明依赖关系。")

h2("5.11  图片识别自动记账")
h3("5.11.1  设计目标")
body("把“拍照记账”从三次点击（选图、选候选、保存）压缩到一次点击（选图）。判定与加分全部由"
     "本地视觉模型 + 本地规则完成，用户只负责提供照片。")
h3("5.11.2  处理链路")
table(
    ["步骤", "模块", "动作"],
    [
        ["1", "RecordTab", "校验登录 → 拉起系统图库选图"],
        ["2", "ImageRecognitionService", "读取配置；未配置模型直接报错并引导设置"],
        ["3", "AIRecognitionService", "图片压到长边 1024（超限降 640）→ JPEG base64 → 调 /chat/completions"],
        ["4", "AIRecognitionService", "解析 JSON：hasLowCarbon + activityId；兼容思考文本与截断"],
        ["5", "ImageRecognitionService", "按 activityId 从 CarbonData 查名称、类别、图标、基础分"],
        ["6", "AutoRecordService", "算图片指纹 → 读台账 → 策略判定 → 本地/云端落库 → 回写台账"],
        ["7", "RecordTab", "面板顶部给出结论（绿=已记账 / 黄=原因），已入账行标“已记账”"],
    ],
    widths=[1.2, 4.6, 9.2],
)
h3("5.11.3  与模型的约定")
body("提示词要求模型只输出一个 JSON 对象，且只有两个字段：")
code('{"hasLowCarbon":true,"activityId":"travel_bike"}\n{"hasLowCarbon":false,"activityId":""}')
body("清单直接遍历内置的 33 条行为生成（含 id、名称、类别），因此提示词与行为库永远一致。"
     "类别、单位、减排因子、积分全部由本地查表，模型不复述、不计算——既省 token，"
     "也避免它把行为名写错或把分数算错。")
h3("5.11.4  自动记账规则")
for t in [
    "数量固定记 1 个计量单位：模型只判“有没有这件事”，不判数量。",
    "积分与手动记账同源：积分 = 基础分 + 减排量 × 2（最低 1 分），基础分与因子来自 CarbonData。",
    "同图去重：9×8 灰度 dHash 指纹，24 小时内同一张图只记一次（改系统时间也绕不过，用绝对时间差）。",
    "单行为日上限：同一行为每天最多自动记 3 次，防连拍同类照片刷分。",
    "备注可追溯：统一写为“AI识别自动记账：行为名”，历史与 CSV 报表里一眼可辨。",
]:
    bullet(t)
h3("5.11.5  失败与兜底")
body("模型没看出行为、格式不符、连不上、超时、同图已记、达到上限，都会在面板顶部用黄色横幅"
     "写明原因；候选仍可手动“补记”，并保留“重试这张 / 换张照片”入口。"
     "端侧色彩识别这条兜底已整体删除：它只能说明画面颜色像不像，无法构成行为证据。")
h3("5.11.6  界面")
image_row([
    ("ai-auto-record.jpeg", "图 5-1  识别完成：绿色横幅给出记账结论，候选行标“已记账”"),
    ("ai-settings.jpeg", "AI 识别设置：地址、模型名、Key 与规则说明"),
])

# ---------------------------------------------------------------- 6 关键算法
h1("6  关键算法与业务规则")

h2("6.1  减排量与积分")
body("所有行为的减排量按“数量 × 单位因子”计算，保留 3 位小数；积分按下式折算，最低 1 分：")
code("reduction = round(qty × factor, 3)\npoint     = max(1, round(basePoint + reduction × 2))")
body("这样高减排行为得分更高，避免“只刷简单行为”。积分与减排量都由同一条记录派生，"
     "因此统计、等级、徽章、CSV 报表四处口径天然一致。")

h2("6.2  统计口径与连续打卡")
body("记录的“业务日期”是 date 字段，不是写入时间 time。今日/本周/本月/年度、筛选、复盘全部按 date 聚合，"
     "补记、导入备份、跨零点都不会出现“列表里有、统计里没有”的错位。")
body("连续打卡：从今天往前数，若今天还没记录则从昨天起算（当天没来及记不算断）；"
     "周起点按周一计算，用日期运算而非固定毫秒差，避免夏令时偏移。")

h2("6.3  任务奖励回收")
body("每日任务的领奖记录以 yyyy-MM-dd#taskId 存入 claimedTasks。删除记录后重新统计当日各分类数量，"
     "若某任务已不达标，则把奖励退回（spentPoint 对称加回）并移除 key，保证“积分账实一致”。"
     "读取、领取、回滚三处都会清理非今日 key，避免数组无限增长。")

h2("6.4  图片指纹（dHash）")
body("把图片解码为 9×8 的 RGBA 缩略图，转灰度后逐行比较相邻像素（左 > 右 记 1，否则 0），"
     "得到 64 位二进制串，再折叠成 16 位十六进制。实现要点：")
for t in [
    "解码后校验尺寸必须为 9×8：少数解码路径会忽略 desiredSize，用原图左上角算指纹会把两张不同照片判成同一张。",
    "算不出指纹时不做同图去重，但每日上限仍然生效，功能不会因此中断。",
    "比较时用绝对时间差，用户把系统时间往回调同样落在去重窗口内。",
    "指纹只在本机参与去重，不上传、不写进任何业务记录。",
]:
    bullet(t)

h2("6.5  自动记账策略")
body("策略层是纯函数（AutoRecordPolicy.ets），不碰 UI、网络与存储，因此能被 Node 脚本直接验证。"
     "输入是候选行为、图片指纹与台账上下文，输出“接受列表 + 跳过原因”：")
table(
    ["闸门", "规则", "命中后的表现"],
    [
        ["同图去重", "指纹在 24 小时窗口内出现过", "整轮不记，提示“这张照片 24 小时内已经记过账”"],
        ["单行为日上限", "该行为今日已自动记满 3 次", "跳过该行为，提示已达上限"],
        ["同轮去重", "同一行为在一次结果里重复出现", "只保留一条"],
    ],
    widths=[3.0, 6.4, 5.6],
)

h2("6.6  提示词协议")
body("提示词由四部分组成：角色与任务、33 条行为清单、5 条判定规则、两行输出示例。"
     "严格模式下追加“只允许输出 JSON、不要 confidence/evidence/activities”的约束，用于格式重试。"
     "关键约束：")
for t in [
    "只看“是否发生”，不猜数量、不猜分数；多个行为只选最明确的一条。",
    "activityId 必须原样取自清单，不允许自造、翻译或写中文名。",
    "看不到任何行为时 hasLowCarbon=false、activityId 为空串。",
]:
    bullet(t)

h2("6.7  模型输出的解析与容错")
body("小模型经常“不听话”，解析按四级兜底：")
table(
    ["层级", "处理", "适用情况"],
    [
        ["① 直接解析", "去掉 ``` 围栏与前后废话，截取首个 { 到末个 }，修复尾逗号", "标准 JSON"],
        ["② 思考文本捞取", "在 content/reasoning 中逐个尝试配平的 {} 片段", "推理与结论混写"],
        ["③ 截断捞取", "正则提取 activityId 与 hasLowCarbon", "输出被额度截断"],
        ["④ 语义兜底", "明确说了“没有低碳行为”才判 false", "完全非 JSON"],
    ],
    widths=[2.8, 8.2, 4.0],
)
quote("安全底线：只有拿到合法 activityId 才算命中。模型说 true 却给不出 id 时一律按“没识别出来”处理，"
      "绝不凭一句话给用户加分。")

h2("6.8  思考型模型的适配")
body("qwen3-vl 系列会先思考再回答，实测踩到三类问题，均已处理：")
for t in [
    "输出额度被思考吃光：首轮 max_tokens 2600、严格重试 4000，并附带 reasoning_effort=low（不支持的网关会忽略）。",
    "单次耗时 20~90 秒：读超时放宽到 180 秒，并把“超时”与“连不上”分开报，避免把慢误判成网络故障。",
    "正文为空或 JSON 被截断：先判断 finish_reason=length 给出明确原因（该重试），再走 6.7 的捞取链。",
]:
    bullet(t)

h2("6.9  个性化推荐")
body("InsightService 用纯规则生成 1~3 条建议：优先补从未尝试的分类、连续打卡中断提醒、"
     "月目标进度落后提醒、积分够兑换证书提醒等。首页“为你推荐”与通知里的周期任务共用这套规则。")

# ---------------------------------------------------------------- 7 界面设计
h1("7  界面设计")

h2("7.1  信息架构")
body("主框架为 5 个 Tab：碳账本、记一笔、数据、科普、我的；登录页与城市碳普惠为独立页面，"
     "由“我的”进入。数据详情统一用底部面板（bindSheet）承载，按 sheetKind 路由不同内容，"
     "避免同一组件上多次 bindSheet 只有一处生效的问题。")

h2("7.2  识别交互状态机")
table(
    ["状态", "触发", "界面表现"],
    [
        ["idle", "进入页面", "入口显示“选一张照片，AI 判定后自动记账”"],
        ["pick", "点识别按钮", "拉起系统图库，按钮变“选择中”，45 秒看门狗只解锁界面不作废结果"],
        ["analyze", "选图完成", "面板先弹出，显示“正在识别这张照片，小模型可能要几秒…”"],
        ["done-ok", "模型命中且已记账", "绿色横幅“已自动记账：行为 +N”，候选行标“已记账”"],
        ["done-skip", "同图已记 / 达上限 / 保存失败", "黄色横幅说明原因，候选可手动补记"],
        ["fail", "模型报错 / 超时 / 未配置", "红色提示 + “重试这张 / 换张照片”"],
    ],
    widths=[2.4, 4.6, 8.0],
)
picture("live-view.jpeg", 6.6, "图 7-1  下拉通知栏中的实况窗卡片（今日碳账本 + 进度环）")

h2("7.3  主题与可读性")
body("应用提供 5 套皮肤，只换主色，底色与文字保持浅色，避免对比度失控。配色上有两条硬规则：")
for t in [
    "鸿蒙的 8 位色值是 ARGB（#AARRGGBB），不是 Web 的 #RRGGBBAA；半透明白必须写成 #1FFFFFFF。",
    "绿色渐变卡上不用半透明白做色块底，统计条改用不透明的深绿（#0F3D2A），保证白字对比度达标。",
]:
    bullet(t)

# ---------------------------------------------------------------- 8 安全与隐私
h1("8  安全与隐私")

h2("8.1  权限")
body("应用只申请 ohos.permission.INTERNET。备份与报表写入应用沙箱 filesDir，不需要存储权限；"
     "通知权限在运行时申请，用户可随时在系统设置中关闭。")

h2("8.2  云端安全模型")
for t in [
    "所有业务表开启 RLS 且不配置 policy：anon key 不能直接读写任何表。",
    "客户端只能调用显式授权的 RPC；函数内部用 p_token 查 sessions 表确定用户身份。",
    "service_role / secret key 不出现在客户端；仓库里只有 anon key。",
    "客户端本地只存 token，不存密码；登录态失效时自动清会话并回到未登录模板。",
]:
    bullet(t)

h2("8.3  凭据与隐私")
body("视觉模型的 API Key 只保存在本机 preferences（ai_config_json），不上传、不写日志；"
     "识别图片只发送给用户自己配置的模型接口，应用不保存图片副本。"
     "自动记账台账只保存图片指纹与次数，不含图片本身。")

# ---------------------------------------------------------------- 9 构建与部署
h1("9  构建、签名与部署")

h2("9.1  环境准备")
body("安装 DevEco Studio 6.0.1，确保 SDK 目录存在（本机为 D:/DevEco studio/sdk）。"
     "命令行构建不依赖 IDE 界面，但需要环境变量指向 SDK。")

h2("9.2  构建命令")
code('$env:DEVECO_SDK_HOME = "D:/DevEco studio/sdk"\n'
     'node "D:/DevEco studio/tools/hvigor/bin/hvigorw.js" `\n'
     '  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon')
body("产物：entry/build/default/outputs/default/entry-default-unsigned.hap。"
     "全量重建可先执行 hvigorw clean。")

h2("9.3  静态检查")
code('node "D:/DevEco studio/tools/node/node.exe" `\n'
     '  "D:/DevEco studio/plugins/codelinter/run/index.js" `\n'
     '  -c code-linter.json5 -f default .')
body("当前结果：Errors 0、Warns 1（HomeTab 的 reuse-date-instances-check，既有提示）。"
     "预览器要求告警为 0 才不拦截，若被拦截先按该机器 IDE 自带的 codelinter 重跑。")

h2("9.4  签名与安装")
body("仓库自带 OpenHarmony 根 CA 的离线签名材料，tools/sign-hap.sh（或 run.ps1）会完成"
     "“构建 → hap-sign-tool 签名 → hdc install → aa start”。签名只被模拟器/开发板信任；"
     "零售版 HarmonyOS NEXT 真机需要华为签发的调试证书。")
code("bash tools/sign-hap.sh          # 产出 dist/harmony03-signed.hap\n"
     "powershell -ExecutionPolicy Bypass -File tools\\run.ps1")

h2("9.5  辅助脚本")
table(
    ["脚本", "作用", "说明"],
    [
        ["tools/run.ps1", "构建+签名+安装+启动（PowerShell）", "自动探测 DevEco 安装位置，可选自动拉起模拟器"],
        ["tools/run.sh / run.cmd", "同上（Git Bash / CMD）", "CMD 版本先调 PowerShell，规避 WSL 缺失"],
        ["tools/sign-hap.sh", "只签名，不安装", "产出 dist/harmony03-signed.hap"],
        ["tools/verify-logic.mjs", "业务逻辑回归", "转译真实源码到 Node 执行 44 组断言"],
    ],
    widths=[4.0, 6.0, 6.0],
)

# ---------------------------------------------------------------- 10 测试与验证
h1("10  测试与验证")

h2("10.1  构建与静态检查")
table(
    ["项目", "结果"],
    [
        ["hvigorw clean + assembleHap", "BUILD SUCCESSFUL，0 error"],
        ["CodeLinter", "Errors 0 / Warns 1（HomeTab 既有性能提示）/ Suggestions 0"],
        ["签名", "hap-sign-tool 签名成功，产物可安装"],
    ],
    widths=[5.0, 11.0],
)

h2("10.2  业务逻辑回归")
body("tools/verify-logic.mjs 用 DevEco 自带 TypeScript 把真实源码转译成 CommonJS，"
     "仅把 StorageService 换成内存桩、AuthService 换成“已登录”桩，然后在 Node 中跑断言。"
     "共 44 组，覆盖：")
for t in [
    "记账：减排量与积分公式、数量边界、补记日期统计口径、跨天/跨周边界。",
    "统计：连续打卡、日/周/月/年序列、分类聚合与占比、历史筛选。",
    "积分：任务领取与删除回滚、兑换与等级、汇总缓存失效。",
    "数据：CSV 转义、备份恢复、损坏/过新/重复 id 备份、旧字段归一化。",
    "自动记账策略：单条直接入账、同轮去重、同图 24 小时去重、时间回拨、日上限、空候选。",
    "静态守卫：struct 内不得出现 get 访问器、8 位色值不得写成 #RRGGBBAA。",
]:
    bullet(t)

h2("10.3  模拟器走查")
table(
    ["场景", "结果"],
    [
        ["记一笔", "分类切换 → 选行为 → 数量/倍数/备注/日期 → 试算 → 保存，数据立即出现在首页与看板"],
        ["看板", "日/周/月/年与全部/本月/本周切换时曲线、统计、高亮同步；滚动/切 Tab 后仍正常"],
        ["重启", "杀进程重启后记录、积分、任务领取状态保留"],
        ["备份恢复", "备份 → 清空 → 恢复后记录、积分、领取状态一致"],
        ["图片识别（真实模型）", "qwen3-vl:4b 约 8.5 秒返回 activityId，自动记账 +2，全程 0 点击"],
        ["同图去重", "再次选择同一张照片，提示“24 小时内已经记过账”，记录数不变"],
        ["实况窗 / 胶囊", "开启通知后状态栏出现胶囊，通知栏出现“今日碳账本”卡片"],
        ["未登录拦截", "点识别/保存先弹登录引导，不静默加分"],
    ],
    widths=[4.6, 11.4],
)

h2("10.4  缺陷与修复记录（节选）")
table(
    ["问题", "根因", "修复"],
    [
        ["图表切换区间后停在旧数据", "Canvas 只在 onReady/onAreaChange 绘制", "新增 repaint + 固定 key 缓存画布尺寸，状态变化主动重绘"],
        ["记完账首页不刷新", "canvas key 用数据条数拼，重绘查不到尺寸", "改用固定 key，并由 @Watch 触发刷新"],
        ["任务领取把选中的行为重置", "onTokenChange 无条件 pickDefault", "改为 syncSelection，仅在失效时校正"],
        ["补记后统计与列表矛盾", "统计按写入时间、列表按业务日期", "统一按 date 聚合，补记时平移 time"],
        ["识别出来却不自动记账", "拿模型 confidence 当准入门槛，小模型打分偏低", "协议收敛为两值，类别与分值本地查表"],
        ["云端失败时整轮不记账", "自动记账强依赖 RPC 成功", "云端失败退回本机写入并标注未同步"],
        ["实况窗/胶囊不显示", "通知权限被拒（1600004），系统不再弹框", "提供“去系统设置”入口，面板说明依赖关系"],
        ["“刷新实况窗”总是提示成功", "未检查 updateLiveView 返回值", "按真实结果提示，未开启时引导"],
        ["AI 超时被判“连不上”", "读超时 90 秒短于思考型模型耗时", "放宽到 180 秒，超时与断网分开报"],
    ],
    widths=[5.0, 6.0, 5.0],
    size=9.5,
)

h2("10.5  资产与截图")
body("验证截图统一归档在 docs/verify/（首页、看板、备份恢复、识别结果、实况窗等），"
     "本文档只摘录与图片识别、实况窗相关的三张。")
picture("ai-progress.jpeg", 6.6, "图 10-1  识别过程中的面板：先给进度，避免长等待被认为卡死")

# ---------------------------------------------------------------- 11 限制与规划
h1("11  已知限制与后续规划")

h2("11.1  当前边界")
table(
    ["类别", "限制", "影响 / 规避"],
    [
        ["平台", "仅适配 phone / tablet，未做折叠屏与平板双栏", "小屏优先，平板为等比放大"],
        ["模型", "依赖用户自备的本地视觉模型；2B 模型易复读、稳定性差", "推荐 qwen3-vl:4b 及以上；面板会给出失败原因"],
        ["识别", "一张图只判一条行为；数量固定记 1 个单位", "多行为可分别选图，或手动补记"],
        ["识别", "同图 24 小时内只记一次、单行为每日 3 次", "防刷分设计，超限会明确提示"],
        ["云端", "schema.sql 未收录 revoke_claim / clear_records / replace_snapshot", "线上库已具备，仓库脚本待补齐"],
        ["家庭", "成员目录为本地演示数据，非真实社交关系", "仅用于演示完整流程"],
        ["碳普惠", "默认对接本地模拟平台", "接真实城市接口需替换地址与鉴权"],
        ["通知", "实况窗强依赖系统通知权限", "应用内已提供直达设置入口"],
        ["签名", "自签证书仅模拟器/开发板信任", "真机需华为调试证书"],
    ],
    widths=[2.4, 8.0, 5.6],
)

h2("11.2  后续规划")
for t in [
    "补齐 schema.sql 中缺失的 3 个 RPC，并加入一份可重复执行的数据库迁移脚本。",
    "把“撤销上一条自动记账”做成入口，进一步降低误判成本。",
    "识别结果支持多行为（一次返回多条 activityId），并保持现有去重与上限策略。",
    "为折叠屏/平板提供双栏布局；为大字体模式做一轮对比度与截断检查。",
    "引入本地缓存模型列表与一次连通性探测，减少配置阶段的试错。",
    "为项目初始化 Git 仓库并打 tag，交付版本可追溯。",
]:
    bullet(t)

# ---------------------------------------------------------------- 附录 A
h1("附录 A  低碳行为与碳因子清单")
body(f"共 {len(ACTS)} 条行为、{len(CATS)} 个分类。因子单位统一为 kgCO₂e；"
     "积分 = 基础分 + 减排量 × 2（最低 1 分）。", indent=True)

h2("A.1  分类一览")
table(["id", "名称", "图标", "一句话说明"],
      [[c["id"], c["name"], c["icon"], c["desc"]] for c in CATS],
      widths=[2.2, 3.0, 1.6, 9.2], size=9.5)

h2(f"A.2  行为清单（{len(ACTS)} 条）")
rows = []
for a in ACTS:
    rows.append([
        CAT_NAME.get(a["cat"], a["cat"]),
        a["id"],
        a["name"],
        a["unit"],
        f'{a["factor"]:g}',
        f'{a["point"]}',
    ])
table(["分类", "行为 id", "行为名称", "单位", "因子", "基础分"], rows,
      widths=[2.4, 4.4, 5.0, 1.6, 1.8, 1.8], size=9, align_right=(4, 5))

# ---------------------------------------------------------------- 附录 B
h1("附录 B  科普文章清单")
rows = [[SECTION_NAME.get(a["section"], a["section"]), a["title"]] for a in ARTICLES]
table(["栏目", "标题"], rows, widths=[3.0, 13.0], size=10)

# ---------------------------------------------------------------- 结尾
h1("结  语")
body("本项目的技术重点不在“功能多”，而在“账要算得准、错要错得明白”："
     "所有分数由同一条记录派生、所有统计按业务日期聚合、所有异步结果都有兜底与提示。"
     "图片识别这条链路尤其典型——模型只负责判断，金额、类别、去重与限流全部由本地代码把关，"
     "既保留了零点击的体验，也守住了积分不被随意刷取的底线。")
body("文档中的数值与接口均取自当前仓库源码与数据库脚本；后续若调整行为库、积分公式或模型协议，"
     "请同步更新本文档、README 与代码注释，保持三处口径一致。")

OUT.parent.mkdir(parents=True, exist_ok=True)
doc.save(str(OUT))
print(f"OK -> {OUT}")
print(f"files={len(FILES)} lines={TOTAL_LINES} acts={len(ACTS)} cats={len(CATS)} articles={len(ARTICLES)}")
