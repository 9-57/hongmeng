import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { storage } from '../service/StorageService';
import { fileService } from '../service/FileService';
import { auth } from '../service/AuthService';
import { cloudAccount } from '../service/CloudAccount';
import { notificationService } from '../service/NotificationService';
import { familyService } from '../service/FamilyService';
import { carbonStore } from '../viewmodel/CarbonStore';
import { bumpDataVersion } from '../common/Utils';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'carbon', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 从状态栏通知点进来：带上要记录的分类
    this.applyPendingCategory(want);
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onCreate');
  }

  /** 通知点击（应用已在前台） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyPendingCategory(want);
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onNewWant');
  }

  /**
   * 解析通知 Want 里的 pendingCategory，写入 AppStorage。
   * Index 监听到后切到「记一笔」，RecordTab 再消费并清空。
   */
  private applyPendingCategory(want: Want): void {
    const params = want.parameters;
    if (params === undefined) {
      return;
    }
    const category = params['pendingCategory'];
    if (typeof category === 'string' && category.length > 0) {
      AppStorage.setOrCreate('pendingCategory', category);
      hilog.info(DOMAIN, 'carbon', 'notification category: %{public}s', category);
    }
  }

  onDestroy(): void {
    notificationService.stopTimer();
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onWindowStageCreate');

    // 关键：不要开 setWindowLayoutFullScreen(true)。
    // 之前开启沉浸式却没有给页面补状态栏高度的内边距，导致标题栏与状态栏的时间/信号图标重叠
    // （真机截图里"碳账本"和"12:50"叠在一起）。这里交回系统安全区布局，并把系统栏配成页面底色。
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(false);
      win.setWindowSystemBarProperties({
        statusBarColor: '#F5F7F6',
        statusBarContentColor: '#1F2A26',
        navigationBarColor: '#FFFFFF',
        navigationBarContentColor: '#1F2A26'
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'carbon', 'system bar setup failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'carbon', 'window setup error: %{public}s', JSON.stringify(err));
    }

    // 必须在 loadContent 之前把 preferences 读完再建页面。
    // onCreate 是异步的、框架不会 await 它：之前把 init/load 放在 onCreate 里，
    // 页面 Index.aboutToAppear 会先执行，CarbonStore.load() 在 storage 未就绪时
    // 读到空串并把 loaded 置为 true，导致"重启后记录全没了"、图表也永远是 0。
    this.bootstrap(windowStage);
  }

  private async bootstrap(windowStage: window.WindowStage): Promise<void> {
    try {
      await storage.init(this.context);
      fileService.init(this.context);
      await carbonStore.load();
      await familyService.load();
      // 恢复上次登录的会话 token（真正的有效性由服务端 RPC 校验）
      await auth.init();
      AppStorage.setOrCreate('carbonVersion', 1);
      hilog.info(DOMAIN, 'carbon', 'store loaded, records: %{public}d', carbonStore.records.length);
    } catch (err) {
      hilog.error(DOMAIN, 'carbon', 'store init failed: %{public}s', JSON.stringify(err));
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'carbon', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'carbon', 'Succeeded in loading the content.');
      // 页面加载完再申请通知权限，确保系统授权弹窗有窗口可挂载。
      // 自动开启：权限 → 实况窗 + 第一条任务 → 10 分钟定时器 + WorkScheduler。
      notificationService.startAuto(this.context).catch((err: Error) => {
        hilog.warn(DOMAIN, 'carbon', 'auto push start failed: %{public}s', err.message);
      });
    });

    // 首屏加载后再静默同步账号数据：网络慢或失败都不影响打开应用
    cloudAccount.restore().catch((err: Error) => {
      hilog.error(DOMAIN, 'carbon', 'account restore failed: %{public}s', err.message);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 回到前台时让各页面重新取数：应用可能在后台跨过零点/跨月，
    // "今日""本周""本月"这类按当前时间计算的统计需要重算（汇总缓存也会按日期自动失效）。
    bumpDataVersion();
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'carbon', '%{public}s', 'Ability onBackground');
  }
}
