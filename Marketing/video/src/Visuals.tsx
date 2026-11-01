// Text-free stills of the film's abstract visuals, on a transparent background, for the PPT kit.
// Frame i of the "Visuals" composition is VISUALS[i]; render with --image-format=png.
import React from 'react';
import {AbsoluteFill, Sequence} from 'remotion';
import {C, Sight, usePoints} from './Film';

const FIELD = {x: 960 - 405, w: 810, h: 1080};

// What a cane reaches: a few points lit around one tap near the bottom.
const CaneReach = () => {
  const pts = usePoints();
  const tap = {x: 0.5, y: 0.88};
  return (
    <svg width={1920} height={1080}>
      {pts.map((p, i) => {
        const d = Math.hypot((p[0] - tap.x) * 0.75, p[1] - tap.y);
        return d < 0.12 ? <circle key={i} cx={FIELD.x + p[0] * FIELD.w} cy={p[1] * FIELD.h} r={3} fill={C.fg} opacity={1 - d / 0.12} /> : null;
      })}
      {[30, 70, 110].map((r, i) => (
        <circle key={r} cx={FIELD.x + tap.x * FIELD.w} cy={tap.y * FIELD.h} r={r} fill="none" stroke={C.fg} strokeWidth={1.5} opacity={0.5 - i * 0.15} />
      ))}
    </svg>
  );
};

// Sound rings around the walker and a nudge on the left edge.
const Nudge = () => (
  <svg width={1920} height={1080}>
    <defs><filter id="soft"><feGaussianBlur stdDeviation="14" /></filter></defs>
    {[120, 240, 360].map((r, i) => <circle key={r} cx={960} cy={540} r={r} fill="none" stroke={C.fg} strokeWidth={1.2} opacity={0.45 - i * 0.13} />)}
    <circle cx={960} cy={540} r={14} fill={C.fg} />
    <rect x={0} y={240} width={40} height={600} fill={C.mint} filter="url(#soft)" />
    <rect x={0} y={280} width={6} height={520} rx={3} fill={C.mint} />
  </svg>
);

const Hold = ({children}: {children: React.ReactNode}) => <AbsoluteFill>{children}</AbsoluteFill>;

export const VISUALS: [string, () => React.ReactElement][] = [
  ['cane-reach', () => <CaneReach />],
  ['phone-sight', () => <Sight f={0} reach={1.1} route={1} pulses={false} gain={2.4} />],
  ['phone-sight-points', () => <Sight f={0} reach={1.1} route={0} pulses={false} gain={2.4} />],
  ['sound-and-nudge', () => <Nudge />],
];

export const Visuals = () => (
  <AbsoluteFill>
    {VISUALS.map(([name, V], i) => <Sequence key={name} from={i} durationInFrames={1}><Hold><V /></Hold></Sequence>)}
  </AbsoluteFill>
);
