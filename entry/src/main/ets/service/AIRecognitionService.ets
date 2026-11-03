import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Activity } from '../model/CarbonModels';
import { ACTIVITIES } from '../model/CarbonData';
import { storage } from './StorageService';

const TAG = 'carbon-ai';

/** 配置存储键 */
const AI_KEY = 'ai_config_json';

/** 送进模型的图片长边上限。本地小模型上下文只有 4096，图太大会直接超限 */
const MAX_SIDE = 1024;
/** 超限时的降级尺寸 */
const MAX_SIDE_RETRY = 640;

/**
 * AI 识别配置。
 *
 * 图片识别现在只有这一条路径（端侧色彩占位已删除）：默认关闭，用户填好本地
 * 部署的模型地址与名称并打开开关后才会工作；没开时识别入口会直接说明"未启用"，
 * 不会用猜测结果糊弄用户。
 */
export class AIConfig {
  enabled: boolean = false;
  /** OpenAI 兼容地址，末尾不要带 /chat/completions */
  baseUrl: string = '';
  apiKey: string = '';
  model: string = '';
}

/** 连通性自检结果 */
export class ProbeResult {
  ok: boolean = false;
  /** 可直接展示给用户的结论 */
  message: string = '';
  /** 建议替换的地址（本机回环自动改成宿主别名时给出），空串表示不用改 */
  suggest: string = '';
}

/**
 * 一次 AI 识别的结果。
 *
 * 与模型约定只回两个值，见 buildRecogPrompt：
 *   hasLowCarbon（有没有低碳行为）+ activityId（具体是哪一条）。
 * 类别、名称、单位、减排因子、积分全部由本地 CarbonData 查出来，不让模型复述，
 * 既省 token 又避免它把行为名写错、把积分算错。
 */
export class AIOutcome {
  /** 调用成功并解析出结果（不代表图里一定有低碳行为） */
  ok: boolean = false;
  /** 是否检测到低碳行为 */
  hasLowCarbon: boolean = false;
  /** 命中的行为 id（CarbonData 里的 ACTIVITIES[].id），未命中为空串 */
  activityId: string = '';
  /** 失败原因，可直接展示 */
  message: string = '';
  /**
   * 是否属于"服务本身不可用"（网络不通 / 超时 / 5xx / 接口报错），
   * 用来区分"该重试"和"模型答了但格式不对"。
   */
  needFallback: boolean = false;
  /** 原始返回片段，便于排查 */
  raw: string = '';
}

/**
 * 响应结构。
 * 全部字段声明为可选：JSON.parse 得到的是普通对象，模型少给字段时
 * 直接读 .length / .message 会抛异常，必须显式判空。
 */
class AIErrorBody {
  message?: string;
  type?: string;
  code?: string;
}

class AIRespMessage {
  content?: string;
  reasoning?: string;
  reasoning_content?: string;
}

class AIChoice {
  message?: AIRespMessage;
  finish_reason?: string;
}

class AIResponse {
  choices?: AIChoice[];
  error?: AIErrorBody;
}

/** JSON.parse 出来的判定字段：只认这两个值 */
class AIFields {
  hasLowCarbon?: boolean | string;
  activityId?: string;
  /** 兼容旧格式（模型仍按老提示词给出数组时，取第一条） */
  activities?: AIActivityField[];
}

class AIActivityField {
  activityId?: string;
}

function asText(v: string | undefined | null, def: string): string {
  return typeof v === 'string' ? v : def;
}

/** "null" / "none" 这类占位值统一当空串 */
function cleanActivityId(v: string | undefined | null): string {
  const id = asText(v, '').trim();
  if (id === 'null' || id === 'NULL' || id === 'None' || id === 'none' ||
    id === 'undefined' || id === '') {
    return '';
  }
  return id;
}

/** 本地/局域网地址不需要 API Key（Ollama 之类） */
function isLocalEndpoint(baseUrl: string): boolean {
  const u = baseUrl.toLowerCase();
  return u.indexOf('localhost') >= 0 || u.indexOf('127.0.0.1') >= 0 ||
    u.indexOf('0.0.0.0') >= 0 || u.indexOf('192.168.') >= 0 || u.indexOf('10.') >= 0;
}

