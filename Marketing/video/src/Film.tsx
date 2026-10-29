// The ~3 minute competition film. Scene list and wording follow docs/pitch/script.md.
import React from 'react';
import {
  AbsoluteFill, Audio, Easing, Img, Loop, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame,
} from 'remotion';

const FPS = 30;
export const s = (x: number) => Math.round(x * FPS);
export const C = {fg: '#F5F5F7', dim: '#86868B', mint: '#40F2C4', blue: '#6CC6FF', warn: '#FF7A59', screen: '#060B13'};
export const FONT = '"PingFang SC", -apple-system, "Helvetica Neue", sans-serif';
const ease = Easing.bezier(0.25, 0.1, 0.25, 1);
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

// [scene, start s, end s]
const SCENES = {open: [0, 10], stats: [10, 26], cane: [26, 42], reveal: [42, 54], how: [54, 80], states: [80, 96],
  numbers: [96, 108], photo: [108, 128], field: [128, 150], end: [150, 168]} as const;
export const TOTAL = s(168);

// Voice lines: start (s) and length (s) of public/vo/<id>.wav.
const VO: [string, number, number][] = [
  ['v1', 11, 4.2], ['v2', 18.5, 3.7], ['v3', 27.5, 8.2], ['v4', 47.5, 2.9], ['v5', 56, 10], ['v6', 82, 7.1],
  ['v7', 98.5, 3.5], ['v8', 110.5, 6.1], ['v9', 132, 7.5], ['v10', 153.5, 4.3],
];

const amount = (f: number, a: number, d = 18) => interpolate(f, [a, a + d], [0, 1], {...clamp, easing: ease});
// Fades and rises in at frame a, fades out at b.
export const reveal = (f: number, a: number, b = Infinity, rise = 30): React.CSSProperties => {
  const i = amount(f, a);
  const o = b === Infinity ? 1 : 1 - amount(f, b);
  return {opacity: i * o, transform: `translateY(${(1 - i) * rise}px)`};
};

const gradient = (from: string, to: string): React.CSSProperties => ({
  background: `linear-gradient(90deg, ${from}, ${to})`, WebkitBackgroundClip: 'text', color: 'transparent',
});
export const MINT = gradient(C.mint, C.blue);
const SILVER = gradient('#FFFFFF', '#9A9AA0');

export const Center = ({children, style}: {children: React.ReactNode; style?: React.CSSProperties}) => (
  <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', ...style}}>{children}</AbsoluteFill>
);
export const Text = ({size, weight = 600, color = C.fg, style, children}: {
  size: number; weight?: number; color?: string; style?: React.CSSProperties; children: React.ReactNode;
}) => (
  <div style={{fontFamily: FONT, fontSize: size, fontWeight: weight, color, letterSpacing: size > 80 ? -2 : 0,
    lineHeight: 1.15, textAlign: 'center', ...style}}>{children}</div>
);

export const Phone = ({h, style, children}: {h: number; style?: React.CSSProperties; children: React.ReactNode}) => {
  const w = h * 0.4615;
  const pad = h * 0.014;
  return (
    <div style={{position: 'absolute', width: w, height: h, borderRadius: h * 0.115, background: '#1d1d1f', padding: pad,
      boxSizing: 'border-box', boxShadow: '0 60px 140px rgba(0,0,0,.7), inset 0 0 0 3px #3a3a3c', ...style}}>
      <div style={{position: 'relative', width: '100%', height: '100%', borderRadius: h * 0.1, overflow: 'hidden', background: C.screen}}>
        {children}
        <div style={{position: 'absolute', top: pad * 1.2, left: '50%', width: w * 0.3, height: h * 0.034,
          marginLeft: -w * 0.15, borderRadius: 99, background: '#000'}} />
      </div>
    </div>
  );
};

// ---------- 1. Cold open ----------
const Open = () => {
  const f = useCurrentFrame();
  return (
    <Center>
      <Text size={84} weight={500} style={{position: 'absolute', ...reveal(f, s(1.2), s(4.2))}}>闭上眼睛。</Text>
      <Text size={84} weight={500} style={{position: 'absolute', ...reveal(f, s(5.2), s(8.6))}}>走到门口。</Text>
    </Center>
  );
};

