// Mono-glyph icons mirroring CP_Toolkit Icons.* set.
// 12px stroke-based, currentColor — matches the toolkit's flat aesthetic.
const Icon = ({ name, size = 12, style }) => {
  const s = size;
  const stroke = { stroke: 'currentColor', strokeWidth: 1.4, fill: 'none', strokeLinecap: 'round', strokeLinejoin: 'round' };
  const fill = { fill: 'currentColor', stroke: 'none' };
  const base = { width: s, height: s, display: 'inline-block', verticalAlign: 'middle', flexShrink: 0, ...style };
  const paths = {
    search: <><circle cx="5.5" cy="5.5" r="3.5" {...stroke}/><line x1="8" y1="8" x2="11" y2="11" {...stroke}/></>,
    scan:   <><path d="M2 6 A4 4 0 0 1 10 6" {...stroke}/><polyline points="10,3 10,6 7,6" {...stroke}/><path d="M10 6 A4 4 0 0 1 2 6" {...stroke}/><polyline points="2,9 2,6 5,6" {...stroke}/></>,
    sort:   <><line x1="2" y1="3.5" x2="9" y2="3.5" {...stroke}/><line x1="2" y1="6" x2="7" y2="6" {...stroke}/><line x1="2" y1="8.5" x2="5" y2="8.5" {...stroke}/></>,
    gear:   <><circle cx="6" cy="6" r="1.5" {...stroke}/><path d="M6 1.5v1.5M6 9v1.5M1.5 6h1.5M9 6h1.5M2.6 2.6l1 1M8.4 8.4l1 1M9.4 2.6l-1 1M3.6 8.4l-1 1" {...stroke}/></>,
    close:  <><line x1="3" y1="3" x2="9" y2="9" {...stroke}/><line x1="9" y1="3" x2="3" y2="9" {...stroke}/></>,
    plus:   <><line x1="6" y1="2.5" x2="6" y2="9.5" {...stroke}/><line x1="2.5" y1="6" x2="9.5" y2="6" {...stroke}/></>,
    star:   <><polygon points="6,1.8 7.3,4.5 10.2,4.9 8.1,6.9 8.6,9.7 6,8.4 3.4,9.7 3.9,6.9 1.8,4.9 4.7,4.5" {...stroke}/></>,
    starF:  <><polygon points="6,1.8 7.3,4.5 10.2,4.9 8.1,6.9 8.6,9.7 6,8.4 3.4,9.7 3.9,6.9 1.8,4.9 4.7,4.5" {...fill}/></>,
    clock:  <><circle cx="6" cy="6" r="3.8" {...stroke}/><polyline points="6,4 6,6 7.5,7" {...stroke}/></>,
    chevR:  <><polyline points="4.5,2.5 8,6 4.5,9.5" {...stroke}/></>,
    chevL:  <><polyline points="7.5,2.5 4,6 7.5,9.5" {...stroke}/></>,
    chevD:  <><polyline points="2.5,4.5 6,8 9.5,4.5" {...stroke}/></>,
    play:   <><polygon points="4,3 4,9 9,6" {...fill}/></>,
    eye:    <><path d="M1.5 6 Q 6 2 10.5 6 Q 6 10 1.5 6 Z" {...stroke}/><circle cx="6" cy="6" r="1.2" {...stroke}/></>,
    eyeOff: <><path d="M1.5 6 Q 6 2 10.5 6 Q 6 10 1.5 6 Z" {...stroke}/><line x1="2" y1="2" x2="10" y2="10" {...stroke}/></>,
    trash:  <><polyline points="3,3.5 9,3.5" {...stroke}/><path d="M3.7 3.5 L4.2 9.5 L7.8 9.5 L8.3 3.5" {...stroke}/><path d="M5 3.5 V 2.5 H 7 V 3.5" {...stroke}/></>,
    drag:   <><circle cx="4.5" cy="3.5" r=".7" {...fill}/><circle cx="7.5" cy="3.5" r=".7" {...fill}/><circle cx="4.5" cy="6" r=".7" {...fill}/><circle cx="7.5" cy="6" r=".7" {...fill}/><circle cx="4.5" cy="8.5" r=".7" {...fill}/><circle cx="7.5" cy="8.5" r=".7" {...fill}/></>,
    dice:   <><rect x="2" y="2" width="8" height="8" rx="1.2" {...stroke}/><circle cx="4.2" cy="4.2" r=".7" {...fill}/><circle cx="7.8" cy="4.2" r=".7" {...fill}/><circle cx="6" cy="6" r=".7" {...fill}/><circle cx="4.2" cy="7.8" r=".7" {...fill}/><circle cx="7.8" cy="7.8" r=".7" {...fill}/></>,
    layers: <><polygon points="6,1.8 10.5,4 6,6.2 1.5,4" {...stroke}/><polyline points="1.5,6.2 6,8.4 10.5,6.2" {...stroke}/><polyline points="1.5,8.4 6,10.6 10.5,8.4" {...stroke}/></>,
    folder: <><path d="M1.8 3.5 H 5 L 6 4.5 H 10.2 V 9 H 1.8 Z" {...stroke}/></>,
    pin:    <><path d="M6 1.5 L 8.5 4 L 7.5 5 L 8 7 L 6 7 M 6 7 L 4 7 L 4.5 5 L 3.5 4 L 6 1.5 Z M 6 7 V 10.5" {...stroke}/></>,
    swap:   <><polyline points="2,4 9,4 7,2" {...stroke}/><polyline points="10,8 3,8 5,10" {...stroke}/></>,
    erase:  <><path d="M2.5 8 L 6 4.5 L 9 7.5 L 7 9.5 L 4.5 9.5 Z" {...stroke}/><line x1="6" y1="4.5" x2="9" y2="7.5" {...stroke}/></>,
    add:    <><circle cx="6" cy="6" r="4" {...stroke}/><line x1="6" y1="4" x2="6" y2="8" {...stroke}/><line x1="4" y1="6" x2="8" y2="6" {...stroke}/></>,
    check:  <><polyline points="2.5,6 5,8.5 9.5,3.5" {...stroke}/></>,
    dot:    <><circle cx="6" cy="6" r="2" {...fill}/></>,
    grip:   <><line x1="4" y1="2.5" x2="4" y2="9.5" {...stroke}/><line x1="6" y1="2.5" x2="6" y2="9.5" {...stroke}/><line x1="8" y1="2.5" x2="8" y2="9.5" {...stroke}/></>,
  };
  return <svg viewBox="0 0 12 12" style={base} aria-hidden="true">{paths[name] || null}</svg>;
};

window.Icon = Icon;
