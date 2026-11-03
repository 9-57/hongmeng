import { Activity, Category, Badge, DailyTask } from '../model/CarbonModels';

/**
 * 四级分类（对应赛题"出行、节水节电、旧物回收、光盘行动"四类，另补两类贴近校园生活）
 */
export const CATEGORIES: Category[] = [
  new Category('travel', '绿色出行', '🚲', '#2F9E68', '少开一次车，多走一段路'),
  new Category('energy', '节水节电', '💡', '#9C540F', '随手关灯关水，省下的都是碳'),
  new Category('recycle', '旧物回收', '♻️', '#3C82D6', '让闲置物品多循环一次'),
  new Category('food', '光盘行动', '🍚', '#D96A5B', '吃多少点多少，不剩一粒米'),
  new Category('shopping', '绿色消费', '🛍️', '#8B6FC4', '少用一次性，多买可循环'),
  new Category('plant', '低碳公益', '🌱', '#4F9D45', '种一棵树，抵一份碳')
];

/**
 * 内置碳排放因子库
 * 因子单位统一为 kgCO2e，取值参考《中国产品全生命周期温室气体排放系数集》、
 * 生态环境部《大型活动碳中和实施指南（试行）》、IPCC AR6 及行业公开口径，
 * 均为"常识性估算值"，用于教学演示与大众科普，不作为碳交易核算依据。
 */
