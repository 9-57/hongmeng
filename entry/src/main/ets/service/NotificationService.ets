import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Insight } from './InsightService';
import { carbonStore } from '../viewmodel/CarbonStore';
import { fmtKg } from '../common/Utils';

const TAG = 'carbon-notify';
const BUNDLE_NAME = 'com.example.harmony03';
const ENTRY_ABILITY = 'EntryAbility';
const WORK_ABILITY = 'CarbonWorkScheduler';
/** 实况窗固定 id，更新时覆盖同一张卡片 */
const LIVE_NOTIFICATION_ID = 1001;
/** 周期任务通知 id 基数，每次推送换 id，避免不同任务被覆盖 */
const TASK_NOTIFICATION_ID_BASE = 2000;
/** WorkScheduler 的工作 id */
const WORK_ID = 10;

/** 自动推送间隔：10 分钟（应用内定时器） */
export const AUTO_PUSH_INTERVAL_MS = 10 * 60 * 1000;
/** WorkScheduler 的系统最小循环间隔为 20 分钟，作为进程退出后的兜底 */
const WORK_REPEAT_MS = 20 * 60 * 1000;

/**
 * 状态栏个性化推送 + 实况窗 + 周期自动推送。
 *
 * 三条链路：
 * 1. 应用启动时自动申请一次通知权限，成功后立即生成实况窗并推送第一条任务；
 * 2. 应用进程存活时，`setInterval` 每 10 分钟推送一条任务并刷新实况窗；
 * 3. 应用进程不在时，WorkScheduler 每 10 分钟拉起 CarbonWorkScheduler 扩展，
 *    在扩展里重新加载本地数据并推送（无需用户点击、无需应用在前台）。
 */
export class NotificationService {
  private static instance: NotificationService | null = null;
  private slotReady: boolean = false;
  private lastMode: string = 'basic';
  private autoStarted: boolean = false;
  private timerId: number = -1;
  private workScheduled: boolean = false;
  private insightCursor: number = 0;
  private lastTaskId: number = -1;

  static getInstance(): NotificationService {
    if (NotificationService.instance === null) {
      NotificationService.instance = new NotificationService();
    }
    return NotificationService.instance;
  }

