import { hilog } from '@kit.PerformanceAnalysisKit';
import { auth } from './AuthService';
import { familyService } from './FamilyService';
import { FamilyInvite } from '../model/CarbonModels';
import { pickInviteToAlert } from '../common/InviteAlert';

/**
 * 家庭邀请提醒器：App 在前台时定时问一次云端「有人邀请我吗」，
 * 有新邀请就交给界面弹一个 4 秒的浮层（同意 / 取消 / 点进去手动同意）。
 *
 * 为什么是轮询：家庭那套接口没有推送通道，邀请是写进 family_invites 表的一行；
 * 之前只有点进「我的家庭」才会拉一次，所以坐在首页是永远看不到邀请的。
 *
 * 间隔取 3 秒：一次 family_state RPC（顺带把家庭缓存刷新了），
 * 最差 3 秒能收到，演示时基本感知不到"等"。未登录或已经有家庭时直接跳过，不发请求。
 * 冷启动、从后台回到前台会额外立刻查一次，不用等满一个间隔。
 */
export const INVITE_POLL_MS: number = 3000;

export class FamilyInviteWatcher {
  private timer: number = -1;
  /** 已经弹过的邀请 id（只记在内存里，重启后会再弹一次，算是一种兜底提醒） */
  private shown: string[] = [];
  private running: boolean = false;
  private notify: (inv: FamilyInvite) => void = (inv: FamilyInvite) => {};

  start(notify: (inv: FamilyInvite) => void): void {
    this.notify = notify;
    if (this.timer !== -1) {
      return;
    }
    this.timer = setInterval(() => {
      this.tick();
    }, INVITE_POLL_MS);
    this.tick();
  }

  /** 立刻查一次（冷启动、从后台回到前台时调用，不用等满一个间隔） */
  checkNow(): void {
    this.tick();
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 界面确认已经展示过（不管用户点同意还是取消），避免重复弹同一条 */
  markShown(inviteId: string): void {
    if (inviteId.length > 0 && this.shown.indexOf(inviteId) < 0) {
      this.shown.push(inviteId);
    }
  }

  isShown(inviteId: string): boolean {
    return this.shown.indexOf(inviteId) >= 0;
  }

  async tick(): Promise<void> {
    if (this.running) {
      return;
    }
    if (!auth.isLoggedIn || familyService.hasFamily()) {
      return;
    }
    this.running = true;
    try {
      const err = await familyService.refresh();
      if (err.length > 0) {
        // 断网不打扰用户：进家庭页时会常驻显示错误条，这里静默跳过
        hilog.debug(0x0000, 'carbon-invite', 'poll skipped: %{public}s', err);
        return;
      }
      const inv = pickInviteToAlert(familyService.incoming(), this.shown,
        familyService.hasFamily(), auth.isLoggedIn);
      if (inv !== null) {
        this.markShown(inv.inviteId);
        this.notify(inv);
      }
    } catch (e) {
      hilog.warn(0x0000, 'carbon-invite', 'poll failed');
    } finally {
      this.running = false;
    }
  }
}

export const inviteWatcher = new FamilyInviteWatcher();