// ---------- 2. Numbers that frame the problem ----------
const Count = ({f, at, to, suffix, label, out}: {f: number; at: number; to: number; suffix: string; label: string; out: number}) => {
  const n = Math.round(to * interpolate(f, [at, at + s(1.6)], [0, 1], {...clamp, easing: Easing.out(Easing.cubic)}));
  return (
    <Center style={reveal(f, at, out)}>
      <Text size={300} style={{...SILVER, fontVariantNumeric: 'tabular-nums'}}>{n}{suffix}</Text>
      <Text size={56} weight={500} color={C.dim} style={{marginTop: 20}}>{label}</Text>
    </Center>
  );
};
export const Stats = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Count f={f} at={s(0.8)} to={1731} suffix="万" label="中国视障人士" out={s(7.6)} />
      <Count f={f} at={s(8.4)} to={410} suffix="" label="在岗导盲犬" out={s(15)} />
      <Text size={22} weight={400} color="#555" style={{position: 'absolute', bottom: 60, width: '100%', ...reveal(f, s(1), s(15), 0)}}>
        数据：中国盲人协会（央视《东方时空》2024 年 4 月；新华社 2025 年 5 月）
      </Text>
    </AbsoluteFill>
  );
};

// ---------- 3. What a cane can tell ----------
export const Cane = () => {
  const f = useCurrentFrame();
  const draw = amount(f, s(0.6), s(1.4));
  const all = 1 - amount(f, s(14.6));
  const ripple = (k: number) => ((f - s(2) + k * 20) % 60) / 60;
  return (
    <AbsoluteFill style={{opacity: all}}>
      <svg width={1920} height={1080}>
        <defs>
          <linearGradient id="fog" x1="0" x2="1">
            <stop offset="0" stopColor="#000" stopOpacity="0" />
            <stop offset="1" stopColor="#000" stopOpacity="1" />
          </linearGradient>
        </defs>
        <line x1={240} y1={760} x2={1680} y2={760} stroke="#333" strokeWidth={2} style={{opacity: amount(f, s(0.2))}} />
        <circle cx={520} cy={560} r={34} fill={C.fg} style={{opacity: amount(f, s(0.2))}} />
        <line x1={520} y1={600} x2={520} y2={760} stroke={C.fg} strokeWidth={10} strokeLinecap="round" style={{opacity: amount(f, s(0.2))}} />
        <line x1={540} y1={640} x2={540 + 300 * draw} y2={640 + 120 * draw} stroke={C.mint} strokeWidth={6} strokeLinecap="round" />
        {f > s(2) && [0, 1, 2].map((k) => (
          <circle key={k} cx={840} cy={760} r={10 + 70 * ripple(k)} fill="none" stroke={C.mint} strokeWidth={3} opacity={(1 - ripple(k)) * 0.8} />
        ))}
        <g style={{opacity: amount(f, s(2.2))}}>
          <line x1={540} y1={810} x2={840} y2={810} stroke={C.dim} strokeWidth={2} />
          <text x={690} y={860} fill={C.dim} fontSize={34} fontFamily={FONT} textAnchor="middle">约 1 米</text>
        </g>
        <g style={{opacity: amount(f, s(4.6), 30)}}>
          {[[1080, 700, 120, 60], [1300, 640, 80, 120], [1520, 690, 140, 70]].map(([x, y, w, h], i) => (
            <rect key={i} x={x} y={y} width={w} height={h} rx={10} fill="none" stroke="#666" strokeWidth={3} strokeDasharray="10 10" />
          ))}
        </g>
        <rect x={880} y={0} width={1040} height={1080} fill="url(#fog)" opacity={0.85} />
      </svg>
      <Text size={72} style={{position: 'absolute', top: 170, width: '100%', ...reveal(f, s(1.6))}}>脚下一米。</Text>
      <Text size={72} color={C.dim} style={{position: 'absolute', top: 270, width: '100%', ...reveal(f, s(5.4))}}>再往前，是什么？</Text>
    </AbsoluteFill>
  );
};

