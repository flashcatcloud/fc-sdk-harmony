/**
 * FlashCat ingest sites. Mirrors `FlashcatSite` in the Android SDK.
 * The intake endpoint receives NDJSON batches as `text/plain` (see fc-rum).
 */
export enum FlashcatSite {
  /** Production (China). */
  CN = 'https://browser.flashcat.cloud',
  /** Staging / pre-release. */
  STAGING = 'https://jira.flashcat.cloud'
}

/** Returns the RUM intake URL for a site (path appended by the upload layer). */
export function intakeEndpoint(site: FlashcatSite): string {
  return site as string;
}
