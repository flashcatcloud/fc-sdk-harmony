/** Mirrors the RUM enums from the Android SDK / rum-events-format. */

export enum RumActionType {
  TAP = 'tap',
  SCROLL = 'scroll',
  SWIPE = 'swipe',
  CLICK = 'click',
  BACK = 'back',
  CUSTOM = 'custom'
}

export enum RumErrorSource {
  NETWORK = 'network',
  SOURCE = 'source',     // ArkTS / JS runtime error
  CONSOLE = 'console',
  WEBVIEW = 'webview',
  AGENT = 'agent',
  CUSTOM = 'custom'
}

export enum RumResourceKind {
  IMAGE = 'image',
  XHR = 'xhr',
  FETCH = 'fetch',
  FONT = 'font',
  CSS = 'css',
  JS = 'js',
  MEDIA = 'media',
  NATIVE = 'native',
  OTHER = 'other'
}

export enum RumResourceMethod {
  GET = 'GET',
  POST = 'POST',
  PUT = 'PUT',
  DELETE = 'DELETE',
  HEAD = 'HEAD',
  PATCH = 'PATCH'
}