export const ACTIVITIES: Activity[] = [
  // ============ 绿色出行 ============
  new Activity('travel_walk', 'travel', '步行代替打车', '🚶', 'km', 0.201, 2,
    '燃油网约车约 0.201 kgCO2e/km', '3 公里内能走就走，一路都是风景', 2, 1, 30),
  new Activity('travel_bike', 'travel', '骑共享单车', '🚲', 'km', 0.12, 3,
    '小汽车约 0.171 kgCO2e/km，自行车近乎为 0，折算替代收益约 0.12', '短途 2 公里，骑行 10 分钟', 2, 1, 30),
  new Activity('travel_bus', 'travel', '公交出行', '🚌', 'km', 0.087, 3,
    '公交约 0.087 kgCO2e/人·km 相对私家车的替代收益', '早晚高峰坐公交，还能补个觉', 8, 1, 60),
  new Activity('travel_metro', 'travel', '地铁出行', '🚇', 'km', 0.097, 3,
    '地铁约 0.06~0.10 kgCO2e/人·km，按替代私家车计', '跨校区、进市区首选', 10, 1, 80),
  new Activity('travel_traintrip', 'travel', '高铁/火车代替飞机', '🚄', '次', 26.0, 8,
    '1000km 行程：飞机约 150kg，高铁约 30kg，差额约 120kg，按中短途折算', '同城出差、回家探亲可优先选高铁', 1, 1, 4),
  new Activity('travel_carpool', 'travel', '拼车/顺风车', '🚗', '次', 2.4, 4,
    '4 人拼车相比每人单独打车，单次可减约 2.4 kgCO2e', '同学同路拼一辆车', 1, 1, 10),
  new Activity('travel_stairs', 'travel', '爬楼梯代替电梯', '🪜', '层', 0.012, 2,
    '电梯每层约 0.012 kWh 电耗，约合 0.0067 kgCO2e，叠加扶梯空载损耗取整', '一次爬 5 层，顺手把楼梯间灯按灭', 5, 1, 30),

  // ============ 节水节电 ============
  new Activity('energy_light', 'energy', '人走关灯', '💡', '次', 0.035, 2,
    '1 盏 10W 灯多开 4 小时约 0.04 kWh，约 0.022 kgCO2e，按常见 3~5 盏估算', '离开宿舍、教室最后一件事', 1, 1, 20),
  new Activity('energy_ac', 'energy', '空调调高 1℃', '❄️', '次', 0.32, 4,
    '空调每调高 1℃ 约省电 7%~10%，1.5 匹空调 8 小时约省 1kWh，约 0.56 kgCO2e，取均值', '夏天 26℃ 就很舒服了', 1, 1, 6),
  new Activity('energy_standby', 'energy', '拔掉待机插头', '🔌', '次', 0.06, 2,
    '机顶盒、路由器、充电器待机约 5~10W，一天约 0.12~0.24 kWh', '睡觉前把排插开关按灭', 1, 1, 10),
  new Activity('energy_washer', 'energy', '衣物集中洗/手洗', '🧺', '次', 0.35, 3,
    '滚筒洗衣机一次约 0.6~1.0 kWh，集中洗比分散洗省约 40%', '攒够一桶再开洗衣机', 1, 1, 5),
  new Activity('energy_water', 'energy', '洗漱随手关水', '🚿', '次', 0.021, 2,
    '水龙头 1 分钟约 6L 水，自来水制水与输送约 0.3~0.9 kgCO2e/t，取 0.35', '刷牙时把水龙头关上，一次能省 3~6L', 1, 1, 20),
  new Activity('energy_shower', 'energy', '缩短洗澡 5 分钟', '🛁', '次', 0.42, 4,
    '燃气/电热水器加热 5 分钟热水（约 40L）约合 0.4~0.5 kgCO2e', '洗澡放首歌，唱完就出来', 1, 1, 4),
  new Activity('energy_dry', 'energy', '自然晾干代替烘干', '👕', '次', 0.85, 3,
    '烘干机一次约 1.5~2 kWh，约 0.85~1.14 kgCO2e', '晴天晒被子，晚上睡得香', 1, 1, 4),
  new Activity('energy_led', 'energy', '更换节能灯具', '🔆', '只', 2.6, 6,
    'LED 比白炽灯省电 80%，一只 9W LED 年省约 60 kWh，约 34 kgCO2e，按使用 1 个月折算', '宿舍台灯换成 LED', 1, 1, 8),

  // ============ 旧物回收 ============
  new Activity('recycle_paper', 'recycle', '废纸/纸箱回收', '📦', 'kg', 0.87, 3,
    '再生纸相比原生纸浆减排约 0.87 kgCO2e/kg 纸', '快递箱拆平攒起来，一次能卖不少', 2, 1, 50),
  new Activity('recycle_bottle', 'recycle', '塑料瓶回收', '🧴', '个', 0.045, 1,
    '1 个 500ml PET 瓶约 25g，再生减排约 1.8 kgCO2e/kg 塑料', '一瓶一投，回收箱就在楼下', 5, 1, 60),
  new Activity('recycle_clothes', 'recycle', '旧衣物捐赠/回收', '👚', 'kg', 5.5, 8,
    '棉质服装全生命周期约 25 kgCO2e/kg，二手流通可避免新购', '毕业季二手群转给学弟学妹', 3, 1, 30),
  new Activity('recycle_book', 'recycle', '旧书流转', '📚', '本', 1.2, 4,
    '1 本教材约 0.5kg 纸，原生纸约 1.2 kgCO2e/kg', '教材用二手，省钱又减碳', 2, 1, 30),
  new Activity('recycle_digital', 'recycle', '电子废弃物交回收点', '📱', '件', 12.0, 8,
    '手机含贵金属，规范回收相比填埋可显著减排，按整机回收估算', '旧手机别乱扔，正规回收站能回收金银铜', 1, 1, 10),
  new Activity('recycle_secondhand', 'recycle', '二手闲置交易', '🔄', '件', 8.0, 6,
    '1 件新衣物/小家电平均碳足迹约 8~15 kgCO2e，二手流通延寿可避免新购', '闲鱼挂一挂，宿舍清一清', 1, 1, 10),

  // ============ 光盘行动 ============
  new Activity('food_clean', 'food', '光盘一次', '🍽️', '次', 0.35, 2,
    '我国餐饮人均每餐浪费约 93g 食物，食物全生命周期碳排放约 2.5~3.5 kgCO2e/kg', '食堂打饭按量取，不够再添', 1, 1, 6),
  new Activity('food_takeout', 'food', '外卖不加一次性餐具', '🥢', '次', 0.048, 1,
    '1 套一次性餐具（筷+勺+袋）约 20g PP 塑料，约 2.4 kgCO2e/kg', '下单时点一下"无需餐具"', 1, 1, 10),
  new Activity('food_leftover', 'food', '剩菜打包带走', '🍱', '次', 0.5, 3,
    '避免约 200g 食物浪费，按 2.5 kgCO2e/kg 折算', '聚餐吃不完，打包回去当夜宵', 1, 1, 5),
  new Activity('food_veg', 'food', '一餐素食', '🥬', '餐', 1.2, 3,
    '同等热量下，红肉餐碳排放约是植物性餐的 3~5 倍，一餐可减约 1.2 kgCO2e', '每周来两天"轻食日"', 1, 1, 6),
  new Activity('food_local', 'food', '选本地产当季果蔬', '🍅', '次', 0.25, 2,
    '本地当季果蔬可减少冷链与长途运输，平均每餐减约 0.2~0.3 kgCO2e', '去菜市场挑本地菜', 1, 1, 6),

  // ============ 绿色消费 ============
  new Activity('shop_bag', 'shopping', '自带购物袋', '👜', '次', 0.036, 2,
    '1 个塑料袋约 6g 聚乙烯，约 6 kgCO2e/kg 塑料', '背包里常备一个布袋', 1, 1, 10),
  new Activity('shop_cup', 'shopping', '自带水杯/拒绝一次性杯', '🥤', '次', 0.055, 2,
    '1 个一次性纸杯约 12g，含淋膜纸与纸浆减排约 4.5 kgCO2e/kg', '教室、图书馆都带上杯子', 1, 1, 10),
  new Activity('shop_repair', 'shopping', '维修代替换新', '🔧', '次', 15.0, 8,
    '1 件小家电新品约 20~40 kgCO2e，维修延寿可避免一次新购', '充电线、耳机坏了先看看能不能修', 1, 1, 5),
  new Activity('shop_package', 'shopping', '快递盒二次利用', '📭', '个', 0.09, 2,
    '1 个快递纸箱约 0.3kg，重复使用避免一次新纸箱生产', '收纳盒、寄件箱都能用上', 2, 1, 20),

  // ============ 低碳公益 ============
  new Activity('plant_tree', 'plant', '参与植树', '🌳', '棵', 18.0, 20,
    '1 棵树年均固碳约 18 kgCO2e（成年树），按首年计', '学校、社区植树活动别错过', 1, 1, 10),
  new Activity('plant_antforest', 'plant', '线上种树/公益捐步', '🐜', '次', 0.5, 3,
    '线上公益种树可折算真实造林，按单次折算', '步数别浪费，捐出去种树', 1, 1, 5),
  new Activity('plant_volunteer', 'plant', '低碳志愿宣传', '📢', '次', 1.0, 10,
    '科普宣传带动他人减排，按人均带动折算', '团日活动、社区宣传都算', 1, 1, 5)
];

