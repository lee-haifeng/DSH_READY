/**
 * Image attachments.
 *
 * Picked photos are copied into the app sandbox once and referenced by path. The base64
 * payload is produced only when a request is built, so a long conversation full of
 * screenshots does not turn into a multi-megabyte JSON document.
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { BLOCK_IMAGE, ContentBlock } from '../model/Types';
import { MAX_IMAGE_BYTES, MAX_IMAGES_PER_MESSAGE } from '../common/Constants';
import { AppContext } from './AppContext';
import { Log, newId } from '../common/Utils';

const log = new Log('Images');

/** Directory that stores attachment copies. */
function imagesDir(): string {
  const root: string = `${AppContext.filesDir()}/images`;
  if (!fileIo.accessSync(root)) {
    fileIo.mkdirSync(root, true);
  }
  return root;
}

/** Lowercase extension of a path, defaulting to jpg. */
function extensionOf(uri: string): string {
  const dot: number = uri.lastIndexOf('.');
  if (dot < 0 || dot === uri.length - 1) {
    return 'jpg';
  }
  const ext: string = uri.slice(dot + 1).toLowerCase();
  if (ext.length > 5) {
    return 'jpg';
  }
  return ext;
}

/** MIME type for a file extension. */
function mediaTypeOf(ext: string): string {
  if (ext === 'png') {
    return 'image/png';
  }
  if (ext === 'webp') {
    return 'image/webp';
  }
  if (ext === 'gif') {
    return 'image/gif';
  }
  if (ext === 'heic') {
    return 'image/heic';
  }
  return 'image/jpeg';
}

export class ImageService {
  /**
   * Open the system picker and copy the chosen photos into the sandbox.
   *
   * @param remaining how many more images the current message may carry
   * @returns attachment blocks ready to be sent, or an empty array when cancelled
   */
  static async pick(remaining: number): Promise<Array<ContentBlock>> {
    const out: Array<ContentBlock> = [];
    if (remaining <= 0) {
      return out;
    }
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = Math.min(remaining, MAX_IMAGES_PER_MESSAGE);
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    let uris: Array<string> = [];
    try {
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      uris = result.photoUris;
    } catch (e) {
      const err = e as BusinessError;
      log.warn(`picker cancelled or failed: ${err.code} ${err.message}`);
      return out;
    }
    for (let i = 0; i < uris.length; i++) {
      const block: ContentBlock | undefined = ImageService.importOne(uris[i]);
      if (block !== undefined) {
        out.push(block);
      }
    }
    return out;
  }

  /** Copy one picked uri into the sandbox and describe it. */
  private static importOne(sourceUri: string): ContentBlock | undefined {
    const ext: string = extensionOf(sourceUri);
    const dest: string = `${imagesDir()}/${newId('img')}.${ext}`;
    let source: fileIo.File | undefined = undefined;
    try {
      source = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(source.fd).size;
      if (size > MAX_IMAGE_BYTES) {
        log.warn(`image rejected, ${size} bytes exceeds the cap`);
        return undefined;
      }
      fileIo.copyFileSync(source.fd, dest);
    } catch (e) {
      const err = e as BusinessError;
      log.error(`import failed: ${err.code} ${err.message}`);
      return undefined;
    } finally {
      if (source !== undefined) {
        fileIo.closeSync(source);
      }
    }
    let width: number = 0;
    let height: number = 0;
    try {
      const imageSource: image.ImageSource = image.createImageSource(dest);
      const info: image.ImageInfo = imageSource.getImageInfoSync();
      width = info.size.width;
      height = info.size.height;
      imageSource.release();
    } catch (e) {
      log.warn('could not read image dimensions');
    }
    const block: ContentBlock = {
      kind: BLOCK_IMAGE,
      uri: dest,
      mediaType: mediaTypeOf(ext),
      name: `image.${ext}`,
      width: width,
      height: height
    };
    return block;
  }

  /** Read an attachment back as base64, or an empty string when the file is gone. */
  static base64Of(uri: string): string {
    if (!fileIo.accessSync(uri)) {
      return '';
    }
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buffer);
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(new Uint8Array(buffer));
    } catch (e) {
      const err = e as BusinessError;
      log.error(`base64 read failed: ${err.code} ${err.message}`);
      return '';
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
    }
  }

  /** Delete an attachment copy, used when the user removes it before sending. */
  static discard(uri: string): void {
    try {
      if (fileIo.accessSync(uri)) {
        fileIo.unlinkSync(uri);
      }
    } catch (e) {
      log.warn('could not delete attachment');
    }
  }

  /** Remove attachment copies that no conversation references any more. */
  static sweep(keep: Set<string>): void {
    const root: string = imagesDir();
    let names: Array<string> = [];
    try {
      names = fileIo.listFileSync(root);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const path: string = `${root}/${names[i]}`;
      if (!keep.has(path)) {
        ImageService.discard(path);
      }
    }
  }
}