/**
 * 把模型"在思考过程里顺手写出来的 JSON"捞出来当结论用。
 *
 * 思考型小模型（qwen3-vl 系列）经常把一整段推理塞进 content：先复述任务、
 * 再分析画面，最后才写结论 JSON，而且常常因为输出额度被思考吃光、末尾直接
 * 截断，于是外面看起来就是"格式不对"。这类回复里**已经有结论**时丢掉它
 * 太可惜——只要抠出来的 JSON 带合法 activityId，或者明确写了
 * hasLowCarbon:false，就采信它，并记日志，方便事后判断准确率。
 */
function salvageFromThinking(text: string): AIOutcome | null {
  if (text.indexOf('"hasLowCarbon"') < 0 && text.indexOf('\'hasLowCarbon\'') < 0) {
    return null;
  }
  // 1) 能直接解析出的结论对象（任意位置出现的第一段合法对象）
  const direct = parseJsonObjects(text);
  for (const o of direct) {
    const out = outcomeFromFields(o);
    if (out !== null) {
      hilog.info(0x0000, TAG, 'salvaged complete json from thinking');
      return out;
    }
  }
  // 2) 被截断的结论：至少把 hasLowCarbon 与 activities 里已写完的条目挑出来
  const out = salvageActivitiesLoosely(text);
  if (out !== null) {
    hilog.info(0x0000, TAG, 'salvaged truncated json from thinking');
  }
  return out;
}

/** 从文本里逐个尝试解析 {} 片段（从每个 { 起找最近的能配平的 }） */
function parseJsonObjects(text: string): AIFields[] {
  const list: AIFields[] = [];
  let from = 0;
  while (from < text.length) {
    const start = text.indexOf('{', from);
    if (start < 0) {
      break;
    }
    let depth = 0;
    let end = -1;
    let inStr = false;
    for (let i = start; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === '"' && text.charAt(i - 1) !== '\\') {
        inStr = !inStr;
      }
      if (inStr) {
        continue;
      }
      if (ch === '{') {
        depth += 1;
      } else if (ch === '}') {
        depth -= 1;
        if (depth === 0) {
          end = i;
          break;
        }
      }
    }
    if (end > start) {
      try {
        const o = JSON.parse(text.substring(start, end + 1)) as AIFields;
        if (o !== null && o !== undefined && (o.hasLowCarbon !== undefined || o.activities !== undefined)) {
          list.push(o);
        }
      } catch (e) {
        // 不是合法 JSON 就跳过
      }
      from = end + 1;
    } else {
      from = start + 1;
    }
  }
  return list;
}

/** 字段对象 → 结论；没有有效信息返回 null */
function outcomeFromFields(o: AIFields): AIOutcome | null {
  const has = o.hasLowCarbon;
  let id = cleanActivityId(o.activityId);
  if (id.length === 0 && o.activities !== undefined && o.activities !== null && Array.isArray(o.activities)) {
    for (const item of o.activities) {
      if (item === undefined || item === null) {
        continue;
      }
      id = cleanActivityId(item.activityId);
      if (id.length > 0) {
        break;
      }
    }
  }
  // 既没行为也没明确否定，不算有效结论
  if (id.length === 0 && has !== true && has !== false && has !== 'true' && has !== 'false') {
    return null;
  }
  const p = new AIOutcome();
  p.ok = true;
  p.activityId = id;
  p.hasLowCarbon = id.length > 0 || has === true || has === 'true';
  return p;
}

