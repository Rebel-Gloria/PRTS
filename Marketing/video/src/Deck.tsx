// Keynote slides: frame i of the "Deck" composition is slide i + 1. Most slides are film scenes held
// at a moment; the rest are drawn here. Order and speaker notes follow docs/pitch/script.md.
import React from 'react';
import {AbsoluteFill, Img, Sequence, staticFile} from 'remotion';
import {C, Cane, Center, End, Field, How, MINT, Numbers, Phone, Photo, Reveal, States, Stats, Text, s} from './Film';

const Card = ({title, lines, accent, width = 640}: {title: string; lines: string[]; accent: string; width?: number}) => (
  <div style={{width, height: 420, borderRadius: 40, background: '#101012', border: '1px solid #222', padding: 60, boxSizing: 'border-box'}}>
    <Text size={56} color={accent} style={{textAlign: 'left'}}>{title}</Text>
    {lines.map((l) => <Text key={l} size={36} weight={400} color={C.dim} style={{textAlign: 'left', marginTop: 28}}>{l}</Text>)}
  </div>
);

const Today = () => (
  <AbsoluteFill>
    <Text size={72} style={{position: 'absolute', top: 170, width: '100%'}}>现有的电子方案。</Text>
    <div style={{position: 'absolute', top: 380, width: '100%', display: 'flex', justifyContent: 'center', gap: 60}}>
      <Card title="专用硬件" accent={C.fg} lines={['效果好', '价格高，升级靠厂商']} />
      <Card title="云端 App" accent={C.fg} lines={['识别强', '要联网、有延迟', '图片要传出去']} />
    </div>
  </AbsoluteFill>
);

const Home = () => {
  const rows = [['避开障碍', '点"开始"'], ['描述画面', '短按屏幕'], ['读出文字', '三指按住']];
  return (
    <AbsoluteFill>
      <Phone h={900} style={{left: 420, top: 90}}>
        <Img src={staticFile('img/home.png')} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
      </Phone>
      <div style={{position: 'absolute', left: 1000, top: 330}}>
        <Text size={72} style={{textAlign: 'left'}}>PRTS 做三件事。</Text>
        {rows.map(([t, d]) => (
          <div key={t} style={{display: 'flex', alignItems: 'baseline', marginTop: 44}}>
            <Text size={48} color={C.mint} style={{width: 260, textAlign: 'left'}}>{t}</Text>
            <Text size={36} weight={400} color={C.dim} style={{textAlign: 'left'}}>{d}</Text>
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
};

const Next = () => (
  <AbsoluteFill>
    <Text size={72} style={{position: 'absolute', top: 170, width: '100%'}}>下一步。</Text>
    <div style={{position: 'absolute', top: 380, width: '100%', display: 'flex', justifyContent: 'center', gap: 48}}>
      <Card title="本地视觉模型" accent={C.mint} width={560} lines={['把视觉模型放进手机', '描述画面也不用联网']} />
      <Card title="台阶检测" accent={C.mint} width={560} lines={['上下台阶', '提前提醒']} />
      <Card title="真人实测" accent={C.mint} width={560} lines={['请视障朋友', '一起走、一起改']} />
    </div>
  </AbsoluteFill>
);

const Statement = ({children}: {children: React.ReactNode}) => (
  <Center><Text size={130} style={MINT}>{children}</Text></Center>
);

// A scene held at its local frame `at`: each slide starts at local frame 0, so start the scene `at` frames early.
const held = (Scene: () => React.ReactElement, at: number) => () => <Sequence from={-at}><Scene /></Sequence>;

export const SLIDES: (() => React.ReactElement)[] = [
  held(Reveal, s(4)),
  held(Stats, s(4)),
  held(Stats, s(12)),
  held(Cane, s(8)),
  Today,
  () => <Statement>一部 iPhone，就够了。</Statement>,
  Home,
  held(How, s(12)),
  held(States, s(10)),
  held(Numbers, s(8)),
  held(Photo, s(14)),
  held(Field, s(12)),
  Next,
  held(End, s(6)),
];

export const Deck = () => (
  <AbsoluteFill style={{background: '#000'}}>
    {SLIDES.map((Slide, i) => <Sequence key={i} from={i} durationInFrames={1} layout="none"><AbsoluteFill><Slide /></AbsoluteFill></Sequence>)}
  </AbsoluteFill>
);
