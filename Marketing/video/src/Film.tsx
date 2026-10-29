// The ~3 minute competition film. Scenes and wording follow docs/pitch/script.md.
// Look: warm black, serif headlines, film grain; the phone's "sight" is drawn as abstract points and light.
import React, {useEffect, useState} from 'react';
import {
  AbsoluteFill, Audio, Easing, Img, Loop, OffthreadVideo, Sequence, continueRender, delayRender, interpolate, random,
  staticFile, useCurrentFrame,
} from 'remotion';

const FPS = 30;
export const s = (x: number) => Math.round(x * FPS);
export const C = {bg: '#0D0C0A', fg: '#EDE8E0', dim: '#8C857A', faint: '#4A463F', mint: '#40F2C4', warm: '#E8B77A'};
export const SERIF = '"Songti SC", "STSong", serif';
export const SANS = '"PingFang SC", -apple-system, sans-serif';
const ease = Easing.bezier(0.33, 0, 0.2, 1);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

// [start s, end s]
const SCENES = {open: [0, 11], street: [11, 34], cane: [34, 52], turn: [52, 62], sees: [62, 84], guide: [84, 98],
  read: [98, 126], honest: [126, 152], end: [152, 172]} as const;
export const TOTAL = s(172);

// Voice lines: id and start (s). Lengths come from prepare.sh's printout.
const VO: [string, number, number][] = [
  ['v1', 2, 6.1], ['v2', 12, 6], ['v3', 20, 7.1], ['v4', 36, 10.4], ['v5', 54, 4.9], ['v6', 64, 10.3], ['v7', 86, 6.8],
  ['v8', 100, 10.6], ['v9', 113, 6.3], ['v10', 128, 7.2], ['v11', 138, 8.2], ['v12', 154, 5.2],
];

export const amount = (f: number, a: number, d = 24) => interpolate(f, [a, a + d], [0, 1], {...clamp, easing: ease});
// Comes into focus at frame a, goes at b.
export const soft = (f: number, a: number, b = Infinity, d = 30): React.CSSProperties => {
  const i = amount(f, a, d);
  const o = b === Infinity ? 1 : 1 - amount(f, b, d);
  return {opacity: i * o, filter: `blur(${(1 - i) * 8}px)`, transform: `translateY(${(1 - i) * 12}px)`};
};

export const Line = ({size = 64, serif = true, color = C.fg, weight, style, children}: {
  size?: number; serif?: boolean; color?: string; weight?: number; style?: React.CSSProperties; children: React.ReactNode;
}) => (
  <div style={{fontFamily: serif ? SERIF : SANS, fontSize: size, fontWeight: weight ?? (serif ? 400 : 300), color,
    lineHeight: 1.5, letterSpacing: serif ? 2 : 1, ...style}}>{children}</div>
);

export const Grain = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{pointerEvents: 'none'}}>
      <AbsoluteFill style={{backgroundImage: `url(${staticFile('img/grain.png')})`, opacity: 0.07, mixBlendMode: 'screen',
        backgroundPosition: `${Math.floor(random(`gx${f}`) * 512)}px ${Math.floor(random(`gy${f}`) * 512)}px`}} />
      <AbsoluteFill style={{background: 'radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,.55) 100%)'}} />
    </AbsoluteFill>
  );
};

// Edge points of a street frame (prepare.sh), normalised to 0..1 in a 3:4 portrait frame.
export const usePoints = () => {
  const [pts, setPts] = useState<[number, number][] | null>(null);
  const [handle] = useState(() => delayRender('street points'));
  useEffect(() => {
    fetch(staticFile('street-points.json')).then((r) => r.json()).then((p) => { setPts(p); continueRender(handle); });
  }, [handle]);
  return pts ?? [];
};
const FIELD = {x: 960 - 405, y: 0, w: 810, h: 1080};
const at = ([x, y]: [number, number]) => [FIELD.x + x * FIELD.w, FIELD.y + y * FIELD.h];

// ---------- open ----------
const Open = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <Line size={30} serif={false} color={C.dim} style={soft(f, s(1), s(9))}>2026 年 10 月 28 日</Line>
      <Line size={72} style={{marginTop: 24, ...soft(f, s(2.4), s(9))}}>十月底，一个晚上。</Line>
    </AbsoluteFill>
  );
};

