import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storage } from '../service/StorageService';
import { carbonStore } from '../viewmodel/CarbonStore';
import { notificationService } from '../service/NotificationService';

const TAG = 'carbon-work';

/**
 * WorkScheduler 周期任务：应用不在前台或进程已退出时，系统按 WorkInfo 的
 * repeatCycleTime（10 分钟）拉起本扩展，重新加载 preferences 并推送一条
 * 个性化低碳任务 + 刷新实况窗。
 *
 * 这个扩展运行在独立进程里，所以必须自己初始化 storage / carbonStore，
 * 不能依赖主 UIAbility 的全局单例是否已加载。
 */
export default class CarbonWorkScheduler extends WorkSchedulerExtensionAbility {
  async onWorkStart(work: workScheduler.WorkInfo): Promise<void> {
    try {
      await storage.init(this.context);
      await carbonStore.load();
      const ok = await notificationService.publishPeriodic();
      hilog.info(0x0000, TAG, 'work %{public}d pushed: %{public}s', work.workId, ok ? 'ok' : 'skip');
    } catch (e) {
      hilog.error(0x0000, TAG, 'work start failed: %{public}s', JSON.stringify(e));
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    hilog.info(0x0000, TAG, 'work %{public}d stopped', work.workId);
  }
}
