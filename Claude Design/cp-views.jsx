// Add FX dialog + Dock view + Window view + draggable section reordering

// ── ADD FX DIALOG (modal) ───────────────────────────────────────────────────
function AddFXDialog({ theme, open, onClose }) {
  if (!open) return null;
  const cats = ['All', 'Favorites', 'VST3', 'VSTi', 'JS', 'AU', 'Recent', 'Containers'];
  const fxList = [
    { cat: 'JS', name: 'JS: Chorus' },
    { cat: 'JS', name: 'JS: Bitcrusher' },
    { cat: 'JS', name: 'JS: Stereo Width' },
    { cat: 'VST3', name: 'kHs Chorus' },
    { cat: 'VST3', name: 'ValhallaVintageVerb' },
    { cat: 'VST3', name: 'FabFilter Pro-Q 3' },
    { cat: 'VSTi', name: 'Surge XT' },
    { cat: 'VSTi', name: 'Vital' },
    { cat: 'COCKOS', name: 'ReaEQ' },
    { cat: 'COCKOS', name: 'ReaComp' },
    { cat: 'COCKOS', name: 'ReaDelay' },
    { cat: 'COCKOS', name: 'ReaVerb' },
    { cat: 'COCKOS', name: 'ReaPitch' },
    { cat: 'COCKOS', name: 'ReaTune' },
  ];
  return (
    <div style={{
      position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.5)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 50,
    }} onClick={onClose}>
      <div onClick={e => e.stopPropagation()} style={{
        width: 720, height: 480, background: theme.window_bg,
        border: `1px solid ${theme.border}`,
        boxShadow: '0 12px 40px rgba(0,0,0,0.6)', display: 'flex', flexDirection: 'column',
      }}>
        <CPTitleBar title="Add FX — FX Browser" theme={theme} />
        {/* Search + filters */}
        <div style={{ padding: 8, display: 'flex', gap: 8, borderBottom: `1px solid ${theme.separator}` }}>
          <div style={{ flex: 1 }}><CPInput value="" hint="🔍 Search FX..." theme={theme} /></div>
          <CPBtn theme={theme}>Scan</CPBtn>
          <CPBtn theme={theme}>★ Favorite</CPBtn>
        </div>
        <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
          {/* Categories */}
          <div style={{
            width: 140, background: theme.panel_bg, borderRight: `1px solid ${theme.separator}`,
            padding: 4, display: 'flex', flexDirection: 'column', gap: 2,
          }}>
            {cats.map((c, i) => (
              <div key={c} style={{
                padding: '6px 8px', fontFamily: cpFont, fontSize: 12,
                background: i === 0 ? theme.accent : 'transparent',
                color: i === 0 ? '#1a1a1c' : theme.text, cursor: 'pointer',
                fontWeight: i === 0 ? 'bold' : 'normal',
              }}>{c}</div>
            ))}
          </div>
          {/* List */}
          <div style={{ flex: 1, overflow: 'auto', padding: 4 }}>
            {fxList.map((fx, i) => (
              <div key={i} style={{
                display: 'flex', alignItems: 'center', gap: 8, padding: '4px 8px',
                fontFamily: cpFont, fontSize: 12, color: theme.text,
                background: i === 3 ? theme.accent_dim : 'transparent', cursor: 'pointer',
              }}>
                <span style={{ width: 50, color: theme.text_dim, fontSize: 10 }}>{fx.cat}</span>
                <span style={{ flex: 1 }}>{fx.name}</span>
                <span style={{ color: theme.text_dim, fontSize: 10 }}>★</span>
              </div>
            ))}
          </div>
        </div>
        {/* Footer */}
        <div style={{
          padding: 8, borderTop: `1px solid ${theme.separator}`,
          display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8,
        }}>
          <span style={{ fontFamily: cpFont, fontSize: 11, color: theme.text_dim }}>
            14 plugins · selected: kHs Chorus
          </span>
          <div style={{ display: 'flex', gap: 6 }}>
            <CPBtn theme={theme} onClick={onClose}>Cancel</CPBtn>
            <CPBtn theme={theme} accent onClick={onClose}>Add to Track</CPBtn>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Section list with drag-to-reorder ───────────────────────────────────────
function useReorderable(initial) {
  const [order, setOrder] = React.useState(initial);
  const [dragId, setDragId] = React.useState(null);
  const [dragOver, setDragOver] = React.useState(null);
  const onDragStart = (id) => () => setDragId(id);
  const onDragOver = (id) => (e) => { e.preventDefault(); setDragOver(id); };
  const onDrop = (id) => () => {
    if (!dragId || dragId === id) { setDragId(null); setDragOver(null); return; }
    const next = order.filter(x => x !== dragId);
    const idx = next.indexOf(id);
    next.splice(idx, 0, dragId);
    setOrder(next);
    setDragId(null); setDragOver(null);
  };
  return { order, setOrder, dragId, dragOver, onDragStart, onDragOver, onDrop };
}

// ── DOCK VIEW (le screenshot 1, horizontal compact) ─────────────────────────
function DockView({ theme, onAddFX }) {
  const SECTIONS = {
    soundgen:   { title: 'SOUND GENERATOR', width: 80,  render: () => <SectionSoundGen theme={theme} enabled={false} /> },
    navigation: { title: 'NAVIGATION',      width: 130, render: () => <SectionNavigation theme={theme} /> },
    mode:       { title: 'MODE',            width: 90,  render: () => <SectionMode theme={theme} /> },
    xypad:      { title: 'XY PAD',          width: 280, render: () => <SectionXYPad theme={theme} size={250} /> },
    presets:    { title: 'PRESETS',         width: 150, render: () => <SectionPresets theme={theme} /> },
    randomizer: { title: 'RANDOMIZER',      width: 180, render: () => <SectionRandomizer theme={theme} /> },
    fxsettings: { title: 'FX SETTINGS', width: 0, flex: 1, extra: <span style={{fontFamily: cpFont, fontSize: 11, color: theme.text}}>| Selected: 5</span>,
                  render: () => <SectionFXSettings theme={theme} onAddFX={onAddFX} /> },
  };
  const { order, dragId, dragOver, onDragStart, onDragOver, onDrop } =
    useReorderable(['soundgen', 'navigation', 'mode', 'xypad', 'presets', 'randomizer', 'fxsettings']);
  const [collapsed, setCollapsed] = React.useState({});
  const toggle = (k) => () => setCollapsed(c => ({ ...c, [k]: !c[k] }));

  return (
    <div style={{
      display: 'flex', flexDirection: 'column',
      background: theme.window_bg, height: '100%',
      fontFamily: cpFont,
    }}>
      {/* Top thin titlebar like docked panel */}
      <div style={{
        height: 22, background: theme.title_bar, display: 'flex',
        alignItems: 'center', padding: '0 8px', justifyContent: 'space-between',
        borderBottom: `1px solid ${theme.border}`, fontSize: 12, color: theme.title_text,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontWeight: 'bold' }}>FX Constellation</span>
          <span style={{ background: theme.button, padding: '0 4px', fontSize: 10 }}>L</span>
        </div>
        <div style={{ display: 'flex', gap: 2 }}>
          <CPIconBtn theme={theme}>⚙</CPIconBtn>
          <CPIconBtn theme={theme} hoverColor={theme.close_btn}>×</CPIconBtn>
        </div>
      </div>
      {/* Sections */}
      <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
        {order.map((key, i) => {
          const s = SECTIONS[key];
          const isDragging = dragId === key;
          const isOver = dragOver === key && dragId !== key;
          const w = collapsed[key] ? 24 : s.width;
          return (
            <React.Fragment key={key}>
              {i > 0 && <CPVSep theme={theme} />}
              <div
                draggable
                onDragStart={onDragStart(key)}
                onDragOver={onDragOver(key)}
                onDrop={onDrop(key)}
                style={{
                  width: s.flex ? undefined : w, flex: s.flex ? 1 : undefined,
                  flexShrink: 0, display: 'flex', flexDirection: 'column',
                  opacity: isDragging ? 0.4 : 1,
                  background: isOver ? theme.accent_dim : 'transparent',
                  transition: 'background 0.1s',
                }}>
                <CPSectionHeader label={s.title} collapsed={collapsed[key]}
                  onToggle={toggle(key)} theme={theme} draggable extra={s.extra} />
                {!collapsed[key] && (
                  <div style={{ padding: 8, display: 'flex', flexDirection: 'column',
                    gap: 5, overflow: 'hidden', flex: 1 }}>
                    {s.render()}
                  </div>
                )}
              </div>
            </React.Fragment>
          );
        })}
      </div>
      {/* bottom tab bar like REAPER docker */}
      <div style={{
        height: 22, background: theme.title_bar, borderTop: `1px solid ${theme.border}`,
        display: 'flex', alignItems: 'center', padding: '0 4px',
      }}>
        <div style={{
          padding: '2px 12px', background: theme.button_a, color: theme.text,
          fontFamily: cpFont, fontSize: 11, display: 'flex', alignItems: 'center', gap: 4,
        }}>
          FX Constellation <span style={{ fontSize: 9 }}>D</span>
        </div>
      </div>
    </div>
  );
}

// ── WINDOW VIEW (radial : XY pad au centre, sections autour) ────────────────
function WindowView({ theme, onAddFX }) {
  return (
    <div style={{
      width: 1100, height: 720, background: theme.window_bg,
      border: `1px solid ${theme.border}`, display: 'flex', flexDirection: 'column',
      boxShadow: '0 16px 48px rgba(0,0,0,0.6)',
      fontFamily: cpFont,
    }}>
      <CPTitleBar title="FX Constellation — Drum Bus Glitch" theme={theme} lockable />
      <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
        {/* LEFT column : Navigation + Mode */}
        <div style={{ width: 200, display: 'flex', flexDirection: 'column',
          borderRight: `1px solid ${theme.separator}` }}>
          <CPSectionHeader label="NAVIGATION" theme={theme} />
          <div style={{ padding: 8, display: 'flex', flexDirection: 'column', gap: 5 }}>
            <SectionNavigation theme={theme} />
          </div>
          <CPSectionHeader label="MODE" theme={theme} />
          <div style={{ padding: 8, display: 'flex', flexDirection: 'column', gap: 5 }}>
            <SectionMode theme={theme} />
          </div>
          <CPSectionHeader label="SOUND GENERATOR" theme={theme} />
          <div style={{ padding: 8 }}>
            <SectionSoundGen theme={theme} enabled={false} />
          </div>
        </div>
        {/* CENTER : XY pad XL + label position */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          <CPSectionHeader label="XY PAD — Drum Bus Glitch" theme={theme}
            extra={<span style={{ fontFamily: cpMono, fontSize: 10, color: theme.text_dim }}>● Manual</span>}
          />
          <div style={{ flex: 1, padding: 16, display: 'flex' }}>
            <SectionXYPad theme={theme} x={0.62} y={0.45} />
          </div>
          {/* RANDOMIZER bandeau bas */}
          <div style={{ borderTop: `1px solid ${theme.separator}` }}>
            <CPSectionHeader label="RANDOMIZER" theme={theme} />
            <div style={{ padding: 8 }}>
              <SectionRandomizer theme={theme} />
            </div>
          </div>
        </div>
        {/* RIGHT : Presets + FX Settings */}
        <div style={{ width: 480, display: 'flex', flexDirection: 'column',
          borderLeft: `1px solid ${theme.separator}` }}>
          <CPSectionHeader label="PRESETS" theme={theme} />
          <div style={{ padding: 8, display: 'flex', flexDirection: 'column', gap: 5 }}>
            <SectionPresets theme={theme} />
          </div>
          <CPSectionHeader label="FX SETTINGS" theme={theme}
            extra={<span style={{ fontFamily: cpFont, fontSize: 11, color: theme.text }}>| Selected: 5</span>}
          />
          <div style={{ flex: 1, padding: 8, overflow: 'auto' }}>
            <SectionFXSettings theme={theme} onAddFX={onAddFX} />
          </div>
        </div>
      </div>
    </div>
  );
}

window.AddFXDialog = AddFXDialog;
window.DockView = DockView;
window.WindowView = WindowView;
