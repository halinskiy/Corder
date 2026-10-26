import type { T } from "../i18n";

export function localLLMError(message: string, t: T): string | null {
  switch (message) {
    case "local_llm_unavailable": return t.local_llm_unavailable;
    case "local_llm_invalid_endpoint": return t.local_llm_invalid_endpoint;
    case "local_llm_no_model": return t.local_llm_no_model;
    case "local_llm_context_truncated": return t.local_llm_context_truncated;
    case "local_llm_context_too_small": return t.local_llm_context_too_small;
    case "local_llm_output_truncated": return t.local_llm_output_truncated;
    case "local_llm_invalid_response": return t.local_llm_invalid_response;
    case "local_llm_request_failed": return t.local_llm_request_failed;
    default: return message.startsWith("local_llm_") ? t.local_llm_request_failed : null;
  }
}
