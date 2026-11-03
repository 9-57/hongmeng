#!/usr/bin/env node
/**
 * 业务逻辑回归脚本（开发期工具，不参与 HAP 构建）。
 *
 * 做法：用 DevEco Studio 自带的 TypeScript 编译器，把真实的
 * model/、common/Utils、viewmodel/CarbonStore 转译成 CommonJS，
 * 仅把 StorageService 换成内存桩，然后在 Node 里跑断言。
 * 这样验证的是**仓库里的真实源码**，不是另写一份算法。
 *
 * 运行：
 *   node tools/verify-logic.mjs
 *   DEVECO_TS="D:/.../typescript/lib/typescript.js" node tools/verify-logic.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'entry', 'src', 'main', 'ets');

const TS_CANDIDATES = [
  process.env.DEVECO_TS,
  // 本机实际安装位置
  'D:/DevEco studio/plugins/codelinter/node_modules/typescript/lib/typescript.js',
  // 旧版/别的机器上的位置，保留兜底
  'D:/HarmonyOS/DevEco Studio6.0.1/DevEco Studio/plugins/codelinter/node_modules/typescript/lib/typescript.js',
  'D:/HarmonyOS/DevEco Studio/plugins/codelinter/node_modules/typescript/lib/typescript.js',
  'D:/deveco-studio/DevEco Studio/plugins/codelinter/node_modules/typescript/lib/typescript.js',
  path.join(ROOT, 'node_modules', 'typescript', 'lib', 'typescript.js')
].filter((p) => typeof p === 'string' && p.length > 0);

let tsPath = '';
for (const p of TS_CANDIDATES) {
  if (fs.existsSync(p)) {
    tsPath = p;
    break;
  }
}
if (tsPath.length === 0) {
  console.error('找不到 TypeScript 编译器。请用 DEVECO_TS 环境变量指定 typescript.js 路径。');
  process.exit(2);
}
const ts = require(tsPath);

const OUT = fs.mkdtempSync(path.join(os.tmpdir(), 'carbon-verify-'));
const TRANSPILE = [
  ['common/Utils.ets', 'common/Utils.js'],
  ['model/CarbonModels.ets', 'model/CarbonModels.js'],
  ['model/CarbonData.ets', 'model/CarbonData.js'],
  ['model/ArticleData.ets', 'model/ArticleData.js'],
  ['service/InsightService.ets', 'service/InsightService.js'],
  ['service/FamilyService.ets', 'service/FamilyService.js'],
  ['common/InviteAlert.ets', 'common/InviteAlert.js'],
  ['service/AutoRecordPolicy.ets', 'service/AutoRecordPolicy.js'],
  ['viewmodel/CarbonStore.ets', 'viewmodel/CarbonStore.js']
];

for (const [from, to] of TRANSPILE) {
  const source = fs.readFileSync(path.join(SRC, from), 'utf8');
  const out = ts.transpileModule(source, {
    fileName: from,
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      useDefineForClassFields: false,
      esModuleInterop: true
    }
  });
  const dest = path.join(OUT, to);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, out.outputText, 'utf8');
}

// 只替换持久化服务：preferences 在 Node 里不可用，用内存 Map 等价实现读写语义
fs.mkdirSync(path.join(OUT, 'service'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'service', 'StorageService.js'), `'use strict';
class StorageStub {
  constructor() { this.data = new Map(); }
  get isReady() { return true; }
  get recordsKey() { return 'records_json'; }
  get metaKey() { return 'meta_json'; }
  get familyKey() { return 'family_json'; }
  async readString(key, defValue) { return this.data.has(key) ? this.data.get(key) : defValue; }
  async writeString(key, value) { this.data.set(key, value); }
}
exports.storage = new StorageStub();
`, 'utf8');

// 账号服务在 Node 里不可用：用具名桩替代，测试以"已登录"状态运行
fs.writeFileSync(path.join(OUT, 'service', 'AuthService.js'), `'use strict';
const authStub = {
  isLoggedIn: true,
  token: 'test-token',
  username: 'carbonuser01',
  user: { id: 'test-user', nickName: '低碳同学' },
  updateUser() {}
};
exports.auth = authStub;
`, 'utf8');

// 云端 RPC 在 Node 里不可用：给一个"离线"桩，验证失败路径不会抛异常
fs.writeFileSync(path.join(OUT, 'service', 'SupabaseClient.js'), `'use strict';
class RpcResponse {
  constructor() {
    this.httpOk = false;
    this.ok = false;
    this.code = '';
    this.message = '';
    this.raw = '';
    this.status = 0;
  }
}
function asText(v, def) { return typeof v === 'string' ? v : def; }
function asNumber(v, def) { return typeof v === 'number' && isFinite(v) ? v : def; }
const supabase = {
  async rpc() {
    const r = new RpcResponse();
    r.code = 'network';
    r.message = '网络连接失败，请检查网络后重试';
    return r;
  }
};
exports.RpcResponse = RpcResponse;
exports.asText = asText;
exports.asNumber = asNumber;
exports.supabase = supabase;
`, 'utf8');

// Utils.bumpDataVersion 用到 AppStorage，补一个最小实现
globalThis.AppStorage = {
  data: new Map(),
  get(key) { return this.data.get(key); },
  setOrCreate(key, value) { this.data.set(key, value); }
};

const utils = require(path.join(OUT, 'common', 'Utils.js'));
const models = require(path.join(OUT, 'model', 'CarbonModels.js'));
const { carbonStore: store } = require(path.join(OUT, 'viewmodel', 'CarbonStore.js'));
const { familyService } = require(path.join(OUT, 'service', 'FamilyService.js'));
const policy = require(path.join(OUT, 'service', 'AutoRecordPolicy.js'));

const TESTS = [];
function test(name, fn) {
  TESTS.push({ name, fn });
}

function pad2(n) {
  return n < 10 ? '0' + n : String(n);
}
function dstr(offsetDays) {
  const d = new Date();
  d.setHours(12, 0, 0, 0);
  d.setDate(d.getDate() + offsetDays);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}
function dateOfMonth(monthOffset, day) {
  const d = new Date();
  d.setHours(12, 0, 0, 0);
  d.setDate(1);
  d.setMonth(d.getMonth() + monthOffset);
  d.setDate(day);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}
function near(actual, expected, msg) {
  assert.ok(Math.abs(actual - expected) < 0.011, `${msg}: 期望 ${expected}，实际 ${actual}`);
}
async function reset() {
  await store.clearAll();
  await store.setNickName('低碳同学');
  await store.setMonthGoal(30);
  await familyService.reset();
}
function act(id) {
  const a = store.getActivityById(id);
  assert.ok(a, `行为 ${id} 不存在`);
  return a;
}
function reduceOf(activity, qty) {
  return utils.round(activity.factor * qty, 3);
}

// ============ 1. 记录写入与减排/积分公式 ============
test('addRecord 计算减排量与积分', async () => {
  await reset();
  const walk = act('travel_walk');
  const got = await store.addRecord(walk, 2, dstr(0), '');
  const expectedReduction = reduceOf(walk, 2);
  const expectedPoint = Math.max(1, Math.round(walk.basePoint + expectedReduction * 2));
  assert.equal(got, expectedPoint);
  assert.equal(store.records.length, 1);
  assert.equal(store.records[0].date, dstr(0));
  near(store.records[0].reduction, expectedReduction, '减排量');
});

// ============ 2. 补记历史日期：统计必须按业务日期而不是写入时间 ============
test('补记 40 天前：不计入今日/本周/本月', async () => {
  await reset();
  const tree = act('plant_tree');
  await store.addRecord(tree, 1, dstr(-40), '补记');
  const s = store.getSummary();
  near(s.totalReduction, reduceOf(tree, 1), '累计减排');
  assert.equal(s.todayReduction, 0, '今日减排应为 0');
  assert.equal(s.todayCount, 0, '今日条数应为 0');
  assert.equal(s.weekReduction, 0, '本周减排应为 0');
  assert.equal(s.monthReduction, 0, '本月减排应为 0');
  assert.equal(s.streakDays, 0, '连续天数应为 0');
  // time 也要落在那一天，底部记录时间与日期不能自相矛盾
  assert.equal(utils.formatDate(store.records[0].time), dstr(-40));
});

test('补记昨天：计入连续天数但不计入今日', async () => {
  await reset();
  await store.addRecord(act('travel_bike'), 3, dstr(-1), '');
  const s = store.getSummary();
  assert.equal(s.todayCount, 0);
  assert.equal(s.streakDays, 1, '今天没记允许从昨天起算');
  near(s.totalReduction, reduceOf(act('travel_bike'), 3), '累计减排');
});

// ============ 3. 连续打卡 ============
test('连续三天打卡 = 3', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('travel_walk'), 1, dstr(-1), '');
  await store.addRecord(act('travel_walk'), 1, dstr(-2), '');
  assert.equal(store.getSummary().streakDays, 3);
});

test('中间断一天则连续归零', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('travel_walk'), 1, dstr(-2), '');
  assert.equal(store.getSummary().streakDays, 1);
});

// ============ 4. 序列 ============
test('dailySeries 按日期落位（今天/昨天）', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('travel_metro'), 10, dstr(-1), '');
  const list = store.dailySeries(7);
  assert.equal(list.length, 7);
  near(list[6].value, reduceOf(act('travel_walk'), 1), '今天');
  near(list[5].value, reduceOf(act('travel_metro'), 10), '昨天');
  assert.equal(list[6].label, '今天');
});

test('weeklySeries 末项为本周边界内的合计', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('plant_tree'), 10, dstr(-40), '');
  const list = store.weeklySeries(8);
  near(list[7].value, reduceOf(act('travel_walk'), 1), '本周');
  assert.equal(list[7].label, '本周');
});

// ============ 5. 分类聚合 ============
test('categorySeries 占比与排序', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  const cats = store.categorySeries('today');
  const plant = cats.find((c) => c.categoryId === 'plant');
  const travel = cats.find((c) => c.categoryId === 'travel');
  near(plant.value, 18, '低碳公益');
  near(travel.value, 0.201, '绿色出行');
  assert.equal(cats[0].categoryId, 'plant', '应按减排量倒序');
  near(plant.ratio + travel.ratio, 1, '占比合计');
  // 展示值四舍五入后仍要闭环到 100%，不能出现 99.5%
  assert.equal(Math.round((plant.ratio + travel.ratio) * 100), 100, '占比应闭环到 100%');

  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  const only = store.categorySeries('today').filter((c) => c.value > 0);
  assert.equal(only.length, 1);
  assert.equal(only[0].ratio, 1, '单一分类占比必须是 100%');
});

test('filterRecords 同时按范围与分类过滤', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('plant_tree'), 1, dstr(-40), '');
  const list = store.filterRecords('month', 'plant');
  assert.equal(list.length, 1, '只应留下本月的一条低碳公益');
});

// ============ 6. 每日任务领取与回滚 ============
test('领任务加积分，删记录后回收奖励', async () => {
  await reset();
  const walk = act('travel_walk');
  const point = await store.addRecord(walk, 2, dstr(0), '');
  let tasks = store.getDailyTasks();
  const walkTask = tasks.find((t) => t.task.id === 't_walk');
  assert.equal(walkTask.done, true);
  assert.equal(walkTask.current, 1);

  const reward = await store.claimTask('t_walk');
  assert.equal(reward, 8);
  assert.equal(store.getSummary().totalPoint, point + reward);
  assert.equal(store.getDailyTasks().find((t) => t.task.id === 't_walk').claimed, true);

  const again = await store.claimTask('t_walk');
  assert.equal(again, 0, '不能重复领取');

  await store.deleteRecord(store.records[0].id);
  assert.equal(store.getSummary().totalPoint, 0, '奖励应随记录回收');
  assert.equal(store.getDailyTasks().find((t) => t.task.id === 't_walk').claimed, false);
});

test('任务进度按业务日期判断（昨天记录不算今天完成）', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(-1), '');
  const walkTask = store.getDailyTasks().find((t) => t.task.id === 't_walk');
  assert.equal(walkTask.done, false);
  assert.equal(walkTask.current, 0);
  assert.equal(await store.claimTask('t_walk'), 0);
});

test('过期任务 key 会被清理', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.claimTask('t_walk');
  store.meta.claimedTasks.push('2000-01-01#t_walk');
  const before = store.meta.spentPoint;
  await store.revokeInvalidClaims();
  assert.equal(store.meta.claimedTasks.some((k) => k.startsWith('2000-01-01')), false);
  assert.equal(store.meta.spentPoint, before, '清理 key 不应改变账目');
});

// ============ 7. 兑换与等级 ============
test('兑换扣积分且不可重复', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  const total = store.getSummary().totalPoint;
  assert.ok(total >= 112, `积分应足够，实际 ${total}`);
  assert.equal(await store.redeem('r_bamboo'), true);
  assert.equal(store.getSummary().totalPoint, total - 100);
  assert.equal(await store.redeem('r_bamboo'), false, '不能重复兑换');
  assert.equal(await store.redeem('c_carbon'), false, '积分不足应失败');
});

test('等级阈值与进度来自同一份数据', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  const lv = store.levelInfo();
  assert.equal(lv.total, 36);
  assert.equal(lv.code, 'Lv.5');
  assert.equal(lv.title, '减碳行动派');
  near(lv.nextNeed, 24, '距下一级');
  near(lv.progress, 0.2, '等级进度');
  assert.equal(lv.isMax, false);
});

// ============ 8. 月度复盘 ============
test('monthReview 本月/上月/活跃天数/最佳记录', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dateOfMonth(0, 1), '');
  await store.addRecord(act('travel_walk'), 1, dateOfMonth(-1, 15), '');
  const review = store.monthReview(0);
  near(review.reduction, 18, '本月减排');
  near(review.lastReduction, reduceOf(act('travel_walk'), 1), '上月减排');
  assert.equal(review.activeDays, 1);
  assert.equal(review.recordCount, 1, '本月记录条数');
  assert.equal(review.hasPrev, true);
  assert.equal(review.bestCategoryName, '低碳公益');
  assert.equal(review.bestRecordName, '参与植树');
  assert.equal(review.hasBestRecord, true);
  assert.ok(review.changeRate > 0, '环比应上升');

  const months = store.monthlySeries(6);
  near(months[5].value, review.reduction, '月度序列本月');
  near(months[4].value, review.lastReduction, '月度序列上月');
});

test('monthReview 无上月数据时 hasPrev=false', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  const review = store.monthReview(0);
  assert.equal(review.hasPrev, false);
  assert.equal(review.changeRate, 0);
});

// ============ 9. 汇总缓存 ============
test('汇总缓存随写入失效', async () => {
  await reset();
  const first = store.getSummary();
  assert.equal(store.getSummary(), first, '未变更时应复用缓存');
  assert.equal(first.totalCount, 0);
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  const second = store.getSummary();
  assert.notEqual(second, first, '写入后应重建');
  assert.equal(second.totalCount, 1);
});

// ============ 10. CSV 转义 ============
test('CSV 含逗号/引号的备注被正确转义', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), 'a,b"c');
  const csv = store.buildCsvReport();
  assert.ok(csv.includes('"a,b""c"'), '期望 RFC4180 转义');
  assert.ok(csv.split('\n')[0].startsWith('日期,时间,行为'));
});

// ============ 11. 备份与恢复 ============
test('备份 → 清空 → 恢复，账目一致', async () => {
  await reset();
  await store.addRecord(act('plant_tree'), 1, dstr(0), '备份');
  await store.addRecord(act('travel_walk'), 2, dstr(-1), '');
  await store.setNickName('小明');
  await store.setMonthGoal(66);
  const payload = store.buildBackupPayload();
  const totalBefore = store.getSummary().totalReduction;
  const pointBefore = store.getSummary().totalPoint;

  await store.clearAll();
  assert.equal(store.records.length, 0);

  const count = await store.restoreFromPayload(payload);
  assert.equal(count, 2);
  assert.equal(store.records.length, 2);
  assert.equal(store.nickName, '小明');
  assert.equal(store.monthGoal, 66);
  near(store.getSummary().totalReduction, totalBefore, '恢复后累计减排');
  assert.equal(store.getSummary().totalPoint, pointBefore, '恢复后积分');
});

test('损坏/过新/重复 id 的备份处理', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  await store.addRecord(act('plant_tree'), 1, dstr(-1), '');
  assert.equal(await store.restoreFromPayload('not-json'), -1);
  assert.equal(await store.restoreFromPayload(''), -1);

  const pack = JSON.parse(store.buildBackupPayload());
  pack.version = 99;
  assert.equal(await store.restoreFromPayload(JSON.stringify(pack)), -1, '过新版本应拒绝');

  pack.version = 1;
  pack.records[1].id = pack.records[0].id;
  const count = await store.restoreFromPayload(JSON.stringify(pack));
  assert.equal(count, 2);
  const ids = new Set(store.records.map((r) => r.id));
  assert.equal(ids.size, 2, '重复 id 应被重新生成');
});

// ============ 12. 证书 ============
test('证书兑换生成编号/日期，备份恢复保留', async () => {
  await reset();
  // 6 棵植树 = 336 分：先兑 100 分徽章，再兑 180 分证书
  for (let i = 0; i < 6; i++) {
    await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  }
  assert.equal(store.certificates().length, 0, '初始没有证书');

  assert.equal(await store.redeem('r_bamboo'), true, '先兑一个普通徽章');
  assert.equal(store.certificates().length, 0, '徽章不产生证书');

  assert.equal(await store.redeem('c_tree1'), true);
  const certs = store.certificates();
  assert.equal(certs.length, 1);
  assert.equal(certs[0].badge.id, 'c_tree1');
  assert.ok(certs[0].serial.startsWith('CF-'), '证书编号格式');
  assert.ok(certs[0].issuedAt > 0, '颁发时间应写入');
  assert.equal(store.certificateOf('c_tree1').serial, certs[0].serial);
  assert.equal(store.certificateOf('r_bamboo'), null, '徽章没有证书');

  const payload = store.buildBackupPayload();
  await store.clearAll();
  assert.equal(store.certificates().length, 0);
  await store.restoreFromPayload(payload);
  const restored = store.certificates();
  assert.equal(restored.length, 1, '备份恢复后证书还在');
  assert.equal(restored[0].serial, certs[0].serial);
});

test('旧备份只有 exchanged 时自动补发证书', async () => {
  await reset();
  const pack = {
    version: 1,
    exportedAt: '01-01 00:00',
    records: [],
    exchanged: ['c_tree5'],
    claimedTasks: [],
    spentPoint: 700,
    nickName: '老用户',
    monthGoal: 30
  };
  const count = await store.restoreFromPayload(JSON.stringify(pack));
  assert.equal(count, 0);
  const certs = store.certificates();
  assert.equal(certs.length, 1, '老数据应补出证书');
  assert.equal(certs[0].badge.id, 'c_tree5');
  assert.equal(certs[0].issuedAt, 0, '未知日期标记为 0');
  assert.ok(certs[0].serial.startsWith('CF-LEGACY-'));
});

// ============ 13. 归一化 ============
test('旧数据缺字段时归一化补齐', async () => {
  await reset();
  const pack = {
    version: 1,
    exportedAt: '01-01 00:00',
    records: [{ activityId: 'travel_walk', qty: 2 }],
    exchanged: [],
    claimedTasks: [],
    spentPoint: 0,
    nickName: '旧数据',
    monthGoal: 30
  };
  const count = await store.restoreFromPayload(JSON.stringify(pack));
  assert.equal(count, 1);
  const r = store.records[0];
  assert.ok(r.id.length > 0, '补 id');
  assert.equal(r.activityName, '步行代替打车');
  assert.equal(r.categoryId, 'travel');
  assert.ok(r.date.length === 10, '补日期');
  near(r.reduction, reduceOf(act('travel_walk'), 2), '补减排量');
  assert.ok(r.point > 0, '补积分');
});

// ============ 13. 分类/文章索引 ============
test('ID 索引可直接取到行为/分类/文章', async () => {
  assert.equal(store.getActivityById('shop_bag').categoryId, 'shopping');
  assert.equal(store.getCategoryById('food').name, '光盘行动');
  assert.equal(store.getArticleById('a_what').title, '什么是碳中和、碳达峰？');
  assert.equal(store.getActivityById('nope'), undefined);
  assert.equal(store.iconOf('travel_walk'), '🚶');
  assert.equal(store.iconOf('nope'), '🍃');
  const shopping = store.activitiesOf('shopping');
  assert.equal(shopping.length, 4, '绿色消费应有 4 条行为');
});

// ============ 14. 智能服务：推荐 / 分享 ============
test('个性化推荐：空数据先引导第一条记录', async () => {
  await reset();
  const list = store.insights();
  assert.ok(list.length >= 2, '至少两条推荐');
  assert.equal(list[0].id, 'first');
  assert.equal(list[0].categoryId, 'travel');
});

test('个性化推荐：优先补从未尝试的分类', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(0), '');
  const list = store.insights();
  const tryNew = list.find((i) => i.id === 'try-energy');
  assert.ok(tryNew, '已记录出行，应推荐未尝试的节水节电');
  assert.equal(tryNew.kind, 'task');
  assert.ok(tryNew.activityId.length > 0, '推荐应带具体行为');
});

test('个性化推荐：连续打卡今天未记会置顶提醒', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 1, dstr(-1), '');
  await store.addRecord(act('travel_walk'), 1, dstr(-2), '');
  const list = store.insights();
  assert.equal(list[0].id, 'streak', '断签提醒应在最前');
  assert.ok(list[0].title.includes('连续 2 天'));
});

test('个性化推荐：积分够证书时提醒兑换', async () => {
  await reset();
  for (let i = 0; i < 4; i++) {
    await store.addRecord(act('plant_tree'), 1, dstr(0), '');
  }
  const list = store.insights();
  assert.ok(list.some((i) => i.id === 'cert'), '224 分且无证书时应提示兑换');
});

test('分享文案包含成绩与话题标签', async () => {
  await reset();
  await store.addRecord(act('travel_walk'), 2, dstr(0), '');
  await store.setNickName('小明');
  const text = store.buildShareText();
  assert.ok(text.includes('小明'));
  assert.ok(text.includes('低碳成绩单'));
  assert.ok(text.includes('kgCO2e'));
  assert.ok(text.includes('碳积分'));
  assert.ok(text.includes('#碳足迹'));
});

// ============ 15. 家庭：云端缓存解析 / 汇总 / 失败降级 ============
const { storage: storageStub } = require(path.join(OUT, 'service', 'StorageService.js'));

/** 造一份"云端返回后写进本地缓存"的家庭数据（字段与 RPC 返回一致） */
function familyCache() {
  return {
    joined: true,
    cachedAt: Date.now(),
    family: {
      id: 'f-1',
      name: '测试家庭',
      inviteCode: 'FAM-1234',
      ownerId: 'u-owner',
      createdAt: 0,
      memberLimit: 6,
      members: [
        { id: 'u-owner', username: 'lyr02', name: '房主', avatar: '🏡', isMe: false, isOwner: true,
          monthReduction: 10, todayReduction: 1, totalReduction: 30 },
        { id: 'test-user', username: 'me', name: '低碳同学', avatar: '🌱', isMe: true, isOwner: false,
          monthReduction: 4, todayReduction: 0.5, totalReduction: 12 }
      ]
    },
    incoming: [
      { inviteId: 'i-1', inviterId: 'u-x', inviteeId: 'test-user', nickname: '小林', username: 'xiaolin',
        familyName: '绿芽之家', hasFamily: true, createdAt: '', expiresAt: '' }
    ],
    outgoing: [
      { inviteId: 'i-2', inviterId: 'test-user', inviteeId: 'u-y', nickname: '小周', username: 'xiaozhou',
        familyName: '测试家庭', hasFamily: false, createdAt: '', expiresAt: '' }
    ]
  };
}

