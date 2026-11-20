/**
 * API key storage backed by the system credential store (Asset Store Kit).
 *
 * The key never touches preferences or the sandbox filesystem. Only a four character
 * tail is remembered so the settings screen can show which key is active.
 */

import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { ASSET_ALIAS } from '../common/Constants';
import { Log } from '../common/Utils';

const log = new Log('Secret');

/** Encode a string as UTF-8 bytes for the credential store. */
function toBytes(text: string): Uint8Array {
  const encoder: util.TextEncoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

/** Decode UTF-8 bytes coming back from the credential store. */
function fromBytes(bytes: Uint8Array): string {
  const options: util.TextDecoderOptions = { fatal: false, ignoreBOM: true };
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', options);
  return decoder.decodeToString(bytes);
}

/** Asset Store error code for "entry not found". */
const ASSET_NOT_FOUND: number = 24000002;

export class SecretService {
  private static cached: string | undefined = undefined;

  /** Persist the API key, replacing any previous value. */
  static async setApiKey(key: string): Promise<void> {
    const trimmed: string = key.trim();
    if (trimmed.length === 0) {
      await SecretService.clearApiKey();
      return;
    }
    await SecretService.clearApiKey();
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, toBytes(ASSET_ALIAS));
    attributes.set(asset.Tag.SECRET, toBytes(trimmed));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, toBytes('deepseek'));
    await asset.add(attributes);
    SecretService.cached = trimmed;
    log.info('api key stored');
  }

  /** Read the stored key, or an empty string when none is configured. */
  static async getApiKey(): Promise<string> {
    const cached: string | undefined = SecretService.cached;
    if (cached !== undefined) {
      return cached;
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ASSET_ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = await asset.query(query);
      if (rows.length === 0) {
        return '';
      }
      const row: asset.AssetMap = rows[0];
      const secret: asset.Value | undefined = row.get(asset.Tag.SECRET);
      if (secret === undefined) {
        return '';
      }
      const key: string = fromBytes(secret as Uint8Array);
      SecretService.cached = key;
      return key;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== ASSET_NOT_FOUND) {
        log.warn(`query api key failed: ${err.code} ${err.message}`);
      }
      return '';
    }
  }

  /** Whether a key is configured, without exposing it. */
  static async hasApiKey(): Promise<boolean> {
    const key: string = await SecretService.getApiKey();
    return key.length > 0;
  }

  /** Remove the stored key. */
  static async clearApiKey(): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ASSET_ALIAS));
    try {
      await asset.remove(query);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== ASSET_NOT_FOUND) {
        log.warn(`remove api key failed: ${err.code} ${err.message}`);
      }
    }
    SecretService.cached = '';
  }

  /** Last four characters of the stored key, for a non-secret hint. */
  static async keyHint(): Promise<string> {
    const key: string = await SecretService.getApiKey();
    if (key.length <= 4) {
      return key.length === 0 ? '' : '••••';
    }
    return `••••${key.slice(key.length - 4)}`;
  }
}