/** 截断/口胡内容：只要能看到合法的 activityId 或明确的 false 就采信 */
function salvageActivitiesLoosely(text: string): AIOutcome | null {
  let id = '';
  const m = text.match(/"activityId"\s*:\s*"([A-Za-z0-9_\-]+)"/);
  if (m !== null) {
    id = cleanActivityId(m[1]);
  }
  const says = text.match(/hasLowCarbon\D{0,4}(true|false)/i);
  if (id.length === 0) {
    if (says !== null && says[1].toLowerCase() === 'false') {
      const p = new AIOutcome();
      p.ok = true;
      p.hasLowCarbon = false;
      return p;
    }
    return null;
  }
  const p = new AIOutcome();
  p.ok = true;
  p.activityId = id;
  p.hasLowCarbon = true;
  return p;
}

/**
 * 生成识别提示词。
 *
 * 与模型的约定刻意压到最小：**只回两个值**
 *   hasLowCarbon —— 画面里有没有低碳行为
 *   activityId   —— 如果有，具体是哪一条（必须是清单里的 id）
 * 类别、单位、减排因子、积分都由本地按 CarbonData 查，模型不复述、不计算，
 * 既省 token、又避免它把行为名或分数写错；对 2B/4B 这类小模型也更容易照做。
 *
 * 清单直接遍历 ACTIVITIES，所以永远和 CarbonData.ets 一致，
 * 不会出现"提示词里写了一版、行为库改了另一版"这种对不上的情况。
 */
export function buildRecogPrompt(strict: boolean = false): string {
  const lines: string[] = [];
  for (const a of ACTIVITIES) {
    lines.push(`${a.id}：${a.name}（${a.categoryId} 类）`);
  }
  const tail: string[] = strict
    ? [
        '',
        '重要：上一次你没有按格式回答。这一次只允许输出一个 JSON 对象，',
        '第一个字符必须是 {，最后一个字符必须是 }，不要写任何解释、不要代码块。',
        '不要输出 confidence、evidence、activities 这些字段，只输出 hasLowCarbon 和 activityId。'
      ]
    : [];
  return [
    '你是低碳行为识别器。看图片，从下面清单里挑出画面中【明确可见】的一条低碳行为。',
    '',
    '清单（id：名称（类别））：',
    lines.join('\n'),
    '',
    '判定规则：',
    '1. 画面里能直接看到证据才算，例如：有人骑车、坐公交地铁、走楼梯、吃完的空餐盘、分类回收的瓶子纸箱、自带水杯布袋、旧衣回收箱、植树、打包盒、不用一次性餐具、关着的灯、晾衣服、修东西。',
    '2. 看不到上述任何行为（风景、人像、宠物、空房间、文字截图、普通食物摆盘），hasLowCarbon 就是 false，activityId 留空字符串。',
    '3. 只看"是否发生"，不要猜数量、不要猜分数；有多个行为时只选最明确的一条。',
    '4. activityId 必须原样取自上面的清单，不要自造、不要翻译、不要写成中文名。',
    '5. 只输出一个 JSON 对象，第一个字符是 {，最后一个字符是 }，不要解释、不要 markdown 代码块。',
    '',
    '输出格式（只有两个字段）：',
    '{"hasLowCarbon":true,"activityId":"travel_bike"}',
    '{"hasLowCarbon":false,"activityId":""}',
    ...tail
  ].join('\n');
}

