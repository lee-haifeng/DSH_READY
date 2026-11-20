/**
 * Voice input.
 *
 * Uses the system speech recogniser (`CoreSpeechKit`) so no audio ever leaves the
 * device through this app. The engine ends a session on its own when the speaker stops,
 * which gives a natural tap-to-talk interaction without a hold gesture.
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Utils';
import { AppContext } from './AppContext';

const log = new Log('Speech');

/** Callbacks the composer implements. */
export interface SpeechEvents {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
  onError: (message: string) => void;
  onStateChange: (listening: boolean) => void;
}

/** Recogniser session state. */
export class SpeechService {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private sessionId: string = '';
  private listening: boolean = false;
  private events: SpeechEvents;
  private language: string = 'zh-CN';

  constructor(events: SpeechEvents) {
    this.events = events;
  }

  /** Ask for the microphone permission. */
  private async ensurePermission(): Promise<boolean> {
    const permissions: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const context: common.UIAbilityContext = AppContext.require();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, permissions);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (e) {
      const err = e as BusinessError;
      log.error(`permission request failed: ${err.code} ${err.message}`);
      return false;
    }
  }

  /** Create the engine on first use. */
  private async ensureEngine(): Promise<boolean> {
    const existing: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    if (existing !== undefined) {
      return true;
    }
    const params: speechRecognizer.CreateEngineParams = {
      language: this.language,
      online: 1
    };
    try {
      const engine: speechRecognizer.SpeechRecognitionEngine = await speechRecognizer.createEngine(params);
      engine.setListener(this.buildListener());
      this.engine = engine;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      log.error(`createEngine failed: ${err.code} ${err.message}`);
      return false;
    }
  }

  private buildListener(): speechRecognizer.RecognitionListener {
    const self: SpeechService = this;
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (sessionId: string, eventMessage: string) => {
        log.info(`speech started ${sessionId}`);
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
        log.debug(`speech event ${eventCode}`);
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        if (result.isFinal || result.isLast) {
          self.events.onFinal(result.result);
        } else {
          self.events.onPartial(result.result);
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
        self.listening = false;
        self.events.onStateChange(false);
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        self.listening = false;
        self.events.onStateChange(false);
        log.error(`speech error ${errorCode} ${errorMessage}`);
        self.events.onError(errorMessage);
      }
    };
    return listener;
  }

  /** Whether a session is running. */
  isListening(): boolean {
    return this.listening;
  }

  /** Set the recognition language, mapping `zh`/`en` onto the supported tags. */
  setLanguage(lang: string): void {
    this.language = lang === 'en' ? 'en-US' : 'zh-CN';
  }

  /** Start listening. Resolves to whether the session actually began. */
  async start(): Promise<boolean> {
    if (this.listening) {
      return true;
    }
    const permitted: boolean = await this.ensurePermission();
    if (!permitted) {
      this.events.onError('chat.voice.permission');
      return false;
    }
    const ready: boolean = await this.ensureEngine();
    if (!ready) {
      this.events.onError('chat.voice.unsupported');
      return false;
    }
    const engine: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    if (engine === undefined) {
      return false;
    }
    this.sessionId = `dsh_${Date.now()}`;
    const audioInfo: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16
    };
    const params: speechRecognizer.StartParams = {
      sessionId: this.sessionId,
      audioInfo: audioInfo
    };
    try {
      engine.startListening(params);
      this.listening = true;
      this.events.onStateChange(true);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      log.error(`startListening failed: ${err.code} ${err.message}`);
      this.events.onError('chat.voice.failed');
      return false;
    }
  }

  /** Cancel the running session, discarding the current utterance. */
  stop(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    if (engine === undefined || !this.listening) {
      return;
    }
    try {
      engine.cancel(this.sessionId);
    } catch (e) {
      log.warn('cancel failed');
    }
    this.listening = false;
    this.events.onStateChange(false);
  }

  /** Release the engine, called when the page disappears. */
  release(): void {
    const engine: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    this.engine = undefined;
    this.listening = false;
    if (engine !== undefined) {
      try {
        engine.shutdown();
      } catch (e) {
        log.warn('shutdown failed');
      }
    }
  }
}
