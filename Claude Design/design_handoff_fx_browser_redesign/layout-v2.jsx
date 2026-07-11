// V2 — Single-bar: tight bottom bar with primary actions; settings live in ⚙ menu.
const T2 = window.CP_THEME;
const C2 = window.CP;
const L2 = window.LAYOUT;
const { PLUGINS: P2, CHAIN_INIT: CI2, TABS: TB2 } = window.MOCK;

const FXBrowserV2 = () => {
  const [search, setSearch] = React.useState('');
  const [filter, setFilter] = React.useState('all');
  const [activeTab, setActiveTab] = React.useState(null);
  const [tabs, setTabs] = React.useState(TB2);
  const [selected, setSelected] = React.useState(new Set([2]));
  const [chain, setChain] = React.useState(CI2);
  const [randomCount, setRandomCount] = React.useState(3);
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  const [randomMenuOpen, setRandomMenuOpen] = React.useState(false);
  const [settings, setSettings] = React.useState({ autoOpen: true, replace: false, fromVisible: false });
  const [splitRatio, setSplitRatio] = React.useState(0.6);
  const [containerW, setContainerW] = React.useState(555);
  const containerRef = React.useRef(null);

  React.useEffect(() => {
    if (!containerRef.current) return;
    const ro = new ResizeObserver(([e]) => setContainerW(e.contentRect.width));
    ro.observe(containerRef.current);
    return () => ro.disconnect();
  }, []);

  const filtered = P2.filter((p) => {
    const f = L2.FILTERS.find((x) => x.id === filter);
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

  return (
    <div ref={containerRef} style={{
      width: '100%', height: '100%', display: 'flex', flexDirection: 'column',
      background: T2.colors.bg, color: T2.colors.text,
      font: `${T2.sizes.fontBase}px ${T2.fonts.ui}`,
      borderRadius: T2.sizes.radius, overflow: 'hidden',
    }}>
      {/* ── Toolbar */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: T2.sizes.gap,
        padding: `${T2.sizes.pad}px`,
        borderBottom: `1px solid ${T2.colors.border}`,
      }}>
        <C2.Input value={search} onChange={setSearch} placeholder="Search FX…" leftIcon="search"
          rightSlot={search && (
            <span onClick={() => setSearch('')} style={{ color: T2.colors.textMute, cursor: 'pointer', display: 'inline-flex', padding: 2 }}>
              <Icon name="close" size={10} />
            </span>
          )} />
        <C2.IconBtn icon="scan" title="Rescan" />
        <C2.IconBtn icon="sort" title="Sort A→Z" />
      </div>

      {/* ── Chips */}
      <L2.ChipRow>
        {L2.FILTERS.map((f) => (
          <C2.Pill key={f.id} icon={f.icon} label={f.label} title={f.title || f.label}
            active={filter === f.id && !activeTab}
            onClick={() => { setFilter(f.id); setActiveTab(null); }} />
        ))}
        <C2.Sep vert style={{ height: T2.sizes.chipH * 0.7, margin: `0 ${T2.sizes.padSmall}px` }} />
        <div style={{ display: 'flex', gap: T2.sizes.gap, overflowX: 'auto', flex: 1, minWidth: 0, scrollbarWidth: 'thin' }}>
          {tabs.map((t, i) => (
            <C2.Tab key={i} label={t} active={activeTab === i}
              onClick={() => setActiveTab(activeTab === i ? null : i)}
              onClose={() => setTabs(tabs.filter((_, j) => j !== i))} />
          ))}
        </div>
        <C2.IconBtn icon="plus" title="New tab" size="sm" style={{ height: T2.sizes.chipH, minWidth: T2.sizes.chipH }} />
      </L2.ChipRow>

      {/* ── Body — pane labels minimal, no mini-toolbars */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0, background: T2.colors.borderSoft }}>
        <div style={{ width: `${splitRatio * 100}%`, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <div style={{ padding: `${T2.sizes.padSmall}px ${T2.sizes.pad}px`, background: T2.colors.bg, borderBottom: `1px solid ${T2.colors.borderSoft}`, flexShrink: 0 }}>
            <L2.PaneLabel icon="folder" text="Plugins" count={filtered.length} />
          </div>
          <L2.ScrollList>
            {filtered.map((p, i) => (
              <L2.PluginRow key={i} p={p} selected={selected.has(i)}
                onClick={() => toggleSel(i)} onDoubleClick={() => addToChain(p)} />
            ))}
          </L2.ScrollList>
        </div>
        <L2.Splitter ratio={splitRatio} setRatio={setSplitRatio} containerW={containerW} />
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <div style={{ padding: `${T2.sizes.padSmall}px ${T2.sizes.pad}px`, background: T2.colors.bg, borderBottom: `1px solid ${T2.colors.borderSoft}`, flexShrink: 0 }}>
            <L2.PaneLabel icon="layers" text="Chain" count={chain.length} />
          </div>
          <L2.ScrollList>
            {chain.length === 0 ? (
              <div style={{ padding: T2.sizes.padLarge, color: T2.colors.textMute, font: `${T2.sizes.fontSm}px ${T2.fonts.ui}`, textAlign: 'center' }}>
                Empty chain. Double-click to add.
              </div>
            ) : chain.map((fx, i) => (
              <L2.ChainRow key={i} fx={fx} idx={i}
                onBypass={() => bypass(i)} onRemove={() => remove(i)} onOpen={() => {}} />
            ))}
          </L2.ScrollList>
        </div>
      </div>

      {/* ── Bottom bar : 1 line, primary actions only */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: T2.sizes.gap,
        padding: `${T2.sizes.padSmall}px ${T2.sizes.pad}px`,
        borderTop: `1px solid ${T2.colors.border}`, background: T2.colors.surface,
        position: 'relative',
      }}>
        <C2.Btn icon="add" label={`Add${selected.size ? ` (${selected.size})` : ''}`}
          title="Add selected to chain"
          style={{ color: selected.size ? T2.colors.text : T2.colors.textDim,
            borderColor: selected.size ? T2.colors.accentDim : T2.colors.border,
            background: selected.size ? T2.colors.accentDim : 'transparent' }} />
        <C2.Sep vert style={{ height: T2.sizes.btnH * 0.6 }} />
        <C2.IconBtn icon="dice" title={`Random ${randomCount}`}
          onClick={() => setRandomMenuOpen(!randomMenuOpen)} active={randomMenuOpen} />
        <C2.Slider value={randomCount} onChange={setRandomCount} min={1} max={12} width={70} />
        <div style={{ flex: 1 }} />
        <C2.IconBtn icon="erase" title="Clear chain" onClick={() => setChain([])} danger />
        <C2.IconBtn icon="gear" title="Settings" active={settingsOpen} onClick={() => setSettingsOpen(!settingsOpen)} />
        {settingsOpen && (
          <div style={{ position: 'absolute', bottom: '100%', right: T2.sizes.pad, zIndex: 10 }}>
            <L2.SettingsMenu open={settingsOpen} onClose={() => setSettingsOpen(false)} settings={settings} setSettings={setSettings} anchor="right" />
          </div>
        )}
      </div>
    </div>
  );
};

window.FXBrowserV2 = FXBrowserV2;