test('家庭：缓存里的家庭能正确解析并汇总', async () => {
  await reset();
  storageStub.data.set('family_json', JSON.stringify(familyCache()));
  await familyService.load(true);
  assert.equal(familyService.hasFamily(), true);
  assert.equal(familyService.family().name, '测试家庭');
  assert.equal(familyService.family().members.length, 2);
  assert.equal(familyService.family().memberLimit, 6);
  assert.equal(familyService.family().inviteCode, 'FAM-1234');
  assert.equal(familyService.isOwner(), false, 'test-user 是成员，不是房主');
  const sum = familyService.summary({ monthReduction: 0, todayReduction: 0, totalReduction: 0 });
  near(sum.monthReduction, 14, '家庭本月 = 10 + 4');
  near(sum.todayReduction, 1.5, '家庭今日 = 1 + 0.5');
  near(sum.totalReduction, 42, '家庭累计 = 30 + 12');
  assert.equal(sum.memberCount, 2);
  near(sum.averageMonth, 7, '人均本月 = 14 / 2');
});

test('家庭：收件箱与已发出的邀请分别解析', async () => {
  await reset();
  storageStub.data.set('family_json', JSON.stringify(familyCache()));
  await familyService.load(true);
  assert.equal(familyService.pendingCount(), 1, '只有收到的邀请算待处理');
  const inv = familyService.incoming()[0];
  assert.equal(inv.inviteId, 'i-1');
  assert.equal(inv.nickname, '小林');
  assert.equal(inv.familyName, '绿芽之家');
  assert.equal(inv.hasFamily, true, '加入型邀请');
  const out = familyService.outgoing()[0];
  assert.equal(out.inviteeId, 'u-y');
  assert.equal(out.hasFamily, false, '组建型邀请');
});

