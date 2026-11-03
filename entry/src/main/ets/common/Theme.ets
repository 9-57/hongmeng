/** 一套配色皮肤：只切换主色系，中性色（底色/卡片/文字/分隔线）保持不变 */
export class SkinDef {
  id: string;
  name: string;
  primary: string;
  primaryDark: string;
  primaryLight: string;

  constructor(id: string, name: string, primary: string, primaryDark: string, primaryLight: string) {
    this.id = id;
    this.name = name;
    this.primary = primary;
    this.primaryDark = primaryDark;
    this.primaryLight = primaryLight;
  }
}

export const SKINS: SkinDef[] = [
  new SkinDef('original', '原始', '#2F9E68', '#217A4F', '#E8F4EE'),
  new SkinDef('red', '红', '#D2544A', '#A63A31', '#FBEDEB'),
  new SkinDef('yellow', '黄', '#C08A1E', '#946A0F', '#FBF2DF'),
  new SkinDef('blue', '蓝', '#3C82D6', '#2B62A6', '#EAF2FC'),
  new SkinDef('black', '黑', '#353A38', '#222624', '#ECEEED')
];

/** 全局视觉规范（浅色主题，主色随皮肤切换，贴近环保与校园感） */
export class Palette {
  static readonly bg: string = '#F5F7F6';
  static readonly card: string = '#FFFFFF';
  /** 主色：由皮肤决定，运行时可变，故不能是 readonly */
  static primary: string = '#2F9E68';
  static primaryDark: string = '#217A4F';
  /** 深色渐变收尾与投影色，由 applySkin 从主色推导，避免深色卡片停在旧绿色 */
  static primaryDeep: string = '#1B5E45';
  static primaryShadow: string = 'rgba(33,122,79,0.20)';
  static primaryLight: string = '#E8F4EE';
  static readonly text: string = '#1F2A26';
  static readonly textSub: string = '#6B7773';
  static readonly textLight: string = '#9AA5A1';
  static readonly line: string = '#E9EDEB';
  static readonly warn: string = '#9C540F';
  static readonly danger: string = '#D96A5B';
  static readonly blue: string = '#3C82D6';
  static readonly purple: string = '#8B6FC4';

  static skinById(id: string): SkinDef {
    for (const s of SKINS) {
      if (s.id === id) {
        return s;
      }
    }
    return SKINS[0];
  }

  /** 应用皮肤：只改主色系，其余中性色不动，避免整套深色改造带来的大片返工 */
  static applySkin(id: string): void {
    const s = Palette.skinById(id);
    Palette.primary = s.primary;
    Palette.primaryDark = s.primaryDark;
    Palette.primaryLight = s.primaryLight;
    Palette.primaryDeep = Palette.shade(s.primaryDark, 0.78);
    Palette.primaryShadow = Palette.rgba(s.primaryDark, 0.2);
  }

  /** 把 #RRGGBB 按比例调暗，用于渐变收尾 */
  static shade(hex: string, factor: number): string {
    const rgb = Palette.channels(hex);
    const r = Math.round(rgb[0] * factor);
    const g = Math.round(rgb[1] * factor);
    const b = Math.round(rgb[2] * factor);
    return `#${Palette.hex2(r)}${Palette.hex2(g)}${Palette.hex2(b)}`;
  }

  /** #RRGGBB 转 rgba()，用于投影 */
  static rgba(hex: string, a: number): string {
    const rgb = Palette.channels(hex);
    return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;
  }

  private static channels(hex: string): number[] {
    const h = hex.replace('#', '');
    if (h.length !== 6) {
      return [0, 0, 0];
    }
    return [parseInt(h.substring(0, 2), 16), parseInt(h.substring(2, 4), 16), parseInt(h.substring(4, 6), 16)];
  }

  private static hex2(n: number): string {
    const v = n < 0 ? 0 : (n > 255 ? 255 : n);
    return v < 16 ? `0${v.toString(16)}` : v.toString(16);
  }
}
