import {Composition} from 'remotion';
import {Deck, SLIDES} from './Deck';
import {PRTSFilm, TOTAL} from './Film';

export const Root = () => (
  <>
    <Composition id="PRTS" component={PRTSFilm} durationInFrames={TOTAL} fps={30} width={1920} height={1080} />
    <Composition id="Deck" component={Deck} durationInFrames={SLIDES.length} fps={30} width={1920} height={1080} />
  </>
);
