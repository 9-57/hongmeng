import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'carbon-io';

/** 备份文件的固定文件名（放在应用沙箱 filesDir 下，无需存储权限） */
const BACKUP_FILE_NAME = 'carbon_backup.json';
const REPORT_FILE_NAME = 'carbon_report.csv';

/**
 * 文件读写服务：负责本地备份、报表导出与备份恢复。
 * 全部操作在应用沙箱内（filesDir）完成，不申请任何存储权限，符合"单机离线"要求。
 * 注意：fd 必须在 finally 里关闭，否则一次读取失败就会泄漏一个文件句柄。
 */
export class FileService {
  private static instance: FileService | null = null;
  private context: common.Context | null = null;

  static getInstance(): FileService {
    if (FileService.instance === null) {
      FileService.instance = new FileService();
    }
    return FileService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
  }

  private dirPath(): string {
    if (this.context === null) {
      return '';
    }
    return this.context.filesDir;
  }

  /** 以 TextEncoder 转成 ArrayBuffer，兼容性比直接写字符串更稳 */
  private static toBuffer(text: string): ArrayBuffer {
    const encoder = new util.TextEncoder();
    const u8: Uint8Array = encoder.encodeInto(text);
    const out = new ArrayBuffer(u8.length);
    const view = new Uint8Array(out);
    for (let i = 0; i < u8.length; i++) {
      view[i] = u8[i];
    }
    return out;
  }

  /** 只解码实际读到的字节数，避免把缓冲区尾部的 0 解成乱码 */
  private static fromBuffer(buf: ArrayBuffer, length: number): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf, 0, length));
  }

  /** 写入文本到沙箱文件，返回文件绝对路径；失败返回空串 */
  writeText(fileName: string, content: string): string {
    const dir = this.dirPath();
    if (dir.length === 0) {
      return '';
    }
    const filePath = `${dir}/${fileName}`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, FileService.toBuffer(content));
      return filePath;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'write failed: %{public}s', JSON.stringify(err));
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'close after write failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /** 读取沙箱文本文件；不存在或失败返回空串 */
  readText(fileName: string): string {
    const dir = this.dirPath();
    if (dir.length === 0) {
      return '';
    }
    const filePath = `${dir}/${fileName}`;
    let file: fs.File | null = null;
    try {
      if (!fs.accessSync(filePath)) {
        return '';
      }
      const stat = fs.statSync(filePath);
      if (stat.size <= 0) {
        return '';
      }
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const readLen = fs.readSync(file.fd, buf);
      return FileService.fromBuffer(buf, readLen);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'read failed: %{public}s', JSON.stringify(err));
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'close after read failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /** 备份数据（记录 + 账户信息打包为一个 JSON） */
  backup(payload: string): string {
    return this.writeText(BACKUP_FILE_NAME, payload);
  }

  /** 读取备份内容 */
  readBackup(): string {
    return this.readText(BACKUP_FILE_NAME);
  }

  /** 导出 CSV 报表，返回路径 */
  exportCsv(csv: string): string {
    // 加 BOM，避免用 Excel 打开时中文乱码
    const bom = String.fromCharCode(0xFEFF);
    return this.writeText(REPORT_FILE_NAME, bom + csv);
  }

  /**
   * 通过系统保存框把文本写到用户自己选择的目录（下载/文档等）。
   * DocumentViewPicker 自带一次性的文件授权，因此不需要申请任何存储权限，
   * 用户也能真正拿到文件（沙箱里的副本在卸载后会被清除）。
   * @returns 保存成功返回文件 uri；用户取消或失败返回空串
   */
  async saveToUserDir(content: string, suggestedName: string): Promise<string> {
    if (this.context === null) {
      return '';
    }
    let uri = '';
    try {
      const docPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      const dot = suggestedName.lastIndexOf('.');
      options.newFileNames = [dot > 0 ? suggestedName.substring(0, dot) : suggestedName];
      if (dot > 0) {
        options.fileSuffixChoices = [suggestedName.substring(dot)];
      }
      const saved = await docPicker.save(options);
      if (saved === undefined || saved.length === 0 || saved[0].length === 0) {
        // 用户点了取消，不算错误，静默返回
        return '';
      }
      uri = saved[0];
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'picker save failed: %{public}s', JSON.stringify(err));
      return '';
    }
    return this.writeUri(uri, content);
  }

  /** 往 picker 返回的 uri 写字节；与沙箱写入共用同一套编码逻辑 */
  private writeUri(uri: string, content: string): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, FileService.toBuffer(content));
      return uri;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'write uri failed: %{public}s', JSON.stringify(err));
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'close after uri write failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /** 导出 CSV 到用户目录（带 BOM，Excel 打开不乱码） */
  async exportCsvToUser(csv: string): Promise<string> {
    const bom = String.fromCharCode(0xFEFF);
    return this.saveToUserDir(bom + csv, REPORT_FILE_NAME);
  }

  /** 把纯文本摘要导出到用户目录 */
  async exportTextToUser(text: string, fileName: string): Promise<string> {
    return this.saveToUserDir(text, fileName);
  }

  /** 把备份 JSON 另存到用户目录（换机时可留底） */
  async exportBackupToUser(payload: string): Promise<string> {
    return this.saveToUserDir(payload, BACKUP_FILE_NAME);
  }

  /** 是否存在备份 */
  hasBackup(): boolean {
    const dir = this.dirPath();
    if (dir.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(`${dir}/${BACKUP_FILE_NAME}`);
    } catch (e) {
      return false;
    }
  }

  /** 文件大小（字节），用于展示 */
  backupSize(): number {
    const dir = this.dirPath();
    if (dir.length === 0) {
      return 0;
    }
    try {
      const p = `${dir}/${BACKUP_FILE_NAME}`;
      if (!fs.accessSync(p)) {
        return 0;
      }
      return fs.statSync(p).size;
    } catch (e) {
      return 0;
    }
  }

  get backupPath(): string {
    const dir = this.dirPath();
    return dir.length === 0 ? '' : `${dir}/${BACKUP_FILE_NAME}`;
  }
}

export const fileService = FileService.getInstance();
