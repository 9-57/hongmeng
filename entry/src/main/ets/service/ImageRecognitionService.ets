import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AIOutcome, AIRecognitionService } from './AIRecognitionService';

const TAG = 'carbon-vision';

/** 单条识别命中（对应一条内置低碳行为） */
export class RecogTag {
  activityId: string = '';
  activityName: string = '';
  categoryId: string = '';
  icon: string = '';
  /** 该行为的基础环保积分（来自 CarbonData 的 basePoint，与记账时的计算同源） */
  point: number = 0;
}

/**
 * 识别结果。
 *
 * 与模型只交换两个值（hasLowCarbon / activityId），名称、类别、图标、积分
 * 全部按 activityId 从 CarbonData 查出来。所以这里最多只有一个 tag。
 */
export class RecogResult {
  ok: boolean = false;
  /** 失败提示文案 */
  message: string = '';
  tags: RecogTag[] = [];
  /** 是否检测到低碳行为 */
  hasLowCarbon: boolean = false;
}

/**
 * 选图结果。
 * 以前 pickImage() 只返回 string，空串同时表示"用户取消"和"打开相册失败"，
 * 于是真正的错误被静默吞掉，界面上只能看到按钮卡住。这里把两种情况分开。
 */
export class PickOutcome {
  /** 选中的图片 uri；空串表示没拿到图片 */
  uri: string = '';
  /** 用户在系统图库里主动取消，不该弹任何提示 */
  canceled: boolean = false;
  /** 真正的失败原因（非空时由界面层提示用户） */
  reason: string = '';
}

/** openSource() 的返回：解码源 + 需要配套关闭的文件描述符 */
class OpenedSource {
  src: image.ImageSource | null = null;
  fd: number = -1;
}

/**
 * 把错误整理成可读文本。
 * 踩坑：BusinessError 的 code/message 挂在原型上，直接 JSON.stringify(e) 得到的是 "{}"，
 * 日志里等于什么都没打，之前排查图片识别问题时完全看不到真实原因。
 */
export function describeErr(e: BusinessError): string {
  if (e === undefined || e === null) {
    return '未知错误';
  }
  const code: number | undefined = e.code;
  const msg: string | undefined = e.message;
  const prefix = (code === undefined || code === 0) ? '' : `[${code}] `;
  const body = (msg === undefined || msg.length === 0) ? '未提供错误信息' : msg;
  return `${prefix}${body}`;
}

/**
 * 图片低碳行为识别。
 *
 * 唯一引擎：设置里配置的 OpenAI 兼容视觉模型（本地部署的千问 / ollama 等）。
 * 视觉模型直接判定"有没有低碳行为、是哪几条、各自多大把握"，命中即由
 * AutoRecordService 自动落库，用户不需要任何点击。
 *
 * 早期版本在没接模型时用"端侧色彩统计"给候选（绿色占比高就猜植树之类），
 * 那只是演示占位：色彩分布只能说明画面像不像，不构成行为证据，既不准也不能
 * 自动记账。接入本地模型后已整体删除——没有模型就不给结论，界面会引导去设置，
 * 而不是用一张猜出来的候选表糊弄用户。
 */