test('家庭：损坏的缓存不会让页面崩', async () => {
  await reset();
  storageStub.data.set('family_json', '{这不是 JSON');
  await familyService.load(true);
  assert.equal(familyService.hasFamily(), false);
  assert.equal(familyService.pendingCount(), 0);
  assert.equal(familyService.family().members.length, 0);
});

test('家庭：断网时刷新返回可读提示，搜索降级为空', async () => {
  await reset();
  const err = await familyService.refresh();
  assert.ok(err.length > 0, '失败要返回可展示的文案');
  const list = await familyService.search('lyr02');
  assert.deepEqual(list, [], '离线时搜索返回空数组而不是抛异常');
  const blank = await familyService.search('   ');
  assert.deepEqual(blank, [], '空关键词不发请求');
});

test('家庭：备份不携带家庭数据（家庭属于账号）', async () => {
  await reset();
  storageStub.data.set('family_json', JSON.stringify(familyCache()));
  await familyService.load(true);
  assert.equal(familyService.hasFamily(), true);
  assert.equal(familyService.exportState(), '', '导出为空，备份文件里不带家庭');
  assert.equal(await familyService.importState('{}'), false, '旧备份不覆盖云端家庭');
  const payload = store.buildBackupPayload();
  await familyService.reset();
  assert.equal(familyService.hasFamily(), false);
  const restored = await store.restoreFromPayload(payload);
  assert.equal(restored, 0);
  assert.equal(familyService.hasFamily(), false, '恢复备份不应重建家庭');
});

