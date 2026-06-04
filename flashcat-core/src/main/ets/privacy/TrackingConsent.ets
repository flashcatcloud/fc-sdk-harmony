/**
 * User consent state for data collection. While PENDING, events are buffered
 * separately and only flushed to the upload pipeline once consent becomes GRANTED.
 */
export enum TrackingConsent {
  GRANTED = 'granted',
  NOT_GRANTED = 'not_granted',
  PENDING = 'pending'
}