export class AIRecognitionService {
  /** 读配置；任何异常都退化成"未启用"，不影响原有识别 */
  static async loadConfig(): Promise<AIConfig> {
    const cfg = new AIConfig();
    let raw = '';
    try {
      raw = await storage.readString(AI_KEY, '');
    } catch (e) {
      return cfg;
    }
    if (raw.length === 0) {
      return cfg;
    }
    try {
      const o = JSON.parse(raw) as AIConfig;
      if (o === null || o === undefined) {
        return cfg;
      }
      cfg.enabled = o.enabled === true;
      cfg.baseUrl = asText(o.baseUrl, '');
      cfg.apiKey = asText(o.apiKey, '');
      cfg.model = asText(o.model, '');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'ai config parse failed');
    }
    return cfg;
  }

  static async saveConfig(cfg: AIConfig): Promise<void> {
    try {
      await storage.writeString(AI_KEY, JSON.stringify(cfg));
    } catch (e) {
      hilog.error(0x0000, TAG, 'save ai config failed');
    }
  }

  /** 配置是否可用（启用 + 地址模型齐全 + 非本地时要有 Key） */
  static isUsable(cfg: AIConfig): boolean {
    if (!cfg.enabled) {
      return false;
    }
    if (cfg.baseUrl.length === 0 || cfg.model.length === 0) {
      return false;
    }
    if (isLocalEndpoint(cfg.baseUrl)) {
      return true;
    }
    return cfg.apiKey.length > 0;
  }

  /** 把图片 uri 压到指定长边并编码成 JPEG 的 base64 */
  private static async encode(uri: string, maxSide: number): Promise<string> {
    let src: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    let fd: number = -1;
    try {
      try {
        const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        fd = f.fd;
        src = image.createImageSource(f.fd);
      } catch (e) {
        src = image.createImageSource(uri);
      }
      if (src === null) {
        return '';
      }
      const info = await src.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;
      if (w <= 0 || h <= 0) {
        return '';
      }
      const scale = Math.min(1, maxSide / Math.max(w, h));
      const tw = Math.max(1, Math.round(w * scale));
      const th = Math.max(1, Math.round(h * scale));
      const opt: image.DecodingOptions = {
        desiredSize: { width: tw, height: th },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      pixels = await src.createPixelMap(opt);
      const packer = image.createImagePacker();
      const packOpt: image.PackingOption = { format: 'image/jpeg', quality: 88 };
      const buf = await packer.packToData(pixels, packOpt);
      await packer.release();
      const helper = new util.Base64Helper();
      return helper.encodeToStringSync(new Uint8Array(buf));
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'encode failed: %{public}s', e.message);
      return '';
    } finally {
      if (pixels !== null) {
        try {
          await pixels.release();
        } catch (e) {
          // 释放失败不影响主流程
        }
      }
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
          // 同上
        }
      }
      if (fd !== -1) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 同上
        }
      }
    }
  }

  /** 从模型回复里抠出 JSON（兼容 ```json 围栏、前后废话、尾逗号） */
  private static extractJson(text: string): string {
    let body = text.replace(/```[a-zA-Z]*/g, '').replace(/```/g, '');
    const start = body.indexOf('{');
    const end = body.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return '';
    }
    body = body.substring(start, end + 1);
    body = body.replace(/,\s*}/g, '}').replace(/,\s*]/g, ']');
    body = body.replace(/\u201c/g, '"').replace(/\u201d/g, '"');
    return body;
  }

  /**
   * 从"不是标准 JSON"的回复里抠关键字段。
   *
   * 小模型常见毛病：JSON 前后加解释、括号配错、忘了引号。整段丢掉太可惜，
   * 只要还能看到 hasLowCarbon:true/false 与 activityId 就能给出结论。
   * 注意：只有真的抠到合法 activityId 才算命中——绝不能凭 hasLowCarbon:true
   * 就给用户加分。抠不到返回 null。
   */
  private static salvage(text: string): AIOutcome | null {
    const bm = text.match(/hasLowCarbon\D{0,4}(true|false)/i);
    if (bm === null) {
      return null;
    }
    const out = new AIOutcome();
    out.ok = true;
    const im = text.match(/activityId\D{0,4}"?([A-Za-z0-9_\-]+)"?/);
    if (im !== null) {
      out.activityId = cleanActivityId(im[1]);
    }
    out.hasLowCarbon = out.activityId.length > 0;
    if (!out.hasLowCarbon && bm[1].toLowerCase() === 'false') {
      out.hasLowCarbon = false;
    } else if (!out.hasLowCarbon) {
      // 说 true 却给不出合法 id：按"没识别出来"处理
      return null;
    }
    hilog.info(0x0000, TAG, 'salvaged from malformed reply');
    return out;
  }

  /** 把一次 HTTP 响应解析成结果 */
  private static parse(ok: boolean, status: number, text: string): AIOutcome {
    const out = new AIOutcome();
    out.raw = text.length > 400 ? text.substring(0, 400) : text;

    if (!ok) {
      out.message = `模型接口返回 ${status}`;
      out.needFallback = status === 0 || status >= 500;
      return out;
    }

    let resp: AIResponse | null = null;
    try {
      resp = JSON.parse(text) as AIResponse;
    } catch (e) {
      out.message = '模型返回的不是 JSON';
      return out;
    }
    if (resp === null || resp === undefined) {
      out.message = '模型返回为空';
      return out;
    }

    const errBody = resp.error;
    if (errBody !== undefined && errBody !== null && asText(errBody.message, '').length > 0) {
      out.message = asText(errBody.message, '');
      out.needFallback = true;
      return out;
    }

    const choices = resp.choices;
    if (choices === undefined || choices === null || choices.length === 0) {
      out.message = '模型没有返回候选结果';
      return out;
    }
    const first = choices[0];
    if (first === undefined || first === null) {
      out.message = '模型返回结构异常';
      return out;
    }
    const msg = first.message;
    if (msg === undefined || msg === null) {
      out.message = '模型返回结构异常';
      return out;
    }

    // 思考型模型正文可能为空，内容全在 reasoning 里
    const content = asText(msg.content, '');
    const spoken = content.length > 0 ? content : asText(msg.reasoning, '');
    if (spoken.length === 0) {
      // 正文和思考都空：多半是 max_tokens 被思考吃光了，属于"该重试"而不是
      // "模型乱答"。给出可操作的原因，并带上 finish_reason 便于排查。
      const fr = asText(first.finish_reason, '');
      out.message = fr === 'length'
        ? '模型把输出额度用在了思考上，没来得及给出结论'
        : '模型返回了空内容';
      out.needFallback = true;
      return out;
    }
    const json = AIRecognitionService.extractJson(spoken);
    if (json.length === 0) {
      // 兜底一：思考型模型常把推理和结论一起写进正文，末尾还被截断。
      // 先尝试从思考文本里捞出结论 JSON（带合法 activityId 才算数）。
      const fromThinking = salvageFromThinking(spoken);
      if (fromThinking !== null) {
        return fromThinking;
      }
      const salvaged = AIRecognitionService.salvage(spoken);
      if (salvaged !== null) {
        return salvaged;
      }
      // 兜底二：它明确说了画面里没有低碳行为，就当 false。绝不从口胡里
      // 反推"有某行为"，那会给用户加虚假积分。
      const t = spoken.replace(/\s+/g, '');
      const saysNo = t.indexOf('没有低碳') >= 0 || t.indexOf('未发现低碳') >= 0 ||
        t.indexOf('无低碳行为') >= 0 || t.indexOf('不存在低碳') >= 0 ||
        t.indexOf('没有明显') >= 0;
      if (saysNo) {
        out.ok = true;
        out.hasLowCarbon = false;
        out.activityId = '';
        return out;
      }
      out.message = '模型没有按要求的 JSON 格式返回';
      return out;
    }

    try {
      const o = JSON.parse(json) as AIFields;
      const has = o.hasLowCarbon;
      let id = cleanActivityId(o.activityId);
      // 兼容旧提示词的数组格式：只取第一条
      if (id.length === 0 && o.activities !== undefined && o.activities !== null &&
        Array.isArray(o.activities)) {
        for (const item of o.activities) {
          if (item === undefined || item === null) {
            continue;
          }
          id = cleanActivityId(item.activityId);
          if (id.length > 0) {
            break;
          }
        }
      }
      out.activityId = id;
      // 给出合法 id 就算有；否则采信模型的布尔值。防止"说了 true 却没给 id"
      // 被当成命中，也防止"写了行为却把 hasLowCarbon 写成 false"被漏掉。
      out.hasLowCarbon = id.length > 0 || has === true || has === 'true';
      out.ok = true;
      return out;
    } catch (e) {
      out.message = '模型返回的 JSON 无法解析';
      return out;
    }
  }

  /** 发一次请求 */
  private static async post(cfg: AIConfig, body: string): Promise<AIOutcome> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json' };
      if (cfg.apiKey.length > 0) {
        header['Authorization'] = `Bearer ${cfg.apiKey}`;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        // 思考型小模型（qwen3-vl:2b/4b）在这个提示词下往往要 20~90 秒才出结论：
        // 推理 20~40 秒，再重试一次就是双倍。90 秒会把"慢"误报成"连不上"，
        // 用户看到的是"AI 不可用"——实测在 4b 上真实踩到过。
        readTimeout: 180000
      };
      const url = `${cfg.baseUrl.replace(/\/+$/, '')}/chat/completions`;
      const resp = await request.request(url, options);
      const text = typeof resp.result === 'string' ? resp.result as string : '';
      const ok = resp.responseCode >= 200 && resp.responseCode < 300;
      return AIRecognitionService.parse(ok, resp.responseCode, text);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, TAG, 'post failed: %{public}s', e.message);
      const out = new AIOutcome();
      const msg = asText(e.message, '');
      // 超时和"根本没有网络"是两回事：超时说明地址是通的，只是模型太慢
      out.message = msg.indexOf('imeout') >= 0 || msg.indexOf('超时') >= 0
        ? '模型响应超时（本地大模型单次可能要一两分钟）'
        : '连不上识别服务，请检查网络或地址';
      out.needFallback = true;
      return out;
    } finally {
      request.destroy();
    }
  }

  /**
   * 探一次 /models，只为了把"连不上"的模糊提示换成能定位的事实。
   * 成功返回空串，失败返回人话原因。
   */
  private static async probeUrl(url: string, apiKey: string): Promise<string> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = {};
      if (apiKey.length > 0) {
        header['Authorization'] = `Bearer ${apiKey}`;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000
      };
      const resp = await request.request(url, options);
      const code = resp.responseCode;
      if (code >= 200 && code < 300) {
        return '';
      }
      if (code === 401 || code === 403) {
        return `Key 无效或没有权限（HTTP ${code}）`;
      }
      if (code === 404) {
        return '地址不对：/models 不存在，Base URL 应形如 http://10.0.2.2:11434/v1';
      }
      return `服务返回 HTTP ${code}`;
    } catch (err) {
      const e = err as BusinessError;
      const m = e.message === undefined ? '' : e.message;
      return `连不上 ${url}（${m.length > 0 ? m : '网络不可达'}）`;
    } finally {
      request.destroy();
    }
  }

  /**
   * 连通性自检。
   *
   * 除了如实报告失败原因，还会处理一个高频坑：模拟器/真机里的 127.0.0.1
   * 指的是手机自己，不是你的电脑。检测到地址写的是本机回环时，会按候选顺序
   * 再试两次（宿主别名同端口、宿主别名 + Ollama 默认 11434），通了就把
   * 地址换成能通的那个。
   */
  static async probe(baseUrl: string, apiKey: string): Promise<ProbeResult> {
    const out = new ProbeResult();
    const base = baseUrl.trim().replace(/\/+$/, '');
    if (base.length === 0) {
      out.message = '先填接口地址';
      return out;
    }

    const first = await AIRecognitionService.probeUrl(`${base}/models`, apiKey);
    if (first.length === 0) {
      out.ok = true;
      out.message = '连接正常，模型列表可读';
      return out;
    }

    // 本机回环 → 换成模拟器访问宿主用的 10.0.2.2 再试
    let host = '';
    if (base.indexOf('://127.0.0.1') >= 0) {
      host = '127.0.0.1';
    } else if (base.indexOf('://localhost') >= 0) {
      host = 'localhost';
    }

    if (host.length > 0) {
      const candidates: string[] = [];
      const samePort = base.replace(`://${host}`, '://10.0.2.2');
      candidates.push(samePort);

      // 端口写错（比如 fport 的 8080）时，再试 Ollama 的默认 11434
      const proto = base.substring(0, base.indexOf('://'));
      const rest = base.substring(base.indexOf('://') + 3);
      const slash = rest.indexOf('/');
      const pathPart = slash >= 0 ? rest.substring(slash) : '';
      const withDefaultPort = `${proto}://10.0.2.2:11434${pathPart}`;
      if (withDefaultPort !== samePort) {
        candidates.push(withDefaultPort);
      }

      for (const c of candidates) {
        const r = await AIRecognitionService.probeUrl(`${c}/models`, apiKey);
        if (r.length === 0) {
          out.ok = true;
          out.suggest = c;
          out.message = `已换成 ${c}（手机里的 127.0.0.1 是它自己）`;
          return out;
        }
      }
    }

    out.message = first;
    return out;
  }

  /**
   * 识别一张图片。
   * cfg 由调用方传入，避免每次识别都读一遍 preferences。
   */
  static async recognize(uri: string, cfg: AIConfig): Promise<AIOutcome> {
    const first = await AIRecognitionService.tryOnce(uri, cfg, MAX_SIDE);
    // 上下文超限：压得更小再试一次
    if (!first.ok && !first.needFallback && AIRecognitionService.isContextError(first.message)) {
      hilog.info(0x0000, TAG, 'context exceeded, retry with smaller image');
      return await AIRecognitionService.tryOnce(uri, cfg, MAX_SIDE_RETRY);
    }
    // 格式没对上：这是小模型最常见的问题，把要求说得更死再要一次。
    // 只重试一次，用户不用等太久，也避免把"模型就是不听话"拖成无限等待。
    if (!first.ok && !first.needFallback && AIRecognitionService.isFormatError(first.message)) {
      hilog.info(0x0000, TAG, 'format mismatch, retry with stricter prompt');
      const again = await AIRecognitionService.tryOnce(uri, cfg, MAX_SIDE, true);
      if (again.ok) {
        return again;
      }
      const out = new AIOutcome();
      out.message = `模型没有按要求返回结果（重试一次仍失败：${again.message}）`;
      hilog.warn(0x0000, TAG, 'format failed, reply head: %{public}s', again.raw);
      return out;
    }
    return first;
  }

  /** 模型答复了但格式不对（不是网络问题，也不该悄悄回退） */
  private static isFormatError(msg: string): boolean {
    return msg.indexOf('JSON') >= 0 || msg.indexOf('格式') >= 0;
  }

  private static isContextError(msg: string): boolean {
    const m = msg.toLowerCase();
    return m.indexOf('context') >= 0 || m.indexOf('too many tokens') >= 0 || m.indexOf('too long') >= 0;
  }

  private static async tryOnce(uri: string, cfg: AIConfig, maxSide: number, strict: boolean = false): Promise<AIOutcome> {
    const b64 = await AIRecognitionService.encode(uri, maxSide);
    if (b64.length === 0) {
      const out = new AIOutcome();
      out.message = '图片处理失败';
      out.needFallback = true;
      return out;
    }
    const prompt = JSON.stringify(buildRecogPrompt(strict));
    // 思考型小模型（qwen3-vl 这类）会先把推理写进 reasoning，正文几乎不剩字。
    // 实测 qwen3-vl:4b 在 1100 token 下会把预算全花在思考上，正文为空 →
    // 被判成"没有按 JSON 返回"，于是重试、再失败。重试时给足预算。
    const maxTokens = strict ? 4000 : 2600;
    // reasoning_effort 是 Ollama / vLLM 支持的非标准参数：能省思考就省，
    // 不支持的网关会忽略它，不影响兼容性。
    const body = `{"model":${JSON.stringify(cfg.model)},"stream":false,"temperature":0.1,` +
      `"max_tokens":${maxTokens},"reasoning_effort":"low",` +
      `"messages":[{"role":"system","content":${prompt}},` +
      `{"role":"user","content":[{"type":"text","text":"识别这张图片中的低碳行为。"},` +
      `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,${b64}"}}]}]}`;
    return await AIRecognitionService.post(cfg, body);
  }

  /** 按行为 id 找内置行为，用于取名称/图标/积分 */
  static activityOf(id: string): Activity | undefined {
    for (const a of ACTIVITIES) {
      if (a.id === id) {
        return a;
      }
    }
    return undefined;
  }
}
