import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 轻提示与确认弹窗工具。
 * 说明：全局 promptAction 的 showToast/showDialog 自 API 18 起已废弃，
 * 官方推荐通过 UIContext 的 PromptAction 实例调用，避免 UI 上下文歧义。
 * 这里统一从组件自身的 UIContext 取，保证弹窗挂在当前页面窗口上。
 */
export class DialogUtil {
  /** 轻提示 */
  static toast(ui: UIContext, msg: string): void {
    try {
      ui.getPromptAction().openToast({ message: msg, duration: 2000 }).catch((err: Error) => {
        // 页面销毁时 toast 会失败，记录日志但不打扰用户
        hilog.debug(0x0000, 'carbon-ui', 'toast failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.warn(0x0000, 'carbon-ui', 'toast threw: %{public}s', JSON.stringify(e));
    }
  }

  /** 确认弹窗，返回是否点击了确认（第二个按钮） */
  static async confirm(ui: UIContext, title: string, message: string, okText: string,
    okColor: string): Promise<boolean> {
    try {
      const res = await ui.getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#6B7773' },
          { text: okText, color: okColor }
        ]
      });
      return res.index === 1;
    } catch (e) {
      hilog.warn(0x0000, 'carbon-ui', 'confirm dialog failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}