/** 成就徽章（自动达成，不可兑换） */
export const ACHIEVEMENT_BADGES: Badge[] = [
  new Badge('b_first', '碳足迹起点', '🌱', '记录第一条低碳行为，从今天开始算自己的碳账。', 0, 'achievement',
    '记录 1 条低碳行为', 'record', 1),
  new Badge('b_ten', '低碳新手', '🌿', '坚持记了 10 条，已经比大多数人更了解自己的排放。', 0, 'achievement',
    '累计记录 10 条', 'record', 10),
  new Badge('b_fifty', '碳账达人', '🌳', '50 条记录，你的碳账本已经有厚度了。', 0, 'achievement',
    '累计记录 50 条', 'record', 50),
  new Badge('b_10kg', '减碳十公斤', '⚖️', '累计减排 10 kg，相当于少开 50 公里小汽车。', 0, 'achievement',
    '累计减排 10 kgCO2e', 'reduction', 10),
  new Badge('b_50kg', '减碳五十公斤', '🏅', '累计减排 50 kg，一棵树一年的固碳量。', 0, 'achievement',
    '累计减排 50 kgCO2e', 'reduction', 50),
  new Badge('b_200kg', '减碳两百公斤', '🏆', '累计减排 200 kg，比约 11 棵树一年的固碳还多。', 0, 'achievement',
    '累计减排 200 kgCO2e', 'reduction', 200),
  new Badge('b_streak7', '七日不断', '🔥', '连续 7 天记录低碳行为，习惯正在形成。', 0, 'achievement',
    '连续记录 7 天', 'streak', 7),
  new Badge('b_streak30', '月度低碳者', '📅', '连续 30 天，一个月都在为地球省碳。', 0, 'achievement',
    '连续记录 30 天', 'streak', 30),
  new Badge('b_allcat', '六边形战士', '🧭', '六个大类都实践过，低碳生活不留死角。', 0, 'achievement',
    '6 个类别各至少记录 1 条', 'category', 6),
  new Badge('b_night', '夜跑捡碳', '🌙', '在 22 点后还坚持记账，自律的人最酷。', 0, 'achievement',
    '22:00 之后记录 1 条', 'night', 1)
];

