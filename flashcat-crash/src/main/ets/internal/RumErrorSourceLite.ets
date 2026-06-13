/**
 * Local mirror of RUM's error-source string values. The crash module depends only
 * on @flashcatcloud/core (not on @flashcatcloud/rum), so it cannot import
 * RumErrorSource from the rum module. The string value MUST stay in sync with
 * flashcat-rum/src/main/ets/RumTypes.ets `RumErrorSource`.
 */
export enum RumErrorSource {
  SOURCE = 'source'
}