// ---------- 4. Product reveal ----------
const Icon = ({f, at, size}: {f: number; at: number; size: number}) => {
  const k = amount(f, at, 30);
  return (
    <Img src={staticFile('img/icon.png')} style={{width: size, height: size, borderRadius: size * 0.225, opacity: k,
      transform: `scale(${0.86 + 0.14 * k})`, boxShadow: `0 0 ${160 * k}px rgba(64,242,196,${0.35 * k})`}} />
  );
};
export const Reveal = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Center style={{opacity: 1 - amount(f, s(4.8))}}>
        <Icon f={f} at={s(0.6)} size={240} />
        <Text size={96} style={{marginTop: 50, letterSpacing: 18, ...reveal(f, s(2))}}>PRTS</Text>
      </Center>
      <Center style={reveal(f, s(5.4), s(11))}>
        <Text size={130} style={MINT}>一部 iPhone，就够了。</Text>
      </Center>
    </AbsoluteFill>
  );
};

// ---------- 5. How guidance works ----------
// Simple pinhole looking along the ground; screen space of the phone SVG is 400 x 866.
const P = (x: number, z: number, y = 0): [number, number] => [200 + (330 * x) / z, 270 + (330 * (1.4 - y)) / z];
const rand = (i: number) => {
  const v = Math.sin(i * 127.1 + 311.7) * 43758.5453;
  return v - Math.floor(v);
};
const BOXES = [{x: 0.3, z: 3.2, w: 0.8, d: 0.5, h: 0.9}, {x: -1.7, z: 5.6, w: 0.35, d: 0.35, h: 0.8}];
const GROUND_DOTS = Array.from({length: 260}, (_, i) => ({x: -2.6 + 5.2 * rand(i), z: 0.9 + 7 * rand(i + 999)}))
  .filter((p) => !BOXES.some((b) => Math.abs(p.x - b.x) < b.w / 2 && Math.abs(p.z - b.z) < b.d / 2));
const BOX_DOTS = BOXES.flatMap((b, j) => Array.from({length: 40}, (_, i) => ({
  x: b.x - b.w / 2 + b.w * rand(i + 50 * j + 5000), z: b.z - b.d / 2, y: b.h * rand(i + 50 * j + 7000),
})));
const ROUTE: [number, number][] = [[0, 1.1], [-0.2, 1.9], [-0.7, 2.8], [-0.8, 3.6], [-0.75, 5], [-0.7, 8]];
const smooth = (pts: [number, number][]) => pts.reduce((d, p, i) => {
  if (i === 0) return `M${p[0]},${p[1]}`;
  const q = pts[i - 1];
  const m = [(q[0] + p[0]) / 2, (q[1] + p[1]) / 2];
  return `${d} Q${q[0]},${q[1]} ${m[0]},${m[1]}` + (i === pts.length - 1 ? ` L${p[0]},${p[1]}` : '');
}, '');

const Box = ({b, lit}: {b: typeof BOXES[number]; lit: number}) => {
  const l = b.x - b.w / 2, r = b.x + b.w / 2, n = b.z - b.d / 2, fz = b.z + b.d / 2;
  const front = [P(l, n), P(r, n), P(r, n, b.h), P(l, n, b.h)];
  const top = [P(l, n, b.h), P(r, n, b.h), P(r, fz, b.h), P(l, fz, b.h)];
  const pts = (q: [number, number][]) => q.map((p) => p.join(',')).join(' ');
  return (
    <g opacity={lit}>
      <polygon points={pts(top)} fill="rgba(255,122,89,.18)" stroke={C.warn} strokeWidth={2} />
      <polygon points={pts(front)} fill="rgba(255,122,89,.28)" stroke={C.warn} strokeWidth={2.5} />
    </g>
  );
};

