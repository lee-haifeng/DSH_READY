/**
 * Small filesystem helpers shared by the stores.
 *
 * State documents are written through a temporary file and a rename, so a process killed
 * mid-write leaves either the old document or the new one, never a truncated one.
 */

import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Utils';

const log = new Log('Fs');

/** Whether a path exists. */
export function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (e) {
    return false;
  }
}

/** Create a directory (and parents) when missing. */
export function ensureDir(path: string): void {
  if (!exists(path)) {
    fileIo.mkdirSync(path, true);
  }
}

/** Read a UTF-8 text file, returning an empty string when it is missing or unreadable. */
export function readTextFile(path: string): string {
  if (!exists(path)) {
    return '';
  }
  try {
    return fileIo.readTextSync(path);
  } catch (e) {
    const err = e as BusinessError;
    log.warn(`read ${path} failed: ${err.code} ${err.message}`);
    return '';
  }
}

/** Write a text file atomically. */
export function writeAtomic(path: string, content: string): void {
  const tmp: string = `${path}.tmp`;
  const file: fileIo.File = fileIo.openSync(tmp,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
  if (exists(path)) {
    fileIo.unlinkSync(path);
  }
  fileIo.renameSync(tmp, path);
}

/** Delete a file when it exists. */
export function removeFile(path: string): void {
  try {
    if (exists(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (e) {
    log.warn(`delete ${path} failed`);
  }
}