/** 可兑换徽章与证书（消耗积分） */
export const REDEEM_BADGES: Badge[] = [
  new Badge('r_bamboo', '青竹徽章', '🎋', '积分兑换的第一枚纪念徽章，象征节节向上。', 100, 'redeem',
    '100 积分兑换', 'redeem', 100),
  new Badge('r_panda', '护熊猫徽章', '🐼', '为山林保护出一份力。', 200, 'redeem',
    '200 积分兑换', 'redeem', 200),
  new Badge('r_earth', '地球守护者', '🌍', '碳积分体系里的中阶荣誉。', 350, 'redeem',
    '350 积分兑换', 'redeem', 350),
  new Badge('c_tree1', '植树证书·一棵', '🌳', '你已用行动换来一棵树的一年固碳量。', 180, 'cert',
    '180 积分兑换', 'redeem', 180),
  new Badge('c_tree5', '植树证书·五棵', '🌲', '五棵树的固碳量，约 90 kgCO2e。', 700, 'cert',
    '700 积分兑换', 'redeem', 700),
  new Badge('c_tree10', '植树证书·十棵', '🌲', '十棵树的固碳量，约 180 kgCO2e，一片小林子正在长成。', 1250, 'cert',
    '1250 积分兑换', 'redeem', 1250),
  new Badge('c_lowcarbon', '低碳生活证书', '🎖️', '坚持记录低碳行为，绿色生活已经成为习惯。', 400, 'cert',
    '400 积分兑换', 'redeem', 400),
  new Badge('c_carbon', '碳中和先锋证书', '🏅', '抵掉一个普通人小半年的生活碳排放。', 1200, 'cert',
    '1200 积分兑换', 'redeem', 1200)
];

/** 日常低碳任务（每天刷新，记录对应类别行为即完成） */
export const DAILY_TASKS: DailyTask[] = [
  new DailyTask('t_walk', '今天走一段路', '🚶', 8, 'travel', 1, '记录任一条绿色出行'),
  new DailyTask('t_energy', '随手关灯关水', '💡', 8, 'energy', 1, '记录任一条节水节电'),
  new DailyTask('t_recycle', '让一件旧物循环', '♻️', 10, 'recycle', 1, '记录任一条旧物回收'),
  new DailyTask('t_food', '做到一次光盘', '🍚', 8, 'food', 1, '记录任一条光盘行动'),
  new DailyTask('t_shop', '少用一次一次性用品', '🛍️', 6, 'shopping', 1, '记录任一条绿色消费'),
  new DailyTask('t_plant', '参与一次低碳公益', '🌱', 15, 'plant', 1, '记录任一条低碳公益')
];

/** 按时段赠送的打卡基础分 */
export const DAY_CHECKIN_POINT = 5;

/**
 * 等级成长表：累计减排量阈值与称号一一对应。
 * 放在数据层，避免 UI（MineTab 的进度条）与业务层各维护一份阈值导致评级不一致。
 */
export const LEVEL_STEPS: number[] = [0, 1, 5, 15, 30, 60, 120, 250, 500, 1000];

export const LEVEL_TITLES: string[] = [
  '碳足迹新手', '低碳见习生', '绿色实践者', '节能小能手', '减碳行动派',
  '低碳达人', '碳中和积极分子', '绿色先锋', '低碳领航员', '碳中和大使'
];