const GuidanceScreen = ({f}: {f: number}) => {
  const grid = amount(f, s(1), 30) * 0.5;
  const scanZ = interpolate(f, [s(2), s(4.5)], [0.6, 9], clamp);
  const sorted = amount(f, s(4.6), 24);
  const route = amount(f, s(7), s(1.6));
  const pulse = f > s(9.6) ? Math.max(0, 1 - ((f - s(9.6)) % 30) / 18) : 0;
  const lines: React.ReactNode[] = [];
  for (let z = 1; z <= 9; z += 0.5) {
    const [x1, y] = P(-5, z); const [x2] = P(5, z);
    lines.push(<line key={`z${z}`} x1={x1} y1={y} x2={x2} y2={y} stroke={C.mint} strokeWidth={0.8} opacity={grid * (1.2 - z / 9)} />);
  }
  for (let x = -3; x <= 3; x += 0.5) {
    const a = P(x, 0.7); const b = P(x, 9);
    lines.push(<line key={`x${x}`} x1={a[0]} y1={a[1]} x2={b[0]} y2={b[1]} stroke={C.mint} strokeWidth={0.8} opacity={grid * 0.6} />);
  }
  const routeD = smooth(ROUTE.map(([x, z]) => P(x, z)));
  return (
    <svg viewBox="0 0 400 866" preserveAspectRatio="xMidYMid slice" style={{width: '100%', height: '100%'}}>
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#0B1422" /><stop offset="0.38" stopColor="#060B13" /><stop offset="1" stopColor="#0A1A1C" />
        </linearGradient>
        <filter id="glow"><feGaussianBlur stdDeviation="6" /></filter>
      </defs>
      <rect width={400} height={866} fill="url(#sky)" />
      {lines}
      {GROUND_DOTS.map((p, i) => {
        if (p.z > scanZ) return null;
        const [x, y] = P(p.x, p.z);
        return <circle key={i} cx={x} cy={y} r={Math.max(1, 3.2 / p.z * 1.6)} fill={sorted > 0 ? C.mint : '#fff'} opacity={0.85 - 0.55 * sorted} />;
      })}
      {BOX_DOTS.map((p, i) => {
        if (p.z > scanZ) return null;
        const [x, y] = P(p.x, p.z, p.y);
        return <circle key={`b${i}`} cx={x} cy={y} r={1.8} fill={sorted > 0.5 ? C.warn : '#fff'} opacity={0.9} />;
      })}
      <path d={routeD} fill="none" stroke={C.mint} strokeWidth={14} strokeLinecap="round" pathLength={1}
        strokeDasharray="1 1" strokeDashoffset={1 - route} opacity={0.5} filter="url(#glow)" />
      <path d={routeD} fill="none" stroke={C.mint} strokeWidth={7} strokeLinecap="round" pathLength={1}
        strokeDasharray="1 1" strokeDashoffset={1 - route} />
      {BOXES.map((b, i) => <Box key={i} b={b} lit={sorted} />)}
      <rect x={0} y={220} width={18} height={420} rx={9} fill={C.mint} opacity={pulse} filter="url(#glow)" />
      <rect x={0} y={220} width={8} height={420} rx={4} fill={C.mint} opacity={pulse} />
    </svg>
  );
};

const STEPS = [
  ['测距', '激光雷达测出每个点有多远'],
  ['识别', '找出地面，标出障碍'],
  ['规划', '算出一条能走的路'],
  ['引导', '语音提示，左右震动指方向'],
];
export const How = () => {
  const f = useCurrentFrame();
  const at = [s(2), s(4.6), s(7), s(9.6)];
  const active = at.filter((a) => f >= a).length - 1;
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(24.6))}}>
      <Phone h={900} style={{left: 420, top: 90, ...reveal(f, s(0.2), Infinity, 60)}}>
        <GuidanceScreen f={f} />
      </Phone>
      <div style={{position: 'absolute', left: 1000, top: 250}}>
        <Text size={30} weight={600} color={C.mint} style={{textAlign: 'left', ...reveal(f, s(0.6))}}>避障引导</Text>
        <Text size={64} style={{textAlign: 'left', marginTop: 14, ...reveal(f, s(0.8))}}>每秒十次，看清脚下的路。</Text>
        <div style={{marginTop: 60}}>
          {STEPS.map(([t, d], i) => (
            <div key={t} style={{display: 'flex', alignItems: 'baseline', marginBottom: 34, ...reveal(f, at[i], Infinity, 20)}}>
              <Text size={40} color={i === active ? C.mint : C.fg} style={{width: 110, textAlign: 'left'}}>{t}</Text>
              <Text size={34} weight={400} color={i === active ? C.fg : C.dim} style={{textAlign: 'left'}}>{d}</Text>
            </div>
          ))}
        </div>
      </div>
      <Text size={22} weight={400} color="#555" style={{position: 'absolute', bottom: 40, width: '100%', ...reveal(f, s(1), Infinity, 0)}}>
        示意动画
      </Text>
    </AbsoluteFill>
  );
};