// ============ 16. 家庭邀请提醒（弹窗规则） ============
const { pickInviteToAlert, inviteAlertText, inviteAlertWho } =
  require(path.join(OUT, 'common', 'InviteAlert.js'));

function invite(id, extra) {
  return Object.assign({
    inviteId: id, inviterId: 'u-1', inviteeId: 'me', nickname: '小林', username: 'xiaolin',
    familyName: '绿芽之家', hasFamily: true, createdAt: '', expiresAt: ''
  }, extra || {});
}

test('邀请提醒：未登录或已有家庭时不弹', () => {
  const list = [invite('i-1')];
  assert.equal(pickInviteToAlert(list, [], false, true).inviteId, 'i-1', '正常情况下要弹');
  assert.equal(pickInviteToAlert(list, [], true, true), null, '已经有家庭就不打扰');
  assert.equal(pickInviteToAlert(list, [], false, false), null, '未登录不弹');
});

test('邀请提醒：同一条邀请只弹一次', () => {
  const list = [invite('i-1')];
  assert.equal(pickInviteToAlert(list, ['i-1'], false, true), null, '弹过就跳过，不能 20 秒后又弹');
  assert.equal(pickInviteToAlert(list, ['i-999'], false, true).inviteId, 'i-1', '别的 id 不影响');
});

