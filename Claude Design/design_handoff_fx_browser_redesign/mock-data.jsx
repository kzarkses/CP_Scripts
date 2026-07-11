// Mock plugin/chain data shared across layouts.
const PLUGINS = [
  { name: 'kHs Pitch Shifter', type: 'VST3', vendor: 'Kilohearts', fav: true, recent: true },
  { name: 'kHs Faturator', type: 'VST3', vendor: 'Kilohearts', fav: false, recent: true },
  { name: 'kHs Delay', type: 'VST3', vendor: 'Kilohearts', fav: true, recent: false },
  { name: 'kHs Compressor', type: 'VST3', vendor: 'Kilohearts', fav: false, recent: false },
  { name: 'ReaEQ', type: 'JS', vendor: 'Cockos', fav: true, recent: true, bundled: true },
  { name: 'ReaComp', type: 'JS', vendor: 'Cockos', fav: false, recent: true, bundled: true },
  { name: 'ReaTune', type: 'JS', vendor: 'Cockos', fav: false, recent: false, bundled: true },
  { name: 'ReaXcomp', type: 'JS', vendor: 'Cockos', fav: false, recent: false, bundled: true },
  { name: 'Pro-Q 3', type: 'VST3', vendor: 'FabFilter', fav: true, recent: true },
  { name: 'Pro-C 2', type: 'VST3', vendor: 'FabFilter', fav: true, recent: false },
  { name: 'Pro-MB', type: 'VST3', vendor: 'FabFilter', fav: false, recent: false },
  { name: 'Pro-L 2', type: 'VST3', vendor: 'FabFilter', fav: false, recent: false },
  { name: 'Saturn 2', type: 'VST3', vendor: 'FabFilter', fav: true, recent: true },
  { name: 'Decapitator', type: 'VST', vendor: 'Soundtoys', fav: false, recent: false },
  { name: 'EchoBoy', type: 'VST', vendor: 'Soundtoys', fav: false, recent: false },
  { name: 'Little Plate', type: 'VST', vendor: 'Soundtoys', fav: false, recent: true },
  { name: 'Valhalla VintageVerb', type: 'VST3', vendor: 'Valhalla DSP', fav: true, recent: false },
  { name: 'Valhalla Delay', type: 'VST3', vendor: 'Valhalla DSP', fav: false, recent: false },
  { name: 'Valhalla Shimmer', type: 'VST3', vendor: 'Valhalla DSP', fav: false, recent: false },
  { name: 'OTT', type: 'VST3', vendor: 'Xfer', fav: false, recent: true },
  { name: 'Serum', type: 'VST3', vendor: 'Xfer', fav: true, recent: false },
  { name: 'Diva', type: 'VST3', vendor: 'u-he', fav: false, recent: false },
  { name: 'Repro-1', type: 'VST3', vendor: 'u-he', fav: false, recent: false },
  { name: 'Zebra2', type: 'VST3', vendor: 'u-he', fav: false, recent: false },
  { name: 'JS: Saturation', type: 'JS', vendor: 'Cockos', fav: false, recent: false, bundled: true },
  { name: 'JS: Bandsplit', type: 'JS', vendor: 'Cockos', fav: false, recent: false, bundled: true },
  { name: 'JS: Hard Limiter', type: 'JS', vendor: 'Cockos', fav: false, recent: false, bundled: true },
];

const CHAIN_INIT = [
  { name: 'kHs Pitch Shifter', type: 'VST3', bypass: false },
  { name: 'Pro-Q 3', type: 'VST3', bypass: false },
  { name: 'ReaComp', type: 'JS', bypass: true },
  { name: 'Valhalla VintageVerb', type: 'VST3', bypass: false },
];

const TABS = ['Bass', 'Drums', 'Vocals', 'Mastering', 'Creative FX'];

window.MOCK = { PLUGINS, CHAIN_INIT, TABS };
