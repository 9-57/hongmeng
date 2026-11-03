import { hilog } from '@kit.PerformanceAnalysisKit';
import { Palette } from '../common/Theme';
import { storage } from './StorageService';

const PREF_KEY_SKIN = 'skin_id';

/**
 * 皮肤服务：皮肤 id 存在 preferences 里，重启后仍然生效。
 * AppStorage 里的 skinId / skinTick 供 UI 观察，skinTick 每次切换 +1 触发各页重绘。
 */
export class SkinService {
  private static currentId: string = 'original';

  static get current(): string {
    return SkinService.currentId;
  }

  /** 在 loadContent 之前调用，保证首帧就是上次选的皮肤 */
  static async init(): Promise<void> {
    let id = 'original';
    try {
      id = await storage.readString(PREF_KEY_SKIN, 'original');
    } catch (e) {
      hilog.warn(0x0000, 'carbon', 'read skin failed');
    }
    SkinService.currentId = id;
    Palette.applySkin(id);
    AppStorage.setOrCreate('skinId', id);
    AppStorage.setOrCreate('skinTick', 0);
  }

  static select(id: string): void {
    SkinService.currentId = id;
    Palette.applySkin(id);
    AppStorage.setOrCreate('skinId', id);
    const tick = AppStorage.get<number>('skinTick') ?? 0;
    AppStorage.setOrCreate('skinTick', tick + 1);
    storage.writeString(PREF_KEY_SKIN, id).catch((err: Error) => {
      hilog.error(0x0000, 'carbon', 'save skin failed: %{public}s', err.message);
    });
  }
}
