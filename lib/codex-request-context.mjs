export function codexThreadId(metadata) {
  const turnMetadata = metadata?.["x-codex-turn-metadata"];
  const candidate = turnMetadata?.thread_id ?? turnMetadata?.session_id;
  return typeof candidate === "string" && candidate.length <= 80 ? candidate : undefined;
}
