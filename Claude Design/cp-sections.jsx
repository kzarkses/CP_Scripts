// Sections de FXConstellation — réplique fidèle des screenshots

// ── SOUND GENERATOR (toggle ON/OFF géant à gauche) ──────────────────────────
function SectionSoundGen({ theme, enabled }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <CPBtn theme={theme} active={enabled} fontSize={11} h={28}
        style={{ width: '100%' }}>
        {enabled ? '● ON' : '○ OFF'}
      </CPBtn>
    </div>
  );
}

// ── NAVIGATION (Manual / Random Walk / Figures + sliders + Morph) ───────────
function SectionNavigation({ theme }) {
  return (
    <>
      <CPCombo value="Manual" theme={theme} />
      <CPSlider value={0.0} theme={theme} fmt={v => v.toFixed(2)} />
      <CPSlider value={2.0} min={0.1} max={10} theme={theme} fmt={v => v.toFixed(1)} />
      <CPSlider value={1.000} theme={theme} fmt={v => v.toFixed(3)} />
      <CPSlider value={0.000} theme={theme} fmt={v => v.toFixed(3)} />
      <CPSlider value={1.000} theme={theme} fmt={v => v.toFixed(3)} />
      <div style={{ display: 'flex', gap: 4 }}>
        <CPBtn theme={theme} style={{ flex: 1 }}>Morph 1</CPBtn>
        <CPBtn theme={theme} style={{ flex: 1 }}>Morph 2</CPBtn>
      </div>
      <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
        <div style={{ flex: 1 }}>
          <CPSlider value={0.000} theme={theme} fmt={v => v.toFixed(3)} />
        </div>
        <span style={{ fontFamily: cpFont, fontSize: 11, color: theme.text }}>Morp</span>
      </div>
      <CPBtn theme={theme} style={{ width: '100%' }}>Auto JSFX</CPBtn>
      <CPBtn theme={theme} style={{ width: '100%' }}>Show Env</CPBtn>
    </>
  );
}

// ── MODE (Single / Granular) ────────────────────────────────────────────────
function SectionMode({ theme, padMode = 0 }) {
  return (
    <>
      <CPBtn theme={theme} active={padMode === 0} style={{ width: '100%' }}>Single</CPBtn>
      <CPBtn theme={theme} active={padMode === 1} style={{ width: '100%' }}>Granular</CPBtn>
    </>
  );
}

// ── XY PAD ──────────────────────────────────────────────────────────────────
function SectionXYPad({ theme, x = 0.5, y = 0.5, granular = false, gridSize = 3, size }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'stretch', flex: 1 }}>
      <div style={{
        position: 'relative', flex: 1, minHeight: size || 280,
        background: '#0e0e0f', border: `1px solid ${theme.border}`,
      }}>
        <PadInner theme={theme} x={x} y={y} granular={granular} gridSize={gridSize} />
      </div>
      <div style={{ fontFamily: cpMono, fontSize: 11, color: theme.text }}>
        Position: {x.toFixed(2)}, {y.toFixed(2)}
      </div>
    </div>
  );
}

function PadInner({ theme, x, y, granular, gridSize }) {
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      {/* center crosshair */}
      <div style={{ position: 'absolute', left: '50%', top: 0, bottom: 0, width: 1, background: '#3a3a3a' }}></div>
      <div style={{ position: 'absolute', top: '50%', left: 0, right: 0, height: 1, background: '#3a3a3a' }}></div>
      {granular && [...Array(gridSize - 1)].map((_, i) => (
        <React.Fragment key={i}>
          <div style={{ position: 'absolute', left: `${((i+1)/gridSize)*100}%`, top: 0, bottom: 0, width: 1, background: '#3a3a3a99' }}></div>
          <div style={{ position: 'absolute', top: `${((i+1)/gridSize)*100}%`, left: 0, right: 0, height: 1, background: '#3a3a3a99' }}></div>
        </React.Fragment>
      ))}
      {/* dot */}
      <div style={{
        position: 'absolute', left: `calc(${x * 100}% - 8px)`,
        top: `calc(${(1 - y) * 100}% - 8px)`,
        width: 16, height: 16, borderRadius: '50%', background: '#fff',
        boxShadow: '0 0 0 1px rgba(0,0,0,0.4)',
      }}></div>
    </div>
  );
}