// ---------- street ----------
const Panel = ({name, from, x, w = 720, h = 960, y = 60, rate = 0.8}: {
  name: string; from: number; x: number; w?: number; h?: number; y?: number; rate?: number;
}) => {
  const f = useCurrentFrame();
  const k = amount(f, from, 36);
  return (
    <div style={{position: 'absolute', left: x, top: y, width: w, height: h, overflow: 'hidden', opacity: k}}>
      <Sequence from={from} layout="none">
        <Loop durationInFrames={s(8.5)} layout="none">
          <OffthreadVideo src={staticFile(`footage/${name}.mp4`)} playbackRate={rate} muted
            style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${1 + 0.0004 * (f - from)})`,
              filter: 'saturate(.8) contrast(1.05)'}} />
        </Loop>
      </Sequence>
    </div>
  );
};
const Street = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(21.8), 36)}}>
      <Panel name="street1" from={0} x={1060} />
      <div style={{opacity: amount(f, s(10.5), 40)}}><Panel name="street2" from={s(10.5)} x={1060} /></div>
      <div style={{position: 'absolute', left: 180, top: 380, width: 760}}>
        <Line size={64} style={soft(f, s(1.5))}>盲道上，停满了车。</Line>
        <Line size={40} color={C.dim} style={{marginTop: 40, ...soft(f, s(9.5))}}>看得见的人，绕一下就过去了。</Line>
        <Line size={40} color={C.dim} style={soft(f, s(12.5))}>看不见的人，只能一点一点去碰。</Line>
      </div>
      <Line size={22} serif={false} color={C.faint} style={{position: 'absolute', left: 180, bottom: 80, ...soft(f, s(2))}}>
        实地录像，晚上九点前后
      </Line>
    </AbsoluteFill>
  );
};

// ---------- cane: only what the tip touches ----------
const Cane = () => {
  const f = useCurrentFrame();
  const pts = usePoints();
  const tapEvery = 22;
  const taps = Array.from({length: Math.floor(f / tapEvery) + 1}, (_, i) => {
    const t = i * tapEvery;
    return {t, x: 0.3 + 0.4 * (0.5 + 0.5 * Math.sin(i * 0.9)), y: 0.86 + 0.04 * Math.cos(i * 1.7)};
  }).filter((p) => f - p.t < 50);
  const out = 1 - amount(f, s(16.6), 36);
  return (
    <AbsoluteFill style={{opacity: out}}>
      <svg width={1920} height={1080}>
        {pts.map((p, i) => {
          let a = 0;
          for (const t of taps) {
            const d = Math.hypot((p[0] - t.x) * 0.75, p[1] - t.y);
            if (d < 0.11) a = Math.max(a, (1 - d / 0.11) * (1 - (f - t.t) / 50));
          }
          if (a <= 0.01) return null;
          const [x, y] = at(p);
          return <circle key={i} cx={x} cy={y} r={2.2} fill={C.fg} opacity={a} />;
        })}
        {taps.map((t) => {
          const k = (f - t.t) / 50;
          const [x, y] = at([t.x, t.y]);
          return <circle key={t.t} cx={x} cy={y} r={6 + 90 * k} fill="none" stroke={C.fg} strokeWidth={1.5} opacity={(1 - k) * 0.5} />;
        })}
      </svg>
      <div style={{position: 'absolute', left: 180, top: 140}}>
        <Line size={56} style={soft(f, s(1))}>一根杖，能碰到的</Line>
        <Line size={56} style={soft(f, s(2.2))}>大约是脚前一米。</Line>
      </div>
      <Line size={26} serif={false} color={C.dim} style={{position: 'absolute', left: 180, bottom: 120, ...soft(f, s(3))}}>
        中国约有 1731 万视障人士，在岗导盲犬约 410 只。
      </Line>
      <Line size={18} serif={false} color={C.faint} style={{position: 'absolute', left: 180, bottom: 84, ...soft(f, s(3))}}>
        中国盲人协会，见央视《东方时空》2024 年 4 月、新华社 2025 年 5 月
      </Line>
    </AbsoluteFill>
  );
};

// ---------- the phone's sight: the same street, all at once ----------
// A gentle path through the open part of the frame, in field coordinates.
const ROUTE: [number, number][] = [[0.5, 1.02], [0.54, 0.86], [0.63, 0.72], [0.64, 0.6], [0.58, 0.48], [0.55, 0.38]];
const curve = (q: [number, number][]) => q.map(at).reduce((d, p, i, all) => {
  if (i === 0) return `M${p[0]},${p[1]}`;
  const [px, py] = all[i - 1];
  const mx = (px + p[0]) / 2, my = (py + p[1]) / 2;
  return `${d} Q${px},${py} ${mx},${my}` + (i === all.length - 1 ? ` L${p[0]},${p[1]}` : '');
}, '');

export const Sight = ({f, reach, route, pulses = true, gain = 1}: {f: number; reach: number; route: number; pulses?: boolean; gain?: number}) => {
  const pts = usePoints();
  // reach: 0..1 radius of what is seen, grown from the bottom centre.
  const band = pulses ? (f % 30) / 30 : -1;
  return (
    <svg width={1920} height={1080} style={{position: 'absolute'}}>
      <defs><filter id="bloom"><feGaussianBlur stdDeviation="10" /></filter></defs>
      {pts.map((p, i) => {
        const d = Math.hypot((p[0] - 0.5) * 0.75, p[1] - 1);
        if (d > reach * 1.25) return null;
        const edge = Math.min(1, (reach * 1.25 - d) / 0.15);
        const lit = band >= 0 && Math.abs(1 - p[1] - band) < 0.04 ? 0.5 : 0;
        const [x, y] = at(p);
        const ground = p[1] > 0.62 && Math.abs(p[0] - 0.6) < 0.22;
        return <circle key={i} cx={x} cy={y} r={ground ? 1.6 : 2.2}
          fill={ground ? C.mint : C.warm} opacity={Math.min(1, (0.35 + lit) * edge * (ground ? 0.6 : 0.9) * gain)} />;
      })}
      <path d={curve(ROUTE)} fill="none" stroke={C.mint} strokeWidth={22} strokeLinecap="round" pathLength={1}
        strokeDasharray="1 1" strokeDashoffset={1 - route} opacity={0.35} filter="url(#bloom)" />
      <path d={curve(ROUTE)} fill="none" stroke={C.mint} strokeWidth={4} strokeLinecap="round" pathLength={1}
        strokeDasharray="1 1" strokeDashoffset={1 - route} opacity={0.9} />
    </svg>
  );
};

const Turn = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Sight f={f} reach={interpolate(f, [s(2), s(8)], [0, 1.1], {...clamp, easing: ease})} route={0} pulses={false} />
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', background: `rgba(13,12,10,${0.55 * (1 - amount(f, s(6), 60))})`}}>
        <Line size={64} style={soft(f, s(1.5), s(7.5))}>如果手机能替他，先看一眼。</Line>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const Sees = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(20.8), 36)}}>
      <Sight f={f} reach={1.1} route={amount(f, s(7), s(2.5))} />
      <div style={{position: 'absolute', left: 140, top: 380, width: 420}}>
        <Line size={26} serif={false} color={C.mint} style={soft(f, s(1))}>每秒十次</Line>
        <Line size={44} style={{marginTop: 18, ...soft(f, s(1.6))}}>量一量前面的路。</Line>
      </div>
      <div style={{position: 'absolute', right: 140, top: 380, width: 420, textAlign: 'right'}}>
        <Line size={26} serif={false} color={C.warm} style={soft(f, s(4.5))}>哪里有东西挡着</Line>
        <Line size={26} serif={false} color={C.mint} style={{marginTop: 14, ...soft(f, s(7))}}>哪里走得过去</Line>
      </div>
      <Line size={18} serif={false} color={C.faint} style={{position: 'absolute', width: '100%', textAlign: 'center', bottom: 50, ...soft(f, s(1))}}>
        点取自实地录像的一帧，路线为示意
      </Line>
    </AbsoluteFill>
  );
};

// ---------- guide: sound and a nudge from one side ----------
const Guide = () => {
  const f = useCurrentFrame();
  const ring = (k: number) => ((f + k * 30) % 90) / 90;
  const nudge = (side: number) => {
    const start = side < 0 ? s(5.5) : s(9);
    if (f < start) return 0;
    const t = (f - start) % 24;
    return f - start < 72 ? Math.max(0, 1 - t / 16) : 0;
  };
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(12.8), 36)}}>
      <svg width={1920} height={1080}>
        <defs><filter id="soft"><feGaussianBlur stdDeviation="14" /></filter></defs>
        {f > s(1) && [0, 1, 2].map((k) => (
          <circle key={k} cx={960} cy={560} r={40 + 360 * ring(k)} fill="none" stroke={C.fg} strokeWidth={1.2}
            opacity={(1 - ring(k)) * 0.45 * amount(f, s(1), 40)} />
        ))}
        <circle cx={960} cy={560} r={14} fill={C.fg} opacity={amount(f, s(0.5))} />
        {[-1, 1].map((side) => (
          <g key={side} opacity={nudge(side)}>
            <rect x={side < 0 ? 0 : 1880} y={260} width={40} height={600} fill={C.mint} filter="url(#soft)" />
            <rect x={side < 0 ? 0 : 1914} y={300} width={6} height={520} rx={3} fill={C.mint} />
          </g>
        ))}
      </svg>
      <Line size={48} style={{position: 'absolute', width: '100%', textAlign: 'center', top: 160, ...soft(f, s(1.5))}}>
        用声音说，用震动轻轻推一下。
      </Line>
      <Line size={26} serif={false} color={C.dim} style={{position: 'absolute', width: '100%', textAlign: 'center', bottom: 150, ...soft(f, s(5.5))}}>
        左边震，往左；右边震，往右。
      </Line>
    </AbsoluteFill>
  );
};

// ---------- describe and read ----------
const Glyphs = ({f, text, from, x, y, size}: {f: number; text: string; from: number; x: number; y: number; size: number}) => (
  <div style={{position: 'absolute', left: x, top: y}}>
    {Array.from(text).map((ch, i) => {
      const k = interpolate(f, [from + i * 2, from + i * 2 + 40], [0, 1], {...clamp, easing: ease});
      const dx = (random(`dx${text}${i}`) - 0.5) * 1400, dy = (random(`dy${text}${i}`) - 0.5) * 800;
      return (
        <span key={i} style={{position: 'absolute', left: i * size * 1.02, fontFamily: SERIF, fontSize: size, color: C.fg,
          opacity: k, transform: `translate(${dx * (1 - k)}px, ${dy * (1 - k)}px) rotate(${(1 - k) * 90 * (random(`r${i}`) - 0.5)}deg)`}}>
          {ch}
        </span>
      );
    })}
  </div>
);
const Read = () => {
  const f = useCurrentFrame();
  const photo = amount(f, s(0.5), 40) * (1 - amount(f, s(4), 60));
  const said = '正前方是一条木地板走廊，左手边靠墙放着鞋架和绿植。';
  const paper = '本周三下午三点，社区活动室有义诊。';
  return (
    <AbsoluteFill>
      <Img src={staticFile('img/hall.jpg')} style={{position: 'absolute', left: 660, top: 140, width: 600, height: 800, objectFit: 'cover',
        opacity: photo, filter: `blur(${amount(f, s(3.5), 60) * 30}px)`, transform: `scale(${1 + amount(f, s(3.5), 60) * 0.15})`}} />
      <div style={{opacity: 1 - amount(f, s(10.5), 30)}}>
        <Line size={26} serif={false} color={C.dim} style={{position: 'absolute', left: 280, top: 400, ...soft(f, s(1))}}>按一下屏幕</Line>
        <Glyphs f={f} text={said} from={s(4.5)} x={280} y={470} size={52} />
      </div>
      <div style={{opacity: amount(f, s(10.5), 30) * (1 - amount(f, s(14.6), 30))}}>
        <Line size={26} serif={false} color={C.dim} style={{position: 'absolute', left: 280, top: 400}}>三根手指按住</Line>
        <Glyphs f={f} text={paper} from={s(11)} x={280} y={470} size={52} />
      </div>
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
        <Line size={56} style={soft(f, s(15.5), s(26))}>不用联网，照片也不出手机。</Line>
        <Line size={24} serif={false} color={C.faint} style={{marginTop: 30, ...soft(f, s(16.5), s(26))}}>
          避障和读字在手机上完成；描述画面需要联网
        </Line>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ---------- honest ----------
const Honest = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(24.8), 36)}}>
      <Panel name="station" from={0} x={1000} w={600} h={800} y={140} rate={0.6} />
      <div style={{position: 'absolute', left: 200, top: 340, width: 700}}>
        <Line size={64} style={soft(f, s(1.5))}>它还不完美。</Line>
        <Line size={36} color={C.dim} style={{marginTop: 36, ...soft(f, s(4.5))}}>夜里光线暗，会看漏。</Line>
        <Line size={36} color={C.dim} style={soft(f, s(6.5))}>遇到台阶，还认不出来。</Line>
        <Line size={36} style={{marginTop: 60, ...soft(f, s(12))}}>每次回来，一帧一帧再过一遍。</Line>
        <Line size={26} serif={false} color={C.dim} style={{marginTop: 18, ...soft(f, s(16))}}>看漏了不行，乱报也不行。</Line>
      </div>
      <Line size={20} serif={false} color={C.faint} style={{position: 'absolute', left: 1000, top: 960, ...soft(f, s(2))}}>
        地铁站口的台阶，2026 年 10 月 28 日
      </Line>
    </AbsoluteFill>
  );
};

// ---------- end ----------
const End = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(18.6), 40)}}>
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
        <Line size={56} style={soft(f, s(1.5), s(7.5))}>接下来，想请视障朋友</Line>
        <Line size={56} style={soft(f, s(2.5), s(7.5))}>跟我们一起走，一起改。</Line>
      </AbsoluteFill>
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', ...soft(f, s(9), s(14.5))}}>
        <Img src={staticFile('img/icon.png')} style={{width: 120, height: 120, borderRadius: 27}} />
        <Line size={44} serif={false} weight={500} style={{marginTop: 30, letterSpacing: 14}}>PRTS</Line>
        <Line size={24} serif={false} color={C.dim} style={{marginTop: 10}}>一个帮视障朋友出门的 iPhone App</Line>
      </AbsoluteFill>
      <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', ...soft(f, s(15))}}>
        <Line size={20} serif={false} color={C.dim} style={{textAlign: 'center', lineHeight: 2}}>
          音乐 "Clean Soul" Kevin MacLeod（incompetech.com），CC BY 4.0<br />配音为合成语音
        </Line>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const PARTS: Record<keyof typeof SCENES, () => React.ReactElement> = {
  open: Open, street: Street, cane: Cane, turn: Turn, sees: Sees, guide: Guide, read: Read, honest: Honest, end: End,
};

const musicVolume = (f: number) => {
  const t = f / FPS;
  const duck = Math.max(...VO.map(([, a, d]) => interpolate(t, [a - 0.6, a - 0.1, a + d + 0.1, a + d + 0.8], [0, 1, 1, 0], clamp)));
  const edge = Math.min(interpolate(t, [0, 3], [0, 1], clamp), interpolate(t, [166, 172], [1, 0], clamp));
  return (0.9 - 0.55 * duck) * edge;
};

export const PRTSFilm = () => (
  <AbsoluteFill style={{background: C.bg}}>
    {Object.entries(SCENES).map(([name, [a, b]]) => {
      const Part = PARTS[name as keyof typeof SCENES];
      return <Sequence key={name} from={s(a)} durationInFrames={s(b - a)}><Part /></Sequence>;
    })}
    <Grain />
    <Audio src={staticFile('music.mp3')} volume={musicVolume} />
    {VO.map(([id, a]) => (
      <Sequence key={id} from={s(a)}><Audio src={staticFile(`vo/${id}.wav`)} /></Sequence>
    ))}
  </AbsoluteFill>
);
