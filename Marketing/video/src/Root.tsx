import {Composition} from 'remotion';
import {PRTSFilm, TOTAL} from './Film';
import {Visuals, VISUALS} from './Visuals';

export const Root = () => (
  <>
    <Composition id="PRTS" component={PRTSFilm} durationInFrames={TOTAL} fps={30} width={1920} height={1080} />
    <Composition id="Visuals" component={Visuals} durationInFrames={VISUALS.length} fps={30} width={1920} height={1080} />
  </>
);
