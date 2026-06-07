import React from "react";

/// Lightweight starfield via a Canvas + requestAnimationFrame loop.
/// Particles spawn at random points inside the host element and drift
/// toward its centre; alpha follows a triangle envelope so they ramp
/// in and out instead of popping. Used as the backdrop of the update
/// modal (count=200 over a full-window overlay) AND as the
/// "transcription-busy" texture on the Upgrade CTA inside the
/// Transcribing banner (count=40 over a 50-px tall button).
///
/// Sizing is purely driven by the canvas's own clientWidth / clientHeight,
/// so the host just needs `position: relative; overflow: hidden` and a
/// CSS rule that pins this canvas to `inset: 0` with `pointer-events: none`.

interface Star {
  x: number; y: number;
  vx: number; vy: number;
  r: number;
  life: number; maxLife: number;
}

interface Props {
  /** Number of particles. 200 looks dense on a full-window overlay;
   *  30-50 is enough for a single-button-sized canvas. */
  count?: number;
  /** Override the host class so callers can pin positioning with
   *  their own CSS rule (`.update-stars`, `.trans-upsell-stars`, etc.). */
  className?: string;
}

export function StarsCanvas({ count = 200, className = "update-stars" }: Props) {
  const ref = React.useRef<HTMLCanvasElement | null>(null);

  React.useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let stars = makeStars(count, canvas);
    let raf = 0;
    let last = performance.now();

    const dpr = Math.min(2, window.devicePixelRatio || 1);

    const resize = () => {
      const { clientWidth: w, clientHeight: h } = canvas;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      stars = makeStars(count, canvas);
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      const cx = w / 2, cy = h / 2;

      ctx.clearRect(0, 0, w, h);

      for (const s of stars) {
        s.life += dt;
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        const dx = s.x - cx, dy = s.y - cy;
        const distSq = dx * dx + dy * dy;
        if (s.life >= s.maxLife || distSq < 16 || s.x < -20 || s.x > w + 20 || s.y < -20 || s.y > h + 20) {
          respawn(s, w, h);
        }
        const t = s.life / s.maxLife;
        const env = t < 0.5 ? t * 2 : (1 - t) * 2;
        const alpha = Math.max(0, Math.min(0.9, env));
        ctx.beginPath();
        ctx.fillStyle = `rgba(255,255,255,${alpha})`;
        ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
        ctx.fill();
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [count]);

  return <canvas ref={ref} className={className} aria-hidden />;
}

function makeStars(n: number, canvas: HTMLCanvasElement): Star[] {
  const out: Star[] = [];
  const w = canvas.clientWidth || 800;
  const h = canvas.clientHeight || 600;
  for (let i = 0; i < n; i++) {
    const s: Star = { x: 0, y: 0, vx: 0, vy: 0, r: 0, life: 0, maxLife: 1 };
    respawn(s, w, h);
    out.push(s);
  }
  return out;
}

function respawn(s: Star, w: number, h: number) {
  const cx = w / 2, cy = h / 2;
  s.x = Math.random() * w;
  s.y = Math.random() * h;
  const dx = cx - s.x;
  const dy = cy - s.y;
  const dist = Math.max(1, Math.hypot(dx, dy));
  const speed = 110 + Math.random() * 110;
  s.vx = (dx / dist) * speed;
  s.vy = (dy / dist) * speed;
  s.r = 0.6 + Math.random() * 1.1;
  s.life = 0;
  s.maxLife = 0.6 + Math.random() * 0.8;
}
