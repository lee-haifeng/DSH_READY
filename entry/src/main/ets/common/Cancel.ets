/**
 * Cancellation token.
 *
 * A tiny substitute for `AbortController`, which ArkTS does not expose. The agent
 * loop hands one token to every async hop so a single "stop" tap unwinds the whole
 * chain: request, tool execution and auto-continuation.
 */

export class CancelToken {
  private flag: boolean = false;
  private listeners: Array<() => void> = [];

  /** Whether cancellation was already requested. */
  get cancelled(): boolean {
    return this.flag;
  }

  /** Request cancellation and run listeners once. */
  cancel(): void {
    if (this.flag) {
      return;
    }
    this.flag = true;
    const pending: Array<() => void> = this.listeners;
    this.listeners = [];
    for (let i = 0; i < pending.length; i++) {
      try {
        pending[i]();
      } catch (e) {
        // A listener must never break cancellation of the others.
      }
    }
  }

  /** Register a listener; it fires immediately when already cancelled. */
  onCancel(listener: () => void): void {
    if (this.flag) {
      listener();
      return;
    }
    this.listeners.push(listener);
  }

  /** Remove a listener registered earlier. */
  offCancel(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}