test('邀请提醒：多条时按顺序取第一条没弹过的', () => {
  const list = [invite('i-1'), invite('i-2'), invite('i-3')];
  assert.equal(pickInviteToAlert(list, [], false, true).inviteId, 'i-1');
  assert.equal(pickInviteToAlert(list, ['i-1'], false, true).inviteId, 'i-2');
  assert.equal(pickInviteToAlert(list, ['i-1', 'i-2', 'i-3'], false, true), null);
});

test('邀请提醒：文案区分加入型与组建型，缺字段有兜底', () => {
  const join = invite('i-1', { hasFamily: true, familyName: '绿芽之家' });
  assert.ok(inviteAlertText(join).indexOf('邀请你加入') >= 0, '加入型');
  assert.ok(inviteAlertText(join).indexOf('绿芽之家') >= 0, '带上家庭名');
  const made = invite('i-2', { hasFamily: false, familyName: '我们的小家' });
  assert.ok(inviteAlertText(made).indexOf('一起组建') >= 0, '组建型');
  assert.equal(inviteAlertWho(invite('i-3', { nickname: '', username: 'xrbx' })), 'xrbx', '没昵称退回账号');
  assert.equal(inviteAlertWho(invite('i-4', { nickname: '', username: '' })), '有人', '都没有也有称呼');
  assert.ok(inviteAlertText(invite('i-5', { familyName: '' })).length > 0, '没家庭名也有正文');
});

