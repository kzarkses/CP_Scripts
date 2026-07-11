// V3 — Tabbed: Plugins/Chain as toggle tabs, single full-width pane.
// Best for very small windows; gives both panes max width when active.
const T3 = window.CP_THEME;
const C3 = window.CP;
const L3 = window.LAYOUT;
const { PLUGINS: P3, CHAIN_INIT: CI3, TABS: TB3 } = window.MOCK;

const FXBrowserV3 = () => {
  const [search, setSearch] = React.useState('');
  const [filter, setFilter] = React.useState('all');
  const [activeTab, setActiveTab] = React.useState(null);
  const [tabs, setTabs] = React.useState(TB3);
  const [selected, setSelected] = React.useState(new Set([8, 12]));
  const [chain, setChain] = React.useState(CI3);
  const [randomCount, setRandomCount] = React.useState(3);
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  const [settings, setSettings] = React.useState({ autoOpen: true, replace: false, fromVisible: true });
  const [view, setView] = React.useState('plugins'); // 'plugins' | 'chain'

  const filtered = P3.filter((p) => {
    const f = L3.FILTERS.find((x) => x.id === filter);
    if (f && !f.test(p)) return false;
    if (search && !p.name.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });

  const toggleSel = (i) => {
    const next = new Set(selected);
    next.has(i) ? next.delete(i) : next.add(i);
    setSelected(next);
  };
  const addToChain = (p) => setChain([...chain, { name: p.name, type: p.type, bypass: false }]);
  const bypass = (i) => setChain(chain.map((c, j) => j === i ? { ...c, bypass: !c.bypass } : c));
  const remove = (i) => setChain(chain.filter((_, j) => j !== i));

  // View toggle "tabs" — bigger, primary
  const ViewTab = ({ id, icon, label, count }) => {
    const active = view === id;
    return (
      <button
        onClick={() => setView(id)}
        style={{
          height: T3.sizes.btnH + 2, padding: `0 ${T3.sizes.padLarge}px`,
          display: 'inline-flex', alignItems: 'center', gap: T3.sizes.gap,
          background: active ? T3.colors.surface : 'transparent',
          color: active ? T3.colors.text : T3.colors.textDim,
          border: 'none',
          borderTop: `2px solid ${active ? T3.colors.accent : 'transparent'}`,
          font: `${T3.sizes.fontBase}px ${T3.fonts.ui}`, fontWeight: active ? 600 : 400,
          cursor: 'pointer', userSelect: 'none', flexShrink: 0,
        }}>
        <Icon name={icon} size={11} />
        <span>{label}</span>
        <span style={{ color: T3.colors.textMute, font: `${T3.sizes.fontSm}px ${T3.fonts.mono}` }}>{count}</span>
      </button>
    );
  };

  return (
    <div style={{
      width: '100%', height: '100%', display: 'flex', flexDirection: 'column',
      background: T3.colors.bg, color: T3.colors.text,
      font: `${T3.sizes.fontBase}px ${T3.fonts.ui}`,
      borderRadius: T3.sizes.radius, overflow: 'hidden',
    }}>
      {/* Toolbar */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: T3.sizes.gap,
        padding: `${T3.sizes.pad}px`,
        borderBottom: `1px solid ${T3.colors.border}`,
        position: 'relative',
      }}>
        <C3.Input value={search} onChange={setSearch} placeholder="Search FX…" leftIcon="search"
          rightSlot={search && (
            <span onClick={() => setSearch('')} style={{ color: T3.colors.textMute, cursor: 'pointer', display: 'inline-flex', padding: 2 }}>
              <Icon name="close" size={10} />
            </span>
          )} />
        <C3.IconBtn icon="scan" title="Rescan" />
        <C3.IconBtn icon="sort" title="Sort A→Z" />
        <C3.IconBtn icon="gear" title="Settings" active={settingsOpen} onClick={() => setSettingsOpen(!settingsOpen)} />
        <L3.SettingsMenu open={settingsOpen} onClose={() => setSettingsOpen(false)} settings={settings} setSettings={setSettings} />
      </div>

      {/* Chips (only when on Plugins) */}
      {view === 'plugins' && (
        <L3.ChipRow>
          {L3.FILTERS.map((f) => (
            <C3.Pill key={f.id} icon={f.icon} label={f.label} title={f.title || f.label}
              active={filter === f.id && !activeTab}
              onClick={() => { setFilter(f.id); setActiveTab(null); }} />
          ))}
          <C3.Sep vert style={{ height: T3.sizes.chipH * 0.7, margin: `0 ${T3.sizes.padSmall}px` }} />
          <div style={{ display: 'flex', gap: T3.sizes.gap, overflowX: 'auto', flex: 1, minWidth: 0, scrollbarWidth: 'thin' }}>
            {tabs.map((t, i) => (
              <C3.Tab key={i} label={t} active={activeTab === i}
                onClick={() => setActiveTab(activeTab === i ? null : i)}
                onClose={() => setTabs(tabs.filter((_, j) => j !== i))} />
            ))}
          </div>
          <C3.IconBtn icon="plus" title="New tab" size="sm" style={{ height: T3.sizes.chipH, minWidth: T3.sizes.chipH }} />
        </L3.ChipRow>
      )}

      {/* View tabs */}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 0,
        background: T3.colors.bg,
        borderBottom: `1px solid ${T3.colors.border}`, paddingLeft: T3.sizes.pad,
        flexShrink: 0,
      }}>
        <ViewTab id="plugins" icon="folder" label="Plugins" count={filtered.length} />
        <ViewTab id="chain" icon="layers" label="Chain" count={chain.length} />
        <div style={{ flex: 1 }} />
        {view === 'plugins' && selected.size > 0 && (
          <C3.Btn icon="add" label={`Add (${selected.size})`}
            onClick={() => { selected.forEach((i) => addToChain(filtered[i])); setSelected(new Set()); }}
            style={{ marginRight: T3.sizes.pad, marginBottom: T3.sizes.padSmall,
              color: T3.colors.text, borderColor: T3.colors.accentDim, background: T3.colors.accentDim }} />
        )}
        {view === 'chain' && (
          <div style={{ display: 'flex', alignItems: 'center', gap: T3.sizes.gap, marginRight: T3.sizes.pad, marginBottom: T3.sizes.padSmall }}>
            <C3.Slider value={randomCount} onChange={setRandomCount} min={1} max={12} width={60} />
            <C3.IconBtn icon="dice" title={`Random ${randomCount}`} />
            <C3.IconBtn icon="erase" title="Clear chain" onClick={() => setChain([])} danger />
          </div>
        )}
      </div>

      {/* Single pane */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0, background: T3.colors.surface }}>
        {view === 'plugins' ? (
          <L3.ScrollList>
            {filtered.map((p, i) => (
              <L3.PluginRow key={i} p={p} selected={selected.has(i)}
                onClick={() => toggleSel(i)} onDoubleClick={() => addToChain(p)} />
            ))}
          </L3.ScrollList>
        ) : (
          <L3.ScrollList>
            {chain.length === 0 ? (
              <div style={{ padding: T3.sizes.padLarge, color: T3.colors.textMute, font: `${T3.sizes.fontSm}px ${T3.fonts.ui}`, textAlign: 'center' }}>
                Empty chain. Switch to Plugins and double-click to add.
              </div>
            ) : chain.map((fx, i) => (
              <L3.ChainRow key={i} fx={fx} idx={i}
                onBypass={() => bypass(i)} onRemove={() => remove(i)} onOpen={() => {}} />
            ))}
          </L3.ScrollList>
        )}
      </div>
    </div>
  );
};

window.FXBrowserV3 = FXBrowserV3;
