// Layout V1 — "Compact" : pane-local mini-toolbars, no global footer.
// Toolbar: Search prominent + icon-only Scan/Sort/Settings
// Filters: built-ins as 1-2 letter pills, custom tabs in scrollable row + overflow chevron
// Body: 60/40 splitter, body_h adaptive (fills available)
// Plugins pane mini-toolbar: count + "Add selected" (only visible when selection > 0)
// Chain pane mini-toolbar: chain count + Random ▾ + count slider + Clear
// Chain rows: hover-reveals action icons; bypassed = dimmed text + amber dot

const Tl = window.CP_THEME;
const { Btn, IconBtn, Input, Pill, Tab, Check, Slider, Sep } = window.CP;
const { PLUGINS, CHAIN_INIT, TABS } = window.MOCK;

const FILTERS = [
  { id: 'all',     label: 'All',  icon: null,    test: () => true },
  { id: 'fav',     label: '',     icon: 'starF', test: (p) => p.fav,   title: 'Favorites' },
  { id: 'recent',  label: '',     icon: 'clock', test: (p) => p.recent, title: 'Recents' },
  { id: 'vst3',    label: 'V3',   icon: null,    test: (p) => p.type === 'VST3', title: 'VST3' },
  { id: 'vst',     label: 'V',    icon: null,    test: (p) => p.type === 'VST',  title: 'VST' },
  { id: 'js',      label: 'JS',   icon: null,    test: (p) => p.type === 'JS',   title: 'JS' },
  { id: 'bundled', label: 'B',    icon: null,    test: (p) => p.bundled,         title: 'Bundled' },
];

// ── Settings ContextMenu (⚙)
const SettingsMenu = ({ open, onClose, settings, setSettings, anchor = 'right' }) => {
  if (!open) return null;
  return (
    <>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 9 }} />
      <div style={{
        position: 'absolute', top: Tl.sizes.btnH + Tl.sizes.gap, [anchor]: 0, zIndex: 10,
        minWidth: 180, padding: Tl.sizes.padSmall,
        background: Tl.colors.surface, border: `1px solid ${Tl.colors.border}`,
        borderRadius: Tl.sizes.radius, boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
      }}>
        <div style={{ padding: `${Tl.sizes.padSmall}px ${Tl.sizes.pad}px`, color: Tl.colors.textMute, font: `${Tl.sizes.fontSm}px ${Tl.fonts.ui}`, letterSpacing: 0.5, textTransform: 'uppercase' }}>Behavior</div>
        <Check label="Auto-open FX on add" checked={settings.autoOpen} onChange={(v) => setSettings({ ...settings, autoOpen: v })} />
        <Check label="Replace on add" checked={settings.replace} onChange={(v) => setSettings({ ...settings, replace: v })} />
        <Sep style={{ margin: `${Tl.sizes.padSmall}px 0` }} />
        <div style={{ padding: `${Tl.sizes.padSmall}px ${Tl.sizes.pad}px`, color: Tl.colors.textMute, font: `${Tl.sizes.fontSm}px ${Tl.fonts.ui}`, letterSpacing: 0.5, textTransform: 'uppercase' }}>Random</div>
        <Check label="From visible only" checked={settings.fromVisible} onChange={(v) => setSettings({ ...settings, fromVisible: v })} />
      </div>
    </>
  );
};

