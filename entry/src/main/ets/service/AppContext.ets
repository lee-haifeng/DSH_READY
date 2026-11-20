/**
 * Process-wide application context.
 *
 * ArkUI pages cannot reach the ability context directly, so the ability stores it
 * here once during `onCreate`. Services read it lazily and fail loudly if a caller
 * touches storage before the ability is ready.
 */

import { common } from '@kit.AbilityKit';

export class AppContext {
  private static ability: common.UIAbilityContext | undefined = undefined;

  /** Called once from EntryAbility.onCreate. */
  static attach(context: common.UIAbilityContext): void {
    AppContext.ability = context;
  }

  /** The ability context, required by preferences, files and Asset Store. */
  static require(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | undefined = AppContext.ability;
    if (ctx === undefined) {
      throw new Error('AppContext is not initialised: EntryAbility.onCreate must call AppContext.attach');
    }
    return ctx;
  }

  /** Files directory that holds session documents. */
  static filesDir(): string {
    return AppContext.require().filesDir;
  }
}