// ---------- 6. Three situations ----------
const StateIcon = ({kind}: {kind: number}) => (
  <svg width={240} height={150} viewBox="0 0 240 150">
    {kind === 0 && <path d="M30 75 H200" stroke={C.mint} strokeWidth={8} strokeLinecap="round" />}
    {kind === 0 && <path d="M180 55 L205 75 L180 95" fill="none" stroke={C.mint} strokeWidth={8} strokeLinecap="round" strokeLinejoin="round" />}
    {kind === 1 && <path d="M30 75 H140" stroke={C.mint} strokeWidth={8} strokeLinecap="round" strokeDasharray="2 18" />}
    {kind === 1 && <rect x={170} y={45} width={50} height={60} rx={10} fill="none" stroke={C.warn} strokeWidth={6} />}
    {kind === 2 && <rect x={105} y={55} width={44} height={50} rx={10} fill="none" stroke={C.warn} strokeWidth={6} />}
    {kind === 2 && <path d="M25 95 C70 95 70 25 127 25 S185 95 220 95" fill="none" stroke={C.mint} strokeWidth={8} strokeLinecap="round" />}
  </svg>
);
export const States = () => {
  const f = useCurrentFrame();
  const cards = [['前方畅通', '只做播报'], ['障碍较远', '先引导你走近'], ['障碍很近', '逐点绕过去']];
  const at = [s(2), s(4), s(6.2)];
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(14.6))}}>
      <Text size={72} style={{position: 'absolute', top: 160, width: '100%', ...reveal(f, s(0.3))}}>三种情况，三种带法。</Text>
      <div style={{position: 'absolute', top: 380, width: '100%', display: 'flex', justifyContent: 'center', gap: 48}}>
        {cards.map(([t, d], i) => (
          <div key={t} style={{width: 480, height: 440, borderRadius: 40, background: '#101012', border: '1px solid #222',
            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', ...reveal(f, at[i], Infinity, 40)}}>
            <StateIcon kind={i} />
            <Text size={52} style={{marginTop: 40}}>{t}</Text>
            <Text size={34} weight={400} color={C.dim} style={{marginTop: 16}}>{d}</Text>
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ---------- 7. Numbers ----------
export const Numbers = () => {
  const f = useCurrentFrame();
  const cols: [string, string, string, number][] = [
    ['10', '次/秒', '持续分析', s(2.4)],
    ['48', '毫秒', '95% 的结果在这之内送到', s(3.6)],
    ['0', '次联网', '避障全程在手机上完成', s(5)],
  ];
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(11))}}>
      <Text size={64} style={{position: 'absolute', top: 200, width: '100%', ...reveal(f, s(0.5))}}>快，也不靠网络。</Text>
      <div style={{position: 'absolute', top: 400, width: '100%', display: 'flex', justifyContent: 'center', gap: 160}}>
        {cols.map(([n, u, d, a]) => (
          <div key={u} style={{width: 420, ...reveal(f, a, Infinity, 40)}}>
            <div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'center'}}>
              <Text size={220} style={MINT}>{n}</Text>
              <Text size={48} weight={500} style={{marginLeft: 12}}>{u}</Text>
            </div>
            <Text size={30} weight={400} color={C.dim} style={{marginTop: 10}}>{d}</Text>
          </div>
        ))}
      </div>
      <Text size={22} weight={400} color="#555" style={{position: 'absolute', bottom: 60, width: '100%', ...reveal(f, s(2.4), Infinity, 0)}}>
        iPhone 17 Pro Max 实地测试，2026 年 10 月
      </Text>
    </AbsoluteFill>
  );
};

