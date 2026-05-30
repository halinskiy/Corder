import React from "react";
import { Star, X } from "lucide-react";
import type { T } from "../i18n";

interface Props {
  t: T;
  /// Called when the user clicks Send (rating > 0). Rating is the
  /// 1-5 star pick, comment is trimmed (may be empty). Email is
  /// added by the parent from the signed-in account — we don't
  /// ask the user for it here.
  onSubmit: (rating: number, comment: string) => void;
  /// Called when the user clicks the X corner button or the Skip
  /// button under the form. The banner is removed and re-surfaces
  /// after 7 days (parent-managed in localStorage).
  onDismiss: () => void;
}

/// Inline rating prompt that lives at the bottom of a non-empty
/// transcript. Same outline-card visual language as
/// SpeakersClarifyBanner / EmptyDeleteBanner — 18 px light heading,
/// 1 px `--border-strong`, 12 px content gap. Two phases:
///   1) only stars + dismiss X are visible
///   2) once a star is clicked the comment + email fields and the
///      Send/Skip row slide in below
/// We deliberately don't auto-submit on a star click: people often
/// want to tap a star and then add a sentence. Make the Send button
/// the explicit commit.
export function RatingBanner({ t, onSubmit, onDismiss }: Props) {
  const [rating, setRating] = React.useState(0);
  const [hoverRating, setHoverRating] = React.useState(0);
  const [comment, setComment] = React.useState("");
  const [busy, setBusy] = React.useState(false);

  // Fallback to English literals when a locale hasn't translated the
  // rating strings yet. Keys are optional in the Strings interface so
  // a missing key returns undefined rather than crashing — but undefined
  // in JSX would render nothing. Hardcoded fallbacks are intentional.
  const title = t.rating_title || "How is Corder treating you?";
  const commentPh = t.rating_comment_placeholder || "What can we improve? (optional)";
  const submitLabel = t.rating_submit || "Send";
  const skipLabel = t.rating_skip || "Skip";
  // Only ask for written feedback when the rating leaves room for
  // improvement. A 5-star tap is a clean signal on its own; making
  // the user think of something to type would just add friction and
  // suppress the submit rate.
  const showComment = rating > 0 && rating <= 4;

  const handleSubmit = () => {
    if (busy || rating === 0) return;
    setBusy(true);
    onSubmit(rating, comment.trim());
  };

  const stars = [1, 2, 3, 4, 5];
  // Hover preview overrides the committed rating only while the
  // pointer is over the row. Once it leaves we snap back to the
  // committed value so the user sees their actual choice.
  const displayRating = hoverRating > 0 ? hoverRating : rating;

  return (
    <div className="trans-banner clarify-banner rating-banner">
      <button
        className="clarify-dismiss"
        onClick={onDismiss}
        title={skipLabel}
        aria-label={skipLabel}
      >
        <X size={14} strokeWidth={2} />
      </button>
      <div className="clarify-text">
        <div className="clarify-body">{title}</div>
      </div>
      <div className="rating-stars" role="radiogroup" aria-label={title}>
        {stars.map((n) => {
          const filled = displayRating >= n;
          return (
            <button
              key={n}
              type="button"
              className={"rating-star" + (filled ? " filled" : "")}
              onClick={() => setRating(n)}
              onMouseEnter={() => setHoverRating(n)}
              onMouseLeave={() => setHoverRating(0)}
              aria-label={`${n}`}
              aria-checked={rating === n}
              role="radio"
            >
              <Star
                size={26}
                strokeWidth={1.5}
                fill={filled ? "currentColor" : "none"}
              />
            </button>
          );
        })}
      </div>
      {rating > 0 && (
        <>
          {showComment && (
            <textarea
              className="rating-textarea"
              rows={3}
              placeholder={commentPh}
              value={comment}
              onChange={(e) => setComment(e.target.value)}
              disabled={busy}
            />
          )}
          <div className="clarify-actions clarify-actions-stack">
            <button
              type="button"
              className="clarify-btn accent"
              onClick={handleSubmit}
              disabled={busy || rating === 0}
              aria-busy={busy}
            >
              <span>{submitLabel}</span>
            </button>
          </div>
        </>
      )}
    </div>
  );
}
