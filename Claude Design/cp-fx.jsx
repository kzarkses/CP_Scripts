// FX SETTINGS — la grosse colonne de droite : actions verticales + FX rows

// ── FX row : check + name + P/X/Y/N + range_min + range_max + value pill ──
function FXRow({ theme, name, selected, p, x, y, n, rangeMin = 0.0, rangeMax = 1.0, value = 0.5, enabled = true }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 4, height: 22,
      fontFamily: cpFont, fontSize: 11, color: theme.text,
    }}>
      <CPCheck checked={selected} theme={theme} size={14} />
      <div style={{
        width: 60, overflow: 'hidden', textOverflow: 'ellipsis',
        whiteSpace: 'nowrap', color: theme.text,
      }}>{name}</div>
      <CPPill label="P" active={p} theme={theme} />
      <CPPill label="X" active={x} theme={theme} />
      <CPPill label="Y" active={y} theme={theme} />
      <div style={{ width: 40 }}>
        <CPSlider value={rangeMin} theme={theme} fmt={v => v.toFixed(1)} h={16} />
      </div>
      <div style={{ width: 40 }}>
        <CPSlider value={rangeMax} theme={theme} fmt={v => v.toFixed(2)} h={16} />
      </div>
      <CPPill label={enabled ? 'ON' : 'OFF'} active={enabled} theme={theme} w={32} h={16} />
    </div>
  );
}

// ── FX CARD (one FX with its rows) ──────────────────────────────────────────
function FXCard({ theme, name, params = [], collapsed, enabled = true }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3, width: '100%' }}>
      {/* FX header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginBottom: 2 }}>
        <CPBtn theme={theme} style={{ width: 18, padding: 0, fontSize: 10, height: 18 }}>−</CPBtn>
        <CPInput value={name} theme={theme} h={18} />
        <CPBtn theme={theme} style={{ width: 18, padding: 0, fontSize: 10, height: 18 }}>✓</CPBtn>
      </div>
      {/* Action row */}
      <div style={{ display: 'flex', gap: 3, marginBottom: 3 }}>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>All</CPBtn>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>Cont</CPBtn>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>None</CPBtn>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>Rnd</CPBtn>
        <div style={{ width: 18 }}><CPSlider value={3} max={20} theme={theme} fmt={v => v.toFixed(0)} h={18} /></div>
      </div>
      {/* Action row 2 — RandXY / RandRng / RndBase */}
      <div style={{ display: 'flex', gap: 3, marginBottom: 4 }}>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>RandXY</CPBtn>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>RandRng</CPBtn>
        <CPBtn theme={theme} fontSize={10} h={18} style={{ flex: 1 }}>RndBase</CPBtn>
      </div>
      {/* Param rows */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {params.map((p, i) => <FXRow key={i} theme={theme} {...p} />)}
      </div>
    </div>
  );
}

// ── FX SETTINGS section (left actions column + cards horizontal) ────────────
function SectionFXSettings({ theme, layout = 'horizontal', onAddFX }) {
  // From the screenshot: ReaEQ-like FX with parameters Delay / Rate / Depth / Spread / Taps
  const fxs = [
    {
      name: 'kHs Chorus',
      params: [
        { name: 'Delay',  selected: true, p: true, y: false, rangeMin: 0.0, rangeMax: 1.0, enabled: true },
        { name: 'Rate',   selected: true, p: true, x: true,  rangeMin: 0.0, rangeMax: 0.47, enabled: true },
        { name: 'Depth',  selected: true, p: true, y: true,  rangeMin: 0.0, rangeMax: 0.39, enabled: true },
        { name: 'Spread', selected: true, p: true, x: true,  rangeMin: 0.0, rangeMax: 1.0, enabled: true },
        { name: 'Taps',   selected: true, p: true,           rangeMin: 0.0, rangeMax: 1.0, enabled: false },
      ],
    },
  ];
  return (
    <div style={{ display: 'flex', gap: 8, height: '100%' }}>
      <div style={{ width: 90, display: 'flex', flexDirection: 'column', gap: 4 }}>
        <CPBtn theme={theme} style={{ width: '100%' }} onClick={onAddFX}>Add FX...</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Show Filters</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Show All FX</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Close All FX</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Collapse All</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Expand All</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>All</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>All Cont</CPBtn>
        <CPBtn theme={theme} style={{ width: '100%' }}>Clear</CPBtn>
      </div>
      <div style={{ flex: 1, display: 'flex', gap: 8, overflowX: 'auto' }}>
        {fxs.map((fx, i) => (
          <div key={i} style={{ minWidth: 380 }}>
            <FXCard theme={theme} {...fx} />
          </div>
        ))}
      </div>
    </div>
  );
}

window.SectionFXSettings = SectionFXSettings;
window.FXRow = FXRow;
window.FXCard = FXCard;