  async isEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'isNotificationEnabled failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 申请通知权限；已开启则直接返回 true */
  async ensureEnabled(context: common.UIAbilityContext): Promise<boolean> {
    if (await this.isEnabled()) {
      return true;
    }
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'requestEnableNotification failed: %{public}s', JSON.stringify(e));
    }
    return await this.isEnabled();
  }

  /**
   * 跳系统「通知」设置页。
   *
   * 用户点过"不允许"之后，requestEnableNotification 会一直返回 1600004，
   * 系统也不会再弹授权框——此时唯一出路是让用户去设置里手动打开。
   * 不提供这个入口的话，「开启实况窗」按钮就是死路（真实踩到：
   * 实况窗与状态栏灵动岛都不显示，点按钮只提示"请在系统弹窗中允许通知"）。
   */
  async openSettings(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.openNotificationSettings(context);
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'openNotificationSettings failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private async ensureSlot(): Promise<void> {
    if (this.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (e) {
      hilog.debug(0x0000, TAG, 'addSlot: %{public}s', JSON.stringify(e));
    }
    this.slotReady = true;
  }

  private fallbackInsight(): Insight {
    return new Insight('notify-default', 'task', '🌱', '今天也低碳一点',
      '记录一条低碳行为，让碳账本继续生长。', 'travel', 'travel_walk', '去记录');
  }

  private firstInsight(): Insight {
    const list = carbonStore.insights();
    return list.length > 0 ? list[0] : this.fallbackInsight();
  }

  /** 周期任务轮流使用推荐列表，避免每 10 分钟都是同一句 */
  private nextInsight(): Insight {
    const list = carbonStore.insights();
    if (list.length === 0) {
      return this.fallbackInsight();
    }
    const item = list[this.insightCursor % list.length];
    this.insightCursor += 1;
    return item;
  }

  private async buildWantAgent(categoryId: string): Promise<WantAgent | undefined> {
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: ENTRY_ABILITY,
        parameters: { 'pendingCategory': categoryId }
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 100
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getWantAgent failed: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  /** 只发实况窗；失败返回 false */
  private async publishLive(): Promise<boolean> {
    try {
      await this.ensureSlot();
      const insight = this.firstInsight();
      const s = carbonStore.getSummary();
      const agent = await this.buildWantAgent(insight.categoryId);
      const goal = carbonStore.monthGoal > 0 ? carbonStore.monthGoal : 30;
      const percent = Math.min(100, Math.round(s.monthReduction / goal * 100));
      const hasToday = s.todayReduction > 0;
      const liveRequest: notificationManager.NotificationRequest = {
        id: LIVE_NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            title: '今日碳账本',
            text: hasToday
              ? `已减 ${fmtKg(s.todayReduction)} kg · 本月目标 ${percent}%`
              : `今日待打卡 · 本月 ${fmtKg(s.monthReduction)} kg（${percent}%）`,
            typeCode: 1,
            capsule: {
              title: hasToday ? `${fmtKg(s.todayReduction)} kg` : `${fmtKg(s.monthReduction)} kg`,
              backgroundColor: '#2F9E68'
            },
            progress: {
              maxValue: 100,
              currentValue: percent,
              isPercentage: true
            }
          }
        },
        wantAgent: agent,
        isOngoing: true
      };
      await notificationManager.publish(liveRequest);
      this.lastMode = 'live';
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'live view rejected: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 一条普通的个性化任务通知（可被用户划掉），每次使用新 id */
  private async publishTask(): Promise<boolean> {
    try {
      await this.ensureSlot();
      const insight = this.nextInsight();
      const s = carbonStore.getSummary();
      const agent = await this.buildWantAgent(insight.categoryId);
      const goal = carbonStore.monthGoal > 0 ? carbonStore.monthGoal : 30;
      const percent = Math.min(100, Math.round(s.monthReduction / goal * 100));
      const id = TASK_NOTIFICATION_ID_BASE + (Math.floor(Date.now() / 1000) % 100000);
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: '碳足迹 · 个性化低碳任务',
            text: `${insight.icon} ${insight.title}：${insight.detail}`,
            additionalText: s.todayReduction > 0
              ? `今日已减 ${fmtKg(s.todayReduction)} kg · 本月目标 ${percent}%`
              : `本月 ${fmtKg(s.monthReduction)} kg · 目标 ${percent}%`
          }
        },
        wantAgent: agent,
        isOngoing: false
      };
      // 只保留最新一条周期任务，避免 10 分钟一条把通知中心堆满
      if (this.lastTaskId > 0) {
        try {
          await notificationManager.cancel(this.lastTaskId);
        } catch (e) {
          hilog.debug(0x0000, TAG, 'cancel old task failed: %{public}s', JSON.stringify(e));
        }
      }
      await notificationManager.publish(request);
      this.lastTaskId = id;
      this.lastMode = 'task';
      hilog.info(0x0000, TAG, 'periodic task published: %{public}s', insight.title);
      return true;
    } catch (e) {
      hilog.error(0x0000, TAG, 'publishTask failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 更新实况窗内容（数据变化 / 周期刷新） */
  async updateLiveView(): Promise<boolean> {
    if (!(await this.isEnabled())) {
      return false;
    }
    return await this.publishLive();
  }

  /** 周期推送：刷新实况窗 + 发一条新的个性化任务通知 */
  async publishPeriodic(): Promise<boolean> {
    if (!(await this.isEnabled())) {
      return false;
    }
    const liveOk = await this.publishLive();
    const taskOk = await this.publishTask();
    return liveOk || taskOk;
  }

  /** 启动时清掉上一次进程遗留的旧任务通知，避免多次启动堆叠 */
  private async clearOldNotifications(): Promise<void> {
    try {
      await notificationManager.cancelAll();
    } catch (e) {
      hilog.debug(0x0000, TAG, 'cancelAll failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 应用启动时自动开启：申请权限 → 实况窗 + 第一条任务 → 启动定时器 + WorkScheduler */
  async startAuto(context: common.UIAbilityContext): Promise<void> {
    if (this.autoStarted) {
      return;
    }
    this.autoStarted = true;
    const enabled = await this.ensureEnabled(context);
    if (!enabled) {
      this.autoStarted = false;
      hilog.warn(0x0000, TAG, 'notification disabled, auto push not started');
      return;
    }
    await this.clearOldNotifications();
    await this.publishPeriodic();
    this.startTimer();
    this.scheduleWork().catch((err: Error) => {
      hilog.warn(0x0000, TAG, 'schedule work failed: %{public}s', err.message);
    });
    hilog.info(0x0000, TAG, 'auto push started, interval=%{public}d ms', AUTO_PUSH_INTERVAL_MS);
  }

  private startTimer(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval(() => {
      this.publishPeriodic().catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'periodic push failed: %{public}s', err.message);
      });
    }, AUTO_PUSH_INTERVAL_MS);
  }

  stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 注册系统周期任务：应用不在前台/进程退出后仍能拉起扩展推送 */
  private async scheduleWork(): Promise<void> {
    if (this.workScheduled) {
      return;
    }
    try {
      // 重复调用 startWork 会报 9700005；先查已有任务，已注册就直接复用
      const works = await workScheduler.obtainAllWorks();
      for (const item of works) {
        if (item.workId === WORK_ID) {
          this.workScheduled = true;
          hilog.info(0x0000, TAG, 'work scheduler already registered');
          return;
        }
      }
      const work: workScheduler.WorkInfo = {
        workId: WORK_ID,
        bundleName: BUNDLE_NAME,
        abilityName: WORK_ABILITY,
        isPersisted: true,
        isRepeat: true,
        repeatCycleTime: WORK_REPEAT_MS
      };
      workScheduler.startWork(work);
      this.workScheduled = true;
      hilog.info(0x0000, TAG, 'work scheduler registered, repeat=%{public}d ms', WORK_REPEAT_MS);
    } catch (e) {
      hilog.error(0x0000, TAG, 'work scheduler failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 「我的」手动刷新实况窗；未授权时会先申请，成功后也把自动推送开起来 */
  async refreshLiveView(context: common.UIAbilityContext): Promise<boolean> {
    const enabled = await this.ensureEnabled(context);
    if (!enabled) {
      return false;
    }
    if (!this.autoStarted) {
      this.autoStarted = true;
      this.startTimer();
      this.scheduleWork().catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'schedule work failed: %{public}s', err.message);
      });
    }
    return await this.publishLive();
  }

  get lastPublishMode(): string {
    return this.lastMode;
  }
}

export const notificationService = NotificationService.getInstance();
