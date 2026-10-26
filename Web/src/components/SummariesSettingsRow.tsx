import { useId, useRef, useState } from "react";
import { testLocalLLM, type Settings } from "../api";
import type { T } from "../i18n";
import { SettingsSelect } from "./SettingsSelect";
import { localLLMError } from "./localLLMError";

export function SummariesSettingsRow({ s, patch, t }: {
  s: Settings | null;
  patch: (settings: Settings) => void;
  t: T;
}) {
  const id = useId();
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const revision = useRef(0);
  const local = s?.local_only || s?.summary_provider === "local";

  function change(settings: Settings) {
    revision.current++;
    setResult(null);
    patch(settings);
  }

  async function check() {
    const current = revision.current;
    setChecking(true);
    setResult(null);
    try {
      const model = await testLocalLLM({
        local_llm_endpoint: s?.local_llm_endpoint,
        local_llm_model: s?.local_llm_model,
        local_llm_context_tokens: s?.local_llm_context_tokens,
      });
      if (revision.current === current) setResult(t.settings_local_llm_found.replace("{model}", model));
    } catch (error) {
      if (revision.current === current) setResult(localLLMError((error as Error).message, t) ?? t.local_llm_request_failed);
    } finally { setChecking(false); }
  }

  return (
    <div className="hk-block mic-block">
      <div className="settings-row-label">{t.settings_summaries}</div>
      <div className="settings-row-desc">{t.settings_summaries_desc}</div>
      <SettingsSelect<"cloud" | "local">
        value={local ? "local" : "cloud"}
        options={[
          { value: "cloud", label: t.settings_summaries_cloud, disabled: s?.local_only },
          { value: "local", label: t.settings_summaries_local },
        ]}
        disabled={!s}
        onChange={(summary_provider) => change({ summary_provider })}
        ariaLabel={t.settings_summaries}
      />
      {local && (
        <>
          <div className="settings-field">
            <label className="settings-row-desc" htmlFor={`${id}-endpoint`}>{t.settings_local_llm_endpoint}</label>
            <input id={`${id}-endpoint`} className="settings-input" type="url"
              value={s?.local_llm_endpoint ?? "http://127.0.0.1:1234/v1"}
              onChange={(e) => change({ local_llm_endpoint: e.target.value })}
              spellCheck={false} />
          </div>
          <div className="settings-field">
            <label className="settings-row-desc" htmlFor={`${id}-model`}>{t.settings_local_llm_model}</label>
            <input id={`${id}-model`} className="settings-input" type="text"
              value={s?.local_llm_model ?? ""} placeholder={t.settings_local_llm_auto}
              onChange={(e) => change({ local_llm_model: e.target.value })}
              spellCheck={false} />
          </div>
          <div className="settings-field">
            <div className="settings-row-desc">{t.settings_local_llm_context}</div>
            <SettingsSelect value={String(s?.local_llm_context_tokens ?? 16384)}
              options={[4096, 8192, 16384, 32768, 40960, 65536, 131072, 262144].map((value) => ({ value: String(value), label: String(value) }))}
              onChange={(value) => change({ local_llm_context_tokens: Number(value) })}
              ariaLabel={t.settings_local_llm_context} />
          </div>
          <button type="button" className="clarify-btn settings-open-btn" disabled={checking}
            onClick={() => { void check(); }}>
            {checking ? t.settings_local_llm_checking : t.settings_local_llm_check}
          </button>
          {result && <div className="settings-field-hint" role="status">{result}</div>}
        </>
      )}
    </div>
  );
}
