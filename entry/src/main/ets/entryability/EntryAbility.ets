import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppContext } from '../service/AppContext';
import { SettingsService } from '../service/SettingsService';
import { Log } from '../common/Utils';
import { THEME_DARK, THEME_LIGHT, THEME_SYSTEM } from '../common/Theme';

const log = new Log('Ability');

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppContext.attach(this.context);
    try {
      SettingsService.init();
    } catch (e) {
      const err = e as BusinessError;
      log.error(`settings init failed: ${err.code} ${err.message}`);
    }
    log.info('ability created');
  }

  onDestroy(): void {
    log.info('ability destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.applyColorMode();
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        log.error(`loadContent failed: ${err.code} ${err.message}`);
        return;
      }
      this.applyWindowStyle(windowStage);
    });
  }

  /** Keep the app's own theme authoritative instead of following the system blindly. */
  private applyColorMode(): void {
    const mode: string = SettingsService.get().themeMode;
    try {
      const appContext = this.context.getApplicationContext();
      if (mode === THEME_DARK) {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else if (mode === THEME_LIGHT) {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (e) {
      const err = e as BusinessError;
      log.warn(`setColorMode failed: ${err.code} ${err.message}`);
    }
  }

  /** Immersive edge-to-edge layout, which is what a chat app wants on a phone. */
  private applyWindowStyle(windowStage: window.WindowStage): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      const isDark: boolean = SettingsService.get().themeMode === THEME_DARK
        || (SettingsService.get().themeMode === THEME_SYSTEM && this.isSystemDark());
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: isDark ? '#ECEDEF' : '#1A1C21',
        navigationBarContentColor: isDark ? '#ECEDEF' : '#1A1C21'
      });
    } catch (e) {
      const err = e as BusinessError;
      log.warn(`window style failed: ${err.code} ${err.message}`);
    }
  }

  private isSystemDark(): boolean {
    return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onWindowStageDestroy(): void {
    log.info('window stage destroyed');
  }

  onForeground(): void {
    log.debug('foreground');
  }

  onBackground(): void {
    log.debug('background');
  }

  onConfigurationUpdate(config: Configuration): void {
    // System dark mode changed: recompute the palette unless the user pinned a theme.
    if (SettingsService.get().themeMode === THEME_SYSTEM) {
      SettingsService.publish();
    }
  }}