test('邀请提醒：空列表与坏数据不弹也不崩', () => {
  assert.equal(pickInviteToAlert([], [], false, true), null);
  assert.equal(pickInviteToAlert([invite('')], [], false, true), null, '没有 id 的邀请不弹');
});

// ============ 17. 图片识别自动记账策略 ============
function cand(id) {
  return new policy.AutoCandidate(id, id);
}

function policyCtx() {
  const ctx = new policy.PolicyContext();
  ctx.now = Date.now();
  ctx.dailyCap = 3;
  ctx.dedupeWindowMs = 24 * 60 * 60 * 1000;
  return ctx;
}

test('自动记账：模型说是什么就记什么', () => {
  const d = policy.decideAutoRecords([cand('travel_bike')], '', policyCtx());
  assert.deepEqual(d.accepted.map((c) => c.activityId), ['travel_bike']);
  assert.equal(d.duplicatedImage, false);
});

test('自动记账：同一次结果里同一个行为只算一次', () => {
  const d = policy.decideAutoRecords([cand('travel_bike'), cand('travel_bike')], '', policyCtx());
  assert.equal(d.accepted.length, 1);
});

test('自动记账：同一张图 24 小时内不重复加分', () => {
  const ctx = policyCtx();
  ctx.imageSeen.set('abcdef', ctx.now - 1000);
  const d = policy.decideAutoRecords([cand('travel_bike')], 'abcdef', ctx);
  assert.equal(d.duplicatedImage, true);
  assert.equal(d.accepted.length, 0);
});