// ---------- 8. Describe and read ----------
const Bubble = ({f, at, children}: {f: number; at: number; children: React.ReactNode}) => (
  <div style={{position: 'absolute', left: 24, right: 24, bottom: 70, padding: '22px 26px', borderRadius: 28,
    background: 'rgba(30,30,32,.82)', backdropFilter: 'blur(20px)', ...reveal(f, at, Infinity, 20)}}>
    <Text size={26} weight={500} style={{textAlign: 'left', lineHeight: 1.5}}>{children}</Text>
  </div>
);
const Tap = ({f, at, x, y}: {f: number; at: number; x: number; y: number}) => {
  const k = interpolate(f, [at, at + 24], [0, 1], clamp);
  if (f < at) return null;
  return <div style={{position: 'absolute', left: x - 50, top: y - 50, width: 100, height: 100, borderRadius: 50,
    border: '4px solid #fff', opacity: 1 - k, transform: `scale(${0.4 + k})`}} />;
};
const Paper = ({f}: {f: number}) => {
  const straight = amount(f, s(8.6), 24);
  const scan = interpolate(f, [s(7), s(8.6)], [0, 1], clamp);
  const read = amount(f, s(9.4), 30);
  return (
    <div style={{position: 'absolute', inset: 0, background: '#2a2622'}}>
      <div style={{position: 'absolute', left: 60, top: 190, width: 280, height: 380, background: '#F2EFE8', borderRadius: 6,
        transform: `perspective(800px) rotateX(${18 * (1 - straight)}deg) rotateZ(${-8 * (1 - straight)}deg) scale(${1 + 0.08 * straight})`,
        boxShadow: '0 20px 60px rgba(0,0,0,.5)', overflow: 'hidden'}}>
        {Array.from({length: 11}, (_, i) => (
          <div key={i} style={{position: 'absolute', left: 30, top: 40 + i * 30, height: 10, borderRadius: 5,
            width: i === 0 ? 140 : 220 - (i % 3) * 30, background: i < 3 && read > 0 ? C.mint : '#B9B4AA',
            opacity: i < 3 ? 0.6 + 0.4 * read : 1}} />
        ))}
        {scan > 0 && scan < 1 && <div style={{position: 'absolute', left: 0, right: 0, top: scan * 380, height: 4, background: C.mint, boxShadow: `0 0 20px ${C.mint}`}} />}
      </div>
    </div>
  );
};
export const Photo = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(19))}}>
      <div style={{position: 'absolute', left: 430, top: 110, ...reveal(f, s(0.5))}}>
        <Text size={40} style={{width: 360}}>短按，描述画面</Text>
      </div>
      <Phone h={780} style={{left: 430, top: 200, ...reveal(f, s(0.5), Infinity, 60)}}>
        <Img src={staticFile('img/hall.jpg')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
        <Tap f={f} at={s(2.2)} x={180} y={390} />
        <Bubble f={f} at={s(3.6)}>正前方是一条木地板走廊，左边靠墙放着鞋架和绿植。</Bubble>
      </Phone>
      <div style={{position: 'absolute', left: 1130, top: 110, ...reveal(f, s(5.4))}}>
        <Text size={40} style={{width: 360}}>三指按住，读出文字</Text>
      </div>
      <Phone h={780} style={{left: 1130, top: 200, ...reveal(f, s(5.4), Infinity, 60)}}>
        <Paper f={f} />
        {[[120, 650], [180, 620], [240, 650]].map(([x, y], i) => f >= s(6.6) && (
          <div key={i} style={{position: 'absolute', left: x - 34, top: y - 34, width: 68, height: 68, borderRadius: 34,
            background: 'rgba(255,255,255,.35)', border: '3px solid #fff', opacity: 1 - amount(f, s(8.6))}} />
        ))}
        <Bubble f={f} at={s(9.6)}>本周三下午三点，社区活动室有义诊。</Bubble>
      </Phone>
      <Text size={24} weight={400} color="#555" style={{position: 'absolute', bottom: 40, width: '100%', ...reveal(f, s(10.5), Infinity, 0)}}>
        描述画面需要联网；读文字在手机上完成。界面为示意。
      </Text>
    </AbsoluteFill>
  );
};

