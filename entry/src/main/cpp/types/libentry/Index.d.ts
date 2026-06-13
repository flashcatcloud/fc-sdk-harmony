export const add: (a: number, b: number) => number;

/**
 * Demo-only: dereferences null in native code (libentry.so) to produce a real
 * SIGSEGV with a native stack. Used to verify native-crash capture +
 * symbolication. The call does not return.
 */
export const triggerNativeCrash: () => number;
