import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'carbon-share';

/** 分享结果：决定了 UI 层该提示什么文案 */
export enum ShareOutcome {
  /** 系统分享面板已弹出 */
  PANEL = 0,
  /** 面板不可用，已降级为复制到剪贴板 */
  CLIPBOARD = 1,
  /** 剪贴板也失败 */
  FAILED = 2
}

/**
 * 成果分享服务。
 * 主路径调用系统分享面板（ShareKit），把文本卡片直接投递到聊天/备忘录等应用；
 * 若设备不支持该系统能力（例如纯 OpenHarmony 镜像），自动降级为剪贴板，
 * 保证"分享"按钮在任何设备上都不会静默失败，也不需要申请任何权限。
 */
export class ShareService {
  /** 复制纯文本到系统剪贴板 */
  static async copyText(text: string): Promise<boolean> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (e) {
      hilog.error(0x0000, TAG, 'copy to pasteboard failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 唤起系统分享面板分享一段文本；失败时降级为复制到剪贴板 */
  static async shareText(ui: UIContext, text: string): Promise<ShareOutcome> {
    if (text.length === 0) {
      return ShareOutcome.FAILED;
    }
    const host = ui.getHostContext();
    if (host !== undefined) {
      try {
        const record: systemShare.SharedRecord = {
          utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
          content: text,
          title: '我的低碳碳账本'
        };
        const controller = new systemShare.ShareController(new systemShare.SharedData(record));
        const options: systemShare.ShareControllerOptions = {
          previewMode: systemShare.SharePreviewMode.DETAIL
        };
        await controller.show(host as common.UIAbilityContext, options);
        return ShareOutcome.PANEL;
      } catch (e) {
        // 能力缺失（设备不带该服务）或用户环境异常，走剪贴板兜底
        hilog.warn(0x0000, TAG, 'system share unavailable, fallback to pasteboard: %{public}s',
          JSON.stringify(e));
      }
    }
    const ok = await ShareService.copyText(text);
    return ok ? ShareOutcome.CLIPBOARD : ShareOutcome.FAILED;
  }
}