// ── PRESETS ─────────────────────────────────────────────────────────────────
function SectionPresets({ theme }) {
  return (
    <>
      <div style={{ display: 'flex', gap: 4 }}>
        <CPBtn theme={theme} style={{ flex: 1 }}>Save</CPBtn>
        <CPBtn theme={theme} style={{ flex: 1 }}>Save As</CPBtn>
      </div>
      <CPCombo value="" theme={theme} />
      <div style={{ display: 'flex', gap: 4 }}>
        <CPBtn theme={theme} style={{ flex: 1 }}>Rename</CPBtn>
        <CPBtn theme={theme} style={{ flex: 1 }}>Delete</CPBtn>
      </div>
      <div style={{ height: 4 }}></div>
      <div style={{ fontFamily: cpFont, fontSize: 12, fontWeight: 'bold', color: theme.text, marginTop: 2 }}>
        SNAPSHOTS
      </div>
      <div style={{ height: 1, background: theme.separator, marginBottom: 2 }}></div>
      <CPInput value="Snapshot1" theme={theme} />
      <CPBtn theme={theme} style={{ width: '100%' }}>Save</CPBtn>
    </>
  );
}

// ── RANDOMIZER ──────────────────────────────────────────────────────────────
function SectionRandomizer({ theme }) {
  return (
    <>
      <CPBtn theme={theme} accent style={{ width: '100%', fontWeight: 'bold' }} h={24}>
        ULTRA RANDOM
      </CPBtn>
      <CPBtn theme={theme} style={{ width: '100%' }}>FX Order</CPBtn>
      <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
        <CPBtn theme={theme} style={{ flex: 1 }}>Bypass</CPBtn>
        <div style={{ flex: 1 }}>
          <CPSlider value={30} max={100} theme={theme} fmt={v => v.toFixed(0) + '%'} />
        </div>
      </div>
      <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
        <CPBtn theme={theme} style={{ width: 30, padding: 0, fontSize: 10 }}>XY</CPBtn>
        <CPCheck checked={true} theme={theme} size={16} />
        <div style={{ flex: 1 }}></div>
        <CPBtn theme={theme} style={{ width: 30, padding: 0, fontSize: 11 }}>%</CPBtn>
      </div>
      <CPBtn theme={theme} style={{ width: '100%' }}>Ranges</CPBtn>
      <div style={{ display: 'flex', gap: 4 }}>
        <div style={{ flex: 1 }}><CPSlider value={0.0} theme={theme} fmt={v => v.toFixed(2)} /></div>
        <div style={{ flex: 1 }}><CPSlider value={1.0} theme={theme} fmt={v => v.toFixed(2)} /></div>
      </div>
      <CPBtn theme={theme} style={{ width: '100%' }}>Bases</CPBtn>
      <CPSlider value={0.30} theme={theme} fmt={v => v.toFixed(2)} />
      <div style={{ display: 'flex', gap: 4 }}>
        <div style={{ flex: 1 }}><CPSlider value={0.0} theme={theme} fmt={v => v.toFixed(2)} /></div>
        <div style={{ flex: 1 }}><CPSlider value={1.0} theme={theme} fmt={v => v.toFixed(2)} /></div>
      </div>
      <CPBtn theme={theme} style={{ width: '100%' }}>Parameters</CPBtn>
      <div style={{ display: 'flex', gap: 4 }}>
        <div style={{ flex: 1 }}><CPSlider value={3} min={1} max={300} theme={theme} fmt={v => v.toFixed(0)} /></div>
        <div style={{ flex: 1 }}><CPSlider value={8} min={1} max={300} theme={theme} fmt={v => v.toFixed(0)} /></div>
      </div>
    </>
  );
}

window.SectionSoundGen = SectionSoundGen;
window.SectionNavigation = SectionNavigation;
window.SectionMode = SectionMode;
window.SectionXYPad = SectionXYPad;
window.SectionPresets = SectionPresets;
window.SectionRandomizer = SectionRandomizer;
