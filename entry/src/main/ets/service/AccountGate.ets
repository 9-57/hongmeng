import { router } from '@kit.ArkUI';
import { auth } from './AuthService';
import { DialogUtil } from '../common/DialogUtil';
import { Palette } from '../common/Theme';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 账号守卫：碳积分、减排记录、任务奖励都属于账号，不是本机数据。
 * 未登录时任何“会改动账号数据”的动作都要先弹登录引导，不能静默加分。
 * 返回 true 表示已登录、可以继续；false 表示用户被拦下（已弹提示）。
 */
export async function requireLogin(ctx: UIContext, action: string): Promise<boolean> {
  if (auth.isLoggedIn) {
    return true;
  }
  const ok = await DialogUtil.confirm(ctx, `${action}需要登录`,
    '碳积分和减排记录都跟着账号走，登录后这一步才会被记住。', '去登录', Palette.primary);
  hilog.info(0x0000, 'carbon-gate', 'guard %{public}s ok=%{public}s', action, `${ok}`);
  if (ok) {
    router.pushUrl({ url: 'pages/Login' }).catch((e: Error) => {
      hilog.error(0x0000, 'carbon-gate', 'push Login failed: %{public}s', e.message);
    });
  }
  return false;
}