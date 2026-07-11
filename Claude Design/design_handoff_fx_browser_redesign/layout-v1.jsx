// V1 — Compact: pane-local mini-toolbars, no global footer.
const T1 = window.CP_THEME;
const C1 = window.CP;
const L1 = window.LAYOUT;
const { PLUGINS: P1, CHAIN_INIT: CI1, TABS: TB1 } = window.MOCK;

const FXBrowserV1 = () => {
  const [search, setSearch] = React.useState('');
  const [filter, setFilter] = React.useState('all');
  const [activeTab, setActiveTab] = React.useState(null);
  const [tabs, setTabs] = React.useState(TB1);
  const [selected, setSelected] = React.useState(new Set([0, 4]));
  const [chain, setChain] = React.useState(CI1);
  const [randomCount, setRandomCount] = React.useState(3);
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  const [settings, setSettings] = React.useState({ autoOpen: true, replace: false, fromVisible: true });
  const [splitRatio, setSplitRatio] = React.useState(0.6);
  const [containerW, setContainerW] = React.useState(555);
  const containerRef = React.useRef(null);

  React.useEffect(() => {
    if (!containerRef.current) return;
    const ro = new ResizeObserver(([e]) => setContainerW(e.contentRect.width));
    ro.observe(containerRef.current);
    return () => ro.disconnect();
  }, []);

  const filtered = P1.filter((p) => {
    const f = L1.FILTERS.find((x) => x.id === filter);
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
      background: T1.colors.bg, color: T1.colors.text,
      font: `${T1.sizes.fontBase}px ${T1.fonts.ui}`,
      borderRadius: T1.sizes.radius, overflow: 'hidden',
    }}>
      {/* ── Toolbar : search + icon-only Scan/Sort/⚙ */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: T1.sizes.gap,
        padding: `${T1.sizes.pad}px ${T1.sizes.pad}px`,
        borderBottom: `1px solid ${T1.colors.border}`,
        position: 'relative',
      }}>
        <C1.Input value={search} onChange={setSearch} placeholder="Search FX…" leftIcon="search"
          rightSlot={search && (
            <span onClick={() => setSearch('')} style={{ color: T1.colors.textMute, cursor: 'pointer', display: 'inline-flex', padding: 2 }}>
              <Icon name="close" size={10} />
            </span>
          )} />
        <C1.IconBtn icon="scan" title="Rescan FX list" />
        <C1.IconBtn icon="sort" title="Sort A→Z" />
        <C1.IconBtn icon="gear" title="Settings" active={settingsOpen} onClick={() => setSettingsOpen(!settingsOpen)} />
        <L1.SettingsMenu open={settingsOpen} onClose={() => setSettingsOpen(false)} settings={settings} setSettings={setSettings} />
      </div>

      {/* ── Filter row : built-in pills + custom tabs (scrollable) + add */}
      <L1.ChipRow>
        {L1.FILTERS.map((f) => (
          <C1.Pill key={f.id} icon={f.icon} label={f.label} title={f.title || f.label}
            active={filter === f.id && !activeTab}
            onClick={() => { setFilter(f.id); setActiveTab(null); }} />
        ))}
        <C1.Sep vert style={{ height: T1.sizes.chipH * 0.7, margin: `0 ${T1.sizes.padSmall}px` }} />
        <div style={{ display: 'flex', gap: T1.sizes.gap, overflowX: 'auto', flex: 1, minWidth: 0, scrollbarWidth: 'thin' }}>
          {tabs.map((t, i) => (
            <C1.Tab key={i} label={t} active={activeTab === i}
              onClick={() => { setActiveTab(activeTab === i ? null : i); }}
              onClose={() => setTabs(tabs.filter((_, j) => j !== i))} />
          ))}
        </div>
        <C1.IconBtn icon="plus" title="New tab" size="sm" style={{ height: T1.sizes.chipH, minWidth: T1.sizes.chipH }} />
      </L1.ChipRow>

      {/* ── Body : 60/40 splitter, fills available height */}
      <div style={{ flex: 1, display: 'flex', minHeight: 0, background: T1.colors.borderSoft }}>
        {/* Plugins pane */}
        <div style={{ width: `${splitRatio * 100}%`, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <L1.PaneHeader>
            <L1.PaneLabel icon="folder" text="Plugins" count={filtered.length} />
            <div style={{ flex: 1 }} />
            {selected.size > 0 && (
              <C1.Btn icon="add" label={`Add (${selected.size})`} title="Add selected to chain"
                onClick={() => { selected.forEach((i) => addToChain(filtered[i])); setSelected(new Set()); }}
                style={{ color: T1.colors.text, borderColor: T1.colors.accentDim, background: T1.colors.accentDim }} />
            )}
          </L1.PaneHeader>
          <L1.ScrollList>
            {filtered.map((p, i) => (
              <L1.PluginRow key={i} p={p} selected={selected.has(i)}
                onClick={() => toggleSel(i)}
                onDoubleClick={() => addToChain(p)} />
            ))}
          </L1.ScrollList>
        </div>

        <L1.Splitter ratio={splitRatio} setRatio={setSplitRatio} containerW={containerW} />

        {/* Chain pane */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <L1.PaneHeader>
            <L1.PaneLabel icon="layers" text="Chain" count={chain.length} />
            <div style={{ flex: 1 }} />
            <C1.Slider value={randomCount} onChange={setRandomCount} min={1} max={12} width={50} />
            <C1.IconBtn icon="dice" title={`Random ${randomCount} ${settings.fromVisible ? '(visible)' : '(all)'}`} />
            <C1.IconBtn icon="erase" title="Clear chain" onClick={() => setChain([])} danger />
          </L1.PaneHeader>
          <L1.ScrollList>
            {chain.length === 0 ? (
              <div style={{ padding: T1.sizes.padLarge, color: T1.colors.textMute, font: `${T1.sizes.fontSm}px ${T1.fonts.ui}`, textAlign: 'center' }}>
                Empty chain. Double-click a plugin to add.
              </div>
            ) : chain.map((fx, i) => (
              <L1.ChainRow key={i} fx={fx} idx={i}
                onBypass={() => bypass(i)} onRemove={() => remove(i)} onOpen={() => {}} />
            ))}
          </L1.ScrollList>
        </div>
      </div>
    </div>
  );
};

window.FXBrowserV1 = FXBrowserV1;
