import { uiObserver, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { FlashcatLog } from '@flashcatcloud/core';
import { GlobalRumMonitor } from '../RumMonitor';
import { RumAutoInstrumentation } from './RumAutoInstrumentation';

/** Context the navigation observer can be scoped to (ability or UI context). */
export type NavContext = common.UIAbilityContext | UIContext;

/**
 * Phase-2 A1: navigation auto-tracking. Subscribes to the ArkUI
 * `routerPageUpdate` observer and turns router page show/hide into automatic
 * start/stopView calls — so apps using `router` navigation get a correct view
 * tree without any manual `startView`/`stopView`.
 *
 * Mapping:
 * - `ON_PAGE_SHOW`  → startView (page becomes visible)
 * - `ON_PAGE_HIDE`  → stopView  (page hidden — closes its time_spent)
 * - key  = stable `pageId` (falls back to `path`); name = `name` (falls back to
 *   the last path segment); `view.url` attribute = `path`.
 *
 * Idempotent + never-throw: a second attach is ignored; every observer callback
 * is wrapped so a tracker bug can never crash the host app. Inert unless RUM is
 * enabled with `setTrackNavigation(true)`.
 *
 * NavDestination-based navigation (`Navigation`/`navDestinationUpdate`) is a
 * later refinement — `router` covers the broadest set of apps first (OQ-2).
 */
export class RumNavigationTracker {
  // `uiObserver.on('routerPageUpdate', context, cb)` is scoped PER context.
  // Keyed per context (not a single static): a multi-UIAbility app attaches
  // once per ability, and a global single-attach guard silently disabled
  // navigation tracking for every context but the first.
  private static readonly attached: Map<NavContext, (info: uiObserver.RouterPageInfo) => void> =
    new Map<NavContext, (info: uiObserver.RouterPageInfo) => void>();

  /**
   * Attach the router observer scoped to `context` (a UIAbilityContext or a
   * UIContext obtained in UI land). Call once per context after RUM is enabled.
   */
  static attach(context: NavContext): void {
    if (!RumAutoInstrumentation.isNavigationTrackingEnabled()) {
      FlashcatLog.d('rum.nav: trackNavigation disabled — observer not attached');
      return;
    }
    if (RumNavigationTracker.attached.has(context)) {
      FlashcatLog.d('rum.nav: observer already attached to this context — ignoring');
      return; // idempotent per context
    }
    const cb = (info: uiObserver.RouterPageInfo): void => {
      try {
        RumNavigationTracker.onRouterPageUpdate(info);
      } catch (e) {
        FlashcatLog.e(`rum.nav: callback failed: ${e instanceof Error ? e.message : `${e}`}`);
      }
    };
    try {
      uiObserver.on('routerPageUpdate', context, cb);
      RumNavigationTracker.attached.set(context, cb);
      FlashcatLog.d(`rum.nav: routerPageUpdate observer attached (contexts=${RumNavigationTracker.attached.size})`);
    } catch (e) {
      FlashcatLog.e(`rum.nav: observer attach failed: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  /** Detach all observers. Called on SDK stop so they don't leak across re-enable. */
  static detach(): void {
    RumNavigationTracker.attached.forEach(
      (cb: (info: uiObserver.RouterPageInfo) => void, ctx: NavContext) => {
        try {
          uiObserver.off('routerPageUpdate', ctx, cb);
        } catch (_e) {
          // already removed / context torn down
        }
      });
    RumNavigationTracker.attached.clear();
  }

  /** Detach the observer bound to one context (e.g. before that ability is destroyed). */
  static detachContext(context: NavContext): void {
    const cb: ((info: uiObserver.RouterPageInfo) => void) | undefined =
      RumNavigationTracker.attached.get(context);
    if (cb !== undefined) {
      try {
        uiObserver.off('routerPageUpdate', context, cb);
      } catch (_e) {
        // already removed / context torn down
      }
      RumNavigationTracker.attached.delete(context);
    }
  }

  /** Pure: translate a router page update into a start/stopView. */
  private static onRouterPageUpdate(info: uiObserver.RouterPageInfo): void {
    const key: string = RumNavigationTracker.viewKey(info);
    const state: uiObserver.RouterPageState = info.state;
    if (state === uiObserver.RouterPageState.ON_PAGE_SHOW) {
      const name: string = RumNavigationTracker.viewName(info);
      const attributes: Record<string, Object> = { 'view.url': info.path };
      GlobalRumMonitor.get().startView(key, name, attributes);
      FlashcatLog.d(`rum.nav: auto startView key="${key}" name="${name}" path="${info.path}"`);
    } else if (state === uiObserver.RouterPageState.ON_PAGE_HIDE) {
      GlobalRumMonitor.get().stopView(key);
      FlashcatLog.d(`rum.nav: auto stopView key="${key}"`);
    }
  }

  /** Stable per-page key: prefer pageId, fall back to path. */
  static viewKey(info: uiObserver.RouterPageInfo): string {
    return RumNavigationTracker.viewKeyFor(info.pageId, info.path, info.index);
  }

  /** Human view name: prefer the route name, fall back to the last path segment. */
  static viewName(info: uiObserver.RouterPageInfo): string {
    return RumNavigationTracker.viewNameFor(info.name, info.path);
  }

  /** Pure (testable): stable per-page key from raw fields. */
  static viewKeyFor(pageId: string, path: string, index: number): string {
    if (pageId.length > 0) {
      return pageId;
    }
    return path.length > 0 ? path : `page-${index}`;
  }

  /** Pure (testable): human view name from raw fields. */
  static viewNameFor(name: string, path: string): string {
    if (name.length > 0) {
      return name;
    }
    return RumNavigationTracker.lastSegment(path);
  }

  private static lastSegment(path: string): string {
    if (path.length === 0) {
      return 'unknown';
    }
    const trimmed: string = path.endsWith('.ets') ? path.substring(0, path.length - 4) : path;
    const idx: number = trimmed.lastIndexOf('/');
    return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
  }
}