test('自动记账：超过 24 小时的同图可以再记', () => {
  const ctx = policyCtx();
  ctx.imageSeen.set('abcdef', ctx.now - 25 * 60 * 60 * 1000);
  const d = policy.decideAutoRecords([cand('travel_bike')], 'abcdef', ctx);
  assert.equal(d.duplicatedImage, false);
  assert.equal(d.accepted.length, 1);
});

test('自动记账：系统时间被回拨也按去重窗口处理', () => {
  const ctx = policyCtx();
  ctx.imageSeen.set('abcdef', ctx.now + 60 * 1000);
  const d = policy.decideAutoRecords([cand('travel_bike')], 'abcdef', ctx);
  assert.equal(d.duplicatedImage, true);
});

test('自动记账：同一个行为达到每日上限后不再自动加分', () => {
  const ctx = policyCtx();
  ctx.todayCount.set('travel_bike', 3);
  const d = policy.decideAutoRecords([cand('travel_bike')], '', ctx);
  assert.equal(d.accepted.length, 0);
  assert.equal(d.cappedCount(), 1);
});

test('自动记账：空候选不产生任何记录', () => {
  const d = policy.decideAutoRecords([], '', policyCtx());
  assert.equal(d.accepted.length, 0);
  assert.equal(d.skipped.length, 0);
  assert.equal(d.duplicatedImage, false);
});