// ── Plugin row
const PluginRow = ({ p, selected, onClick, onDoubleClick }) => {
  const [hover, setHover] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      onClick={onClick} onDoubleClick={onDoubleClick}
      style={{
        height: Tl.sizes.rowH, padding: `0 ${Tl.sizes.pad}px`,
        display: 'flex', alignItems: 'center', gap: Tl.sizes.gap,
        background: selected ? Tl.colors.accentDim : (hover ? Tl.colors.surface2 : 'transparent'),
        color: selected ? Tl.colors.text : Tl.colors.text,
        font: `${Tl.sizes.fontBase}px ${Tl.fonts.ui}`,
        cursor: 'pointer', userSelect: 'none', borderRadius: Tl.sizes.radius,
      }}>
      {p.fav
        ? <Icon name="starF" size={10} style={{ color: Tl.colors.warn, flexShrink: 0 }} />
        : <span style={{ width: 10, flexShrink: 0 }} />}
      <span style={{ flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</span>
      <span style={{
        font: `${Tl.sizes.fontSm}px ${Tl.fonts.mono}`, color: selected ? Tl.colors.text : Tl.colors.textMute,
        flexShrink: 0, width: 22, textAlign: 'right',
      }}>{p.type}</span>
    </div>
  );
};

// ── Chain row (hover reveals actions, bypass = state)
const ChainRow = ({ fx, idx, onBypass, onRemove, onOpen }) => {
  const [hover, setHover] = React.useState(false);
  const dim = fx.bypass;
  return (
    <div
      onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      onDoubleClick={onOpen}
      style={{
        height: Tl.sizes.rowHLarge, padding: `0 ${Tl.sizes.pad}px 0 ${Tl.sizes.padSmall}px`,
        display: 'flex', alignItems: 'center', gap: Tl.sizes.gap,
        background: hover ? Tl.colors.surface2 : 'transparent',
        color: dim ? Tl.colors.textMute : Tl.colors.text,
        font: `${Tl.sizes.fontBase}px ${Tl.fonts.ui}`, cursor: 'grab',
        userSelect: 'none', borderRadius: Tl.sizes.radius,
        position: 'relative',
      }}>
      {/* Drag grip + bypass dot */}
      <span style={{ width: 12, display: 'inline-flex', justifyContent: 'center', color: Tl.colors.textMute, opacity: hover ? 1 : 0.4 }}>
        <Icon name="grip" size={10} />
      </span>
      <span style={{ width: 16, font: `${Tl.sizes.fontSm}px ${Tl.fonts.mono}`, color: Tl.colors.textMute, flexShrink: 0 }}>{String(idx + 1).padStart(2, '0')}</span>
      <span style={{
        flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        textDecoration: dim ? 'line-through' : 'none',
      }}>{fx.name}</span>
      <span style={{ font: `${Tl.sizes.fontSm}px ${Tl.fonts.mono}`, color: Tl.colors.textMute, flexShrink: 0, width: 22, textAlign: 'right' }}>{fx.type}</span>
      {/* Hover-reveal actions */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 2, marginLeft: Tl.sizes.gap,
        opacity: hover ? 1 : 0, transition: 'opacity 80ms', pointerEvents: hover ? 'auto' : 'none',
      }}>
        <IconBtn icon="play" size="sm" onClick={onOpen} title="Open" style={{ width: 18, minWidth: 18, height: 18, padding: 0 }} />
        <IconBtn icon={dim ? 'eyeOff' : 'eye'} size="sm" onClick={onBypass} title="Bypass" active={dim} style={{ width: 18, minWidth: 18, height: 18, padding: 0, color: dim ? Tl.colors.bypass : undefined }} />
        <IconBtn icon="trash" size="sm" onClick={onRemove} title="Remove" danger style={{ width: 18, minWidth: 18, height: 18, padding: 0 }} />
      </div>
    </div>
  );
};

// ── Splitter (vertical)
const Splitter = ({ ratio, setRatio, containerW }) => {
  const onDown = (e) => {
    e.preventDefault();
    const startX = e.clientX, startR = ratio;
    const m = (ev) => {
      const dx = ev.clientX - startX;
      const next = Math.max(0.3, Math.min(0.75, startR + dx / containerW));
      setRatio(next);
    };
    const u = () => { window.removeEventListener('mousemove', m); window.removeEventListener('mouseup', u); };
    window.addEventListener('mousemove', m); window.addEventListener('mouseup', u);
  };
  return (
    <div onMouseDown={onDown} style={{
      width: Tl.sizes.splitterW, cursor: 'col-resize', flexShrink: 0,
      background: Tl.colors.borderSoft,
      position: 'relative',
    }}>
      <div style={{ position: 'absolute', inset: 0, marginLeft: -3, marginRight: -3 }} />
    </div>
  );
};

// ── Pane header (mini-toolbar above each pane)
const PaneHeader = ({ children, style }) => (
  <div style={{
    height: Tl.sizes.btnH + Tl.sizes.padSmall * 2,
    padding: `${Tl.sizes.padSmall}px ${Tl.sizes.pad}px`,
    display: 'flex', alignItems: 'center', gap: Tl.sizes.gap,
    background: Tl.colors.bg,
    borderBottom: `1px solid ${Tl.colors.borderSoft}`,
    flexShrink: 0, ...style,
  }}>{children}</div>
);

// ── Pane label (left side of mini-toolbar)
const PaneLabel = ({ icon, text, count }) => (
  <span style={{
    display: 'inline-flex', alignItems: 'center', gap: Tl.sizes.gap,
    color: Tl.colors.textDim, font: `${Tl.sizes.fontSm}px ${Tl.fonts.ui}`,
    letterSpacing: 0.5, textTransform: 'uppercase', flexShrink: 0,
  }}>
    {icon && <Icon name={icon} size={10} />}
    <span>{text}</span>
    {count !== undefined && <span style={{ color: Tl.colors.textMute, font: `${Tl.sizes.fontSm}px ${Tl.fonts.mono}` }}>{count}</span>}
  </span>
);

// ── Scrollable list helper
const ScrollList = ({ children, style }) => (
  <div style={{
    flex: 1, overflowY: 'auto', overflowX: 'hidden',
    padding: `${Tl.sizes.padSmall}px 0`,
    background: Tl.colors.surface,
    minHeight: 0, ...style,
  }}>{children}</div>
);

// ── Chip row scrollable with overflow
const ChipRow = ({ children, style }) => {
  const ref = React.useRef(null);
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: Tl.sizes.gap,
      padding: `${Tl.sizes.padSmall}px ${Tl.sizes.pad}px`,
      background: Tl.colors.bg,
      borderBottom: `1px solid ${Tl.colors.borderSoft}`,
      flexShrink: 0, minWidth: 0, ...style,
    }}>{children}</div>
  );
};

// Export shared layout primitives
window.LAYOUT = {
  FILTERS, SettingsMenu, PluginRow, ChainRow, Splitter, PaneHeader, PaneLabel, ScrollList, ChipRow,
};