export class ImageRecognitionService {
  /** 拉起系统图库选择器，返回选中的图片 uri（用户取消返回空串） */
  static async pickImage(): Promise<PickOutcome> {
    const out = new PickOutcome();
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      // 关掉图库左上角的“拍照”入口。该入口依赖系统的相机会话 Ability，
      // 在模拟器/未装相机的设备上点下去会抛 16000001（ability 不存在），
      // 且 picker.select() 的 Promise 不落地——用户看到的就是“点了没反应”。
      // 我们自己已经有拍完再选图的路径，所以这里直接收起这个坑。
      options.isPhotoTakingSupported = false;
      const result = await picker.select(options);
      if (result === undefined || result === null) {
        out.canceled = true;
        return out;
      }
      if (result.photoUris === undefined || result.photoUris.length === 0) {
        out.canceled = true;
        return out;
      }
      const uri = result.photoUris[0];
      if (uri === undefined || uri.length === 0) {
        out.canceled = true;
        return out;
      }
      out.uri = uri;
      hilog.info(0x0000, TAG, 'picked image: %{public}s', uri);
      return out;
    } catch (err) {
      const e = err as BusinessError;
      out.reason = `打开相册失败（${describeErr(e)}）`;
      hilog.error(0x0000, TAG, 'photo picker failed: %{public}s', describeErr(e));
      return out;
    }
  }

  /**
   * 打开图片解码源。
   *
   * 踩坑：图库返回的是 file://media/Photo/... 形态的 uri，直接丢给
   * createImageSource(uri) 在部分设备/模拟器上会报 62980115（uri 无效），
   * 表现就是"选完图没反应"或直接"图片解析失败"。稳妥做法是先 openSync 拿
   * 文件描述符再解码，fd 不可用时再退回 uri 直连。
   */
  private static openSource(uri: string): OpenedSource {
    const out = new OpenedSource();
    try {
      const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      out.fd = f.fd;
      out.src = image.createImageSource(f.fd);
      return out;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(0x0000, TAG, 'open image by fd failed: %{public}s, retry with uri', describeErr(e));
    }
    try {
      out.src = image.createImageSource(uri);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'createImageSource(uri) failed: %{public}s', describeErr(e));
    }
    return out;
  }

  /**
   * 识别一张图片。
   *
   * 只走 AI 判定这一条路：
   *   - 没配模型：直接失败并提示去设置，绝不给猜测结果；
   *   - 模型答复格式不对：如实报错（可重试），不偷偷换别的引擎；
   *   - 连不上 / 超时 / 5xx：如实报错（可重试），同样不降级成猜测。
   */
  static async recognize(uri: string): Promise<RecogResult> {
    if (uri.length === 0) {
      const empty = new RecogResult();
      empty.message = '没有选择图片';
      return empty;
    }

    const cfg = await AIRecognitionService.loadConfig();
    if (!AIRecognitionService.isUsable(cfg)) {
      hilog.warn(0x0000, TAG, 'ai not configured, refuse to guess');
      const off = new RecogResult();
      // 入口判断与这里读的是同一份配置，正常不会走到；走到了也要说清楚
      off.message = '还没开启 AI 识别，无法判定低碳行为。请到「我的 → 个人设置 → AI 图片识别」填写模型接口后重试。';
      return off;
    }

    const ai = await AIRecognitionService.recognize(uri, cfg);
    if (ai.ok) {
      return ImageRecognitionService.fromAI(ai);
    }
    const bad = new RecogResult();
    bad.message = ai.needFallback
      ? `AI 识别暂时不可用（${ai.message}）`
      : ai.message;
    return bad;
  }

  /**
   * 把模型的两个值转成界面可用的结构。
   *
   * 模型只给 activityId，名称/类别/图标/积分全部按 id 从 CarbonData 查，
   * 因此这里最多产出一条 tag；id 不在清单里就当成"没识别出来"并说明原因。
   */
  private static fromAI(ai: AIOutcome): RecogResult {
    const res = new RecogResult();
    res.ok = true;
    res.hasLowCarbon = ai.hasLowCarbon;

    if (!ai.hasLowCarbon) {
      return res;
    }
    if (ai.activityId.length === 0) {
      res.message = '识别到低碳行为，但模型没给出具体是哪一条';
      return res;
    }

    const a = AIRecognitionService.activityOf(ai.activityId);
    if (a === undefined) {
      res.message = `识别到低碳行为，但「${ai.activityId}」不在内置清单里`;
      return res;
    }

    const t = new RecogTag();
    t.activityId = a.id;
    t.activityName = a.name;
    t.categoryId = a.categoryId;
    t.icon = a.icon;
    t.point = a.basePoint;
    res.tags = [t];
    return res;
  }
}