// ---------- 9. Field footage ----------
const Clip = ({name, at, x}: {name: string; at: number; x: number}) => {
  const f = useCurrentFrame();
  return (
    <div style={{position: 'absolute', left: x, top: 330, width: 420, height: 560, borderRadius: 32, overflow: 'hidden',
      background: '#111', ...reveal(f, at, Infinity, 50)}}>
      <Sequence from={at} layout="none">
        <Loop durationInFrames={s(8.5)} layout="none">
          <OffthreadVideo src={staticFile(`footage/${name}.mp4`)} playbackRate={0.8} muted
            style={{width: '100%', height: '100%', objectFit: 'cover'}} />
        </Loop>
      </Sequence>
    </div>
  );
};
export const Field = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(21))}}>
      <Text size={64} style={{position: 'absolute', top: 150, width: '100%', ...reveal(f, s(4), s(7.6))}}>夜晚的街道，一遍遍地走。</Text>
      <Text size={64} style={{position: 'absolute', top: 150, width: '100%', ...MINT, ...reveal(f, s(8.2))}}>报错和漏报，一样危险。</Text>
      <Clip name="street1" at={s(0.4)} x={290} />
      <Clip name="street2" at={s(1)} x={750} />
      <Clip name="station" at={s(1.6)} x={1210} />
      <Text size={24} weight={400} color="#555" style={{position: 'absolute', bottom: 70, width: '100%', ...reveal(f, s(2), Infinity, 0)}}>
        实地录像 · iPhone 17 Pro Max · 2026 年 10 月 28 日 · 2128 帧数据反复重放
      </Text>
    </AbsoluteFill>
  );
};

// ---------- 10. End card ----------
export const End = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{opacity: 1 - amount(f, s(16.6), 30)}}>
      <Center style={{opacity: 1 - amount(f, s(11))}}>
        <Icon f={f} at={s(0.5)} size={200} />
        <Text size={88} style={{marginTop: 44, letterSpacing: 16, ...reveal(f, s(1.5))}}>PRTS</Text>
        <Text size={64} style={{marginTop: 40, ...MINT, ...reveal(f, s(3.5))}}>让每一步，都有回应。</Text>
      </Center>
      <Center style={reveal(f, s(11.6), Infinity, 0)}>
        <Text size={28} weight={400} color={C.dim} style={{lineHeight: 2}}>
          音乐："Clean Soul" Kevin MacLeod (incompetech.com)，CC BY 4.0<br />
          数据：中国盲人协会 · 配音为合成语音
        </Text>
      </Center>
    </AbsoluteFill>
  );
};

const PARTS: Record<keyof typeof SCENES, () => React.ReactElement> = {
  open: Open, stats: Stats, cane: Cane, reveal: Reveal, how: How, states: States, numbers: Numbers, photo: Photo, field: Field, end: End,
};

const musicVolume = (f: number) => {
  const t = f / FPS;
  const duck = Math.max(...VO.map(([, a, d]) => interpolate(t, [a - 0.6, a - 0.1, a + d + 0.1, a + d + 0.8], [0, 1, 1, 0], clamp)));
  const edge = Math.min(interpolate(t, [0, 3], [0, 1], clamp), interpolate(t, [162, 168], [1, 0], clamp));
  return (0.9 - 0.55 * duck) * edge;
};

export const PRTSFilm = () => (
  <AbsoluteFill style={{background: '#000'}}>
    {Object.entries(SCENES).map(([name, [a, b]]) => {
      const Part = PARTS[name as keyof typeof SCENES];
      return <Sequence key={name} from={s(a)} durationInFrames={s(b - a)}><Part /></Sequence>;
    })}
    <Audio src={staticFile('music.mp3')} volume={musicVolume} />
    {VO.map(([id, a]) => (
      <Sequence key={id} from={s(a)}><Audio src={staticFile(`vo/${id}.wav`)} volume={1} /></Sequence>
    ))}
  </AbsoluteFill>
);