// ============ 17. 静态守卫（编译期踩过的坑） ============
function listEts(dir) {
  const out = [];
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    if (fs.statSync(p).isDirectory()) {
      out.push(...listEts(p));
    } else if (name.endsWith('.ets')) {
      out.push(p);
    }
  }
  return out;
}

test('静态检查：struct 内不能有 get 访问器（会被 ets-loader 丢弃）', () => {
  const offenders = [];
  for (const file of listEts(SRC)) {
    const text = fs.readFileSync(file, 'utf8');
    if (!text.includes('@Component') && !text.includes('@Entry')) {
      continue;
    }
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (/^\s+get\s+[A-Za-z_]\w*\s*\(/.test(lines[i])) {
        offenders.push(`${path.relative(ROOT, file)}:${i + 1} ${lines[i].trim()}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `ets-loader 会丢弃 struct 内的 get 访问器：\n${offenders.join('\n')}`);
});

test('静态检查：8 位色值必须按 ARGB 书写（#FFFFFFxx 会变成黄色）', () => {
  const offenders = [];
  for (const file of listEts(SRC)) {
    const text = fs.readFileSync(file, 'utf8');
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (/#[Ff]{6}[0-9A-Fa-f]{2}\b/.test(lines[i])) {
        offenders.push(`${path.relative(ROOT, file)}:${i + 1} ${lines[i].trim()}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `半透明白应写成 #1FFFFFFF 这类 ARGB：\n${offenders.join('\n')}`);
});

// ============ 运行 ============
let passed = 0;
const failures = [];
for (const t of TESTS) {
  try {
    await t.fn();
    passed += 1;
    console.log(`  ✓ ${t.name}`);
  } catch (e) {
    failures.push({ name: t.name, error: e });
    console.log(`  ✗ ${t.name}`);
  }
}
console.log(`\n${passed}/${TESTS.length} 通过`);
for (const f of failures) {
  console.error(`\n[FAIL] ${f.name}\n${f.error && f.error.stack ? f.error.stack : f.error}`);
}
fs.rmSync(OUT, { recursive: true, force: true });
process.exit(failures.length === 0 ? 0 : 1);
