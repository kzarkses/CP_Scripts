// CP_FXConstellation — port mockup en CP_Toolkit
// Palette dark REAPER-ish, Tahoma, rounding=0, scale 1.0

const THEMES = {
  default_dark: {
    window_bg: '#212124', text: '#e0e0e0', text_dim: '#808080',
    border: '#4d4d52', frame: '#333339', frame_h: '#42424a',
    button: '#3d3d42', button_h: '#525258', button_a: '#2e2e33',
    accent: '#5999d9', accent_h: '#73b3f3', accent_a: '#3f80c0',
    header: '#38383d', title_bar: '#1a1a1c', title_text: '#b3b3b8',
    separator: '#4d4d52', tab: '#333339', tab_active: '#42424a',
    track_color: '#9e9e9e',
  },
  reaper_classic: {
    window_bg: '#2e2e2e', text: '#c7c7c7', text_dim: '#7a7a7a',
    border: '#4a4a4a', frame: '#383838', frame_h: '#454545',
    button: '#474747', button_h: '#595959', button_a: '#333',
    accent: '#668c66', accent_h: '#80a680', accent_a: '#4d734d',
    header: '#383838', title_bar: '#242424', title_text: '#b8b8b8',
    separator: '#4a4a4a', tab: '#383838', tab_active: '#4d4d4d',
    track_color: '#9e9e9e',
  },
  midnight: {
    window_bg: '#14141f', text: '#ccd0e6', text_dim: '#5c628a',
    border: '#33334d', frame: '#1f1f2e', frame_h: '#2d2d42',
    button: '#26263a', button_h: '#383852', button_a: '#1a1a2b',
    accent: '#6680e6', accent_h: '#8099ff', accent_a: '#4d66cc',
    header: '#1f1f2e', title_bar: '#0f0f17', title_text: '#9ea3c7',
    separator: '#33334d', tab: '#1f1f2e', tab_active: '#2e2e47',
    track_color: '#7d80a3',
  },
  light: {
    window_bg: '#ebebed', text: '#26262b', text_dim: '#808085',
    border: '#b8b8bc', frame: '#d9d9dc', frame_h: '#cccccf',
    button: '#d1d1d6', button_h: '#bfbfc7', button_a: '#aeaeb8',
    accent: '#3373bf', accent_h: '#4d8cd9', accent_a: '#2659a6',
    header: '#d1d1d6', title_bar: '#d1d1d6', title_text: '#404045',
    separator: '#b3b3b8', tab: '#d9d9dc', tab_active: '#e6e6eb',
    track_color: '#666',
  },
};

// ============================================================================
// CP_TOOLKIT PRIMITIVES — reproduisent gfx natif (rounding=0, Tahoma, no AA fancy)
// ============================================================================
const tk = (theme) => ({
  font: { fontFamily: '"Tahoma", "Geneva", "DejaVu Sans", sans-serif', fontSize: 12, color: theme.text },
  mono: { fontFamily: '"Consolas", "Courier New", monospace', fontSize: 12 },
});

function TitleBar({ title, theme, onSettings }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      height: 28, background: theme.title_bar, borderBottom: `1px solid ${theme.border}`,
      padding: '0 8px', fontFamily: 'Tahoma', fontSize: 12, fontWeight: 'bold',
      color: theme.title_text, userSelect: 'none',
    }}>
      <span>{title}</span>
      <div style={{ display: 'flex', gap: 4 }}>
        <button style={btnTitleStyle(theme)}>⚙</button>
        <button style={{...btnTitleStyle(theme), color: '#cc4040'}}>×</button>
      </div>
    </div>
  );
}
const btnTitleStyle = (t) => ({
  width: 22, height: 20, background: 'transparent', border: 'none',
  color: t.title_text, fontFamily: 'Tahoma', fontSize: 14, cursor: 'pointer',
  display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 0,
});

function Header({ children, theme }) {
  return (
    <div style={{
      fontFamily: 'Tahoma', fontSize: 14, fontWeight: 'bold', color: theme.text,
      marginBottom: 4, letterSpacing: 0.3,
    }}>{children}</div>
  );
}

function CollapsingHeader({ label, open = true, theme, onToggle }) {
  return (
    <div onClick={onToggle} style={{
      cursor: 'pointer', fontFamily: 'Tahoma', fontSize: 14, fontWeight: 'bold',
      color: theme.text, padding: '4px 0', display: 'flex', alignItems: 'center', gap: 4,
      borderBottom: `1px solid ${theme.separator}`,
    }}>
      <span style={{ fontSize: 10, width: 12 }}>{open ? '▼' : '▶'}</span>
      <span>{label}</span>
    </div>
  );
}

function Btn({ children, theme, w, active, ghost, style: extraStyle = {} }) {
  return (
    <button style={{
      height: 24, minWidth: w || 'auto', width: w || undefined,
      padding: '0 10px',
      background: active ? theme.button_a : (ghost ? 'transparent' : theme.button),
      border: `1px solid ${theme.border}`, color: theme.text,
      fontFamily: 'Tahoma', fontSize: 12, cursor: 'pointer',
      borderRadius: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      ...extraStyle,
    }}>{children}</button>
  );
}

function Slider({ label, value, min = 0, max = 1, theme, w = 200, suffix = '', fmt }) {
  const t = (value - min) / (max - min);
  const formatted = fmt ? fmt(value) : value.toFixed(2) + suffix;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
      {label && <span style={{ fontFamily: 'Tahoma', fontSize: 12, color: theme.text, minWidth: 60 }}>{label}</span>}
      <div style={{
        position: 'relative', height: 18, width: w, background: theme.frame,
        border: `1px solid ${theme.border}`, overflow: 'hidden',
      }}>
        <div style={{
          position: 'absolute', left: 0, top: 0, bottom: 0,
          width: `${t * 100}%`, background: theme.accent,
        }}></div>
        <div style={{
          position: 'absolute', inset: 0, display: 'flex', alignItems: 'center',
          justifyContent: 'center', fontFamily: 'Consolas, monospace', fontSize: 11,
          color: theme.text, mixBlendMode: 'difference', filter: 'invert(1) grayscale(1) contrast(2)',
          textShadow: '0 0 1px rgba(0,0,0,0.5)',
        }}>{formatted}</div>
      </div>
    </div>
  );
}

function ComboBox({ value, theme, w = 128 }) {
  return (
    <div style={{
      height: 22, width: w, background: theme.frame, border: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '0 6px', fontFamily: 'Tahoma', fontSize: 12, color: theme.text, cursor: 'pointer',
    }}>
      <span>{value}</span><span style={{ fontSize: 9, color: theme.text_dim }}>▼</span>
    </div>
  );
}

function InputText({ value, theme, w = 128, hint }) {
  return (
    <div style={{
      height: 22, width: w, background: theme.frame, border: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', padding: '0 6px',
      fontFamily: 'Tahoma', fontSize: 12, color: value ? theme.text : theme.text_dim,
    }}>{value || hint}</div>
  );
}

function Checkbox({ checked, label, theme }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontFamily: 'Tahoma', fontSize: 12, color: theme.text }}>
      <div style={{
        width: 16, height: 16, background: theme.frame, border: `1px solid ${theme.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: theme.accent, fontSize: 12, fontWeight: 'bold',
      }}>{checked ? '✓' : ''}</div>
      {label && <span>{label}</span>}
    </div>
  );
}

function Separator({ theme }) {
  return <div style={{ height: 1, background: theme.separator, margin: '6px 0' }}></div>;
}

// ============================================================================
// XY PAD
// ============================================================================
function XYPad({ theme, x = 0.62, y = 0.45, granular = false, gridSize = 3 }) {
  const pad = 298;
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
        <span style={{ fontFamily: 'Tahoma', fontSize: 14, fontWeight: 'bold', color: theme.text }}>▼ XY PAD</span>
        <span style={{ fontFamily: 'Tahoma', fontSize: 14, color: theme.text }}>↻</span>
      </div>
      <Separator theme={theme} />
      <div style={{
        position: 'relative', width: pad, height: pad,
        background: '#1c1c1c', border: `1px solid ${theme.border}`,
      }}>
        {/* center crosshair */}
        <div style={{ position: 'absolute', left: pad/2, top: 0, bottom: 0, width: 1, background: '#3d3d3d' }}></div>
        <div style={{ position: 'absolute', top: pad/2, left: 0, right: 0, height: 1, background: '#3d3d3d' }}></div>
        {/* granular grid */}
        {granular && [...Array(gridSize - 1)].map((_, i) => (
          <React.Fragment key={i}>
            <div style={{ position: 'absolute', left: ((i+1)/gridSize)*pad, top: 0, bottom: 0, width: 1, background: '#3d3d3d99' }}></div>
            <div style={{ position: 'absolute', top: ((i+1)/gridSize)*pad, left: 0, right: 0, height: 1, background: '#3d3d3d99' }}></div>
          </React.Fragment>
        ))}
        {granular && [...Array(gridSize)].flatMap((_, gy) =>
          [...Array(gridSize)].map((_, gx) => {
            const cx = (gx + 0.5) / gridSize * pad;
            const cy = (gy + 0.5) / gridSize * pad;
            const r = pad / gridSize;
            return (
              <React.Fragment key={`${gx}-${gy}`}>
                <div style={{
                  position: 'absolute', left: cx - r, top: cy - r, width: r*2, height: r*2,
                  borderRadius: '50%', border: '1px solid #66666644',
                }}></div>
                <div style={{
                  position: 'absolute', left: cx - 4, top: cy - 4, width: 8, height: 8,
                  borderRadius: '50%', background: '#fff',
                }}></div>
              </React.Fragment>
            );
          })
        )}
        {/* main dot */}
        {!granular && (
          <div style={{
            position: 'absolute', left: x*pad - 8, top: (1-y)*pad - 8, width: 16, height: 16,
            borderRadius: '50%', background: '#fff',
          }}></div>
        )}
      </div>
      <div style={{ fontFamily: 'Consolas, monospace', fontSize: 12, color: theme.text, marginTop: 6 }}>
        Position: {x.toFixed(2)}, {y.toFixed(2)}
      </div>
    </div>
  );
}

// ============================================================================
// FX CARD (horizontal scrollable list)
// ============================================================================
function FXCard({ theme, name, params = [], collapsed = false, enabled = true, selected = 0 }) {
  if (collapsed) {
    return (
      <div style={{
        width: 28, height: 320, background: theme.window_bg, border: `1px solid ${theme.border}`,
        display: 'flex', flexDirection: 'column', alignItems: 'center', padding: 4, gap: 4,
      }}>
        <Btn theme={theme} w={20} style={{height: 20, padding: 0, fontSize: 11}}>+</Btn>
        <div style={{
          writingMode: 'vertical-rl', transform: 'rotate(180deg)', fontFamily: 'Tahoma',
          fontSize: 11, color: theme.text, marginTop: 4, whiteSpace: 'nowrap',
        }}>{name}</div>
      </div>
    );
  }
  return (
    <div style={{
      width: 350, background: theme.window_bg, border: `1px solid ${theme.border}`,
      padding: 8, display: 'flex', flexDirection: 'column', gap: 4,
    }}>
      {/* header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginBottom: 2 }}>
        <Btn theme={theme} w={20} style={{height: 20, padding: 0, fontSize: 11}}>−</Btn>
        <div style={{
          flex: 1, fontFamily: 'Tahoma', fontSize: 12, fontWeight: 'bold', color: theme.text,
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>{name}</div>
        <Btn theme={theme} w={20} style={{height: 20, padding: 0, fontSize: 10}} active={!enabled}>B</Btn>
        <Btn theme={theme} w={20} style={{height: 20, padding: 0, fontSize: 10}}>S</Btn>
        <Btn theme={theme} w={20} style={{height: 20, padding: 0, fontSize: 10, color: '#cc4040'}}>X</Btn>
      </div>
      <div style={{ height: 1, background: theme.separator, margin: '2px 0' }}></div>
      <div style={{ fontFamily: 'Tahoma', fontSize: 11, color: theme.text_dim, marginBottom: 2 }}>
        {selected} / {params.length} selected
      </div>
      {/* param rows */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {params.map((p, i) => (
          <ParamRow key={i} theme={theme} {...p} />
        ))}
      </div>
    </div>
  );
}

function ParamRow({ theme, name, value, selected, xy, inverted, range_min = 0, range_max = 1 }) {
  const xyColor = xy === 'X' ? '#7099d9' : xy === 'Y' ? '#d97070' : 'transparent';
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 4, fontFamily: 'Tahoma', fontSize: 11 }}>
      <div style={{
        width: 14, height: 14, background: theme.frame, border: `1px solid ${theme.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: theme.accent, fontSize: 10, fontWeight: 'bold',
      }}>{selected ? '✓' : ''}</div>
      <div style={{
        width: 16, height: 14, background: xyColor, border: `1px solid ${theme.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff', fontSize: 10, fontWeight: 'bold',
      }}>{xy || ''}</div>
      <div style={{
        width: 14, height: 14, background: inverted ? theme.accent : theme.frame,
        border: `1px solid ${theme.border}`, color: '#fff', fontSize: 10,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>{inverted ? 'N' : ''}</div>
      <div style={{ flex: 1, color: theme.text, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{name}</div>
      <div style={{
        position: 'relative', height: 14, width: 100, background: theme.frame,
        border: `1px solid ${theme.border}`,
      }}>
        <div style={{
          position: 'absolute', left: `${range_min*100}%`, top: 0, bottom: 0,
          width: `${(range_max-range_min)*100}%`, background: theme.accent + '55',
        }}></div>
        <div style={{
          position: 'absolute', left: `${value*100}%`, top: -1, bottom: -1,
          width: 2, background: theme.accent,
        }}></div>
      </div>
      <span style={{ fontFamily: 'Consolas, monospace', fontSize: 10, color: theme.text_dim, minWidth: 36, textAlign: 'right' }}>
        {(value * 100).toFixed(0)}%
      </span>
    </div>
  );
}

// ============================================================================
// CP_TOOLKIT MOCKUP — full window
// ============================================================================
function ConstellationToolkit({ theme, themeName }) {
  const [navMode, setNavMode] = React.useState(0); // 0 manual, 1 walk, 2 figures
  const [padMode, setPadMode] = React.useState(0); // 0 single, 1 granular
  const navOptions = ['Manual', 'Random Walk', 'Figures'];

  return (
    <div style={{
      width: 1140, background: theme.window_bg, fontFamily: 'Tahoma', fontSize: 12,
      color: theme.text, border: `1px solid ${theme.border}`,
      boxShadow: '0 8px 32px rgba(0,0,0,0.4)',
    }}>
      <TitleBar title="CP FX Constellation v1.2" theme={theme} />

      {/* Top region: XY pad + sections columns */}
      <div style={{ display: 'flex', padding: 10, gap: 12 }}>
        <div>
          <XYPad theme={theme} granular={padMode === 1} />
        </div>

        {/* NAVIGATION column */}
        <div style={{ width: 180, display: 'flex', flexDirection: 'column', gap: 4 }}>
          <Header theme={theme}>▼ NAVIGATION</Header>
          <Separator theme={theme} />
          <div style={{display: 'flex', gap: 2, marginBottom: 4}}>
            {navOptions.map((m, i) => (
              <Btn key={i} theme={theme} active={navMode === i} style={{flex: 1, padding: '0 4px', fontSize: 11}}>{m}</Btn>
            ))}
          </div>
          {navMode === 0 && <>
            <Slider label="Smooth" value={0.0} theme={theme} w={120} />
            <Slider label="Speed" value={2.0} min={0.1} max={10} theme={theme} w={120} fmt={v => v.toFixed(1)} />
          </>}
          {navMode === 1 && <>
            <Slider label="Speed" value={2.0} min={0.1} max={10} theme={theme} w={120} fmt={v => v.toFixed(1) + ' Hz'} />
            <Slider label="Jitter" value={0.2} theme={theme} w={120} />
          </>}
          {navMode === 2 && (
            <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 4, marginBottom: 4}}>
              {['○','□','△','◇','Z','∞'].map((s, i) => (
                <div key={i} style={{
                  height: 50, background: i === 0 ? theme.button_a : theme.button,
                  border: `1px solid ${theme.border}`, display: 'flex',
                  alignItems: 'center', justifyContent: 'center', fontSize: 24, color: theme.text,
                  cursor: 'pointer',
                }}>{s}</div>
              ))}
            </div>
          )}
          <Slider label="Range" value={1.0} theme={theme} w={120} />
          <Slider label="Min" value={0.0} theme={theme} w={120} />
          <Slider label="Max" value={1.0} theme={theme} w={120} />
          <div style={{ height: 4 }}></div>
          <div style={{ display: 'flex', gap: 4 }}>
            <Btn theme={theme} style={{flex: 1, fontSize: 11}}>Morph 1</Btn>
            <Btn theme={theme} style={{flex: 1, fontSize: 11}}>Morph 2</Btn>
          </div>
          <Slider label="Morph" value={0.0} theme={theme} w={120} />
          <Btn theme={theme} style={{width: '100%'}}>Auto JSFX <span style={{color:'#5fc15f', marginLeft: 4}}>● ON</span></Btn>
          <Btn theme={theme} style={{width: '100%'}}>Show Env</Btn>
        </div>

        {/* MODE + SOUND GENERATOR + RANDOMIZER */}
        <div style={{ width: 180, display: 'flex', flexDirection: 'column', gap: 4 }}>
          <Header theme={theme}>▼ MODE</Header>
          <Separator theme={theme} />
          <div style={{display: 'flex', gap: 2}}>
            <Btn theme={theme} style={{flex: 1}} active={padMode === 0}>Single</Btn>
            <Btn theme={theme} style={{flex: 1}} active={padMode === 1}>Granular</Btn>
          </div>
          {padMode === 1 && <>
            <ComboBox value="3x3" theme={theme} w={172} />
            <Btn theme={theme} style={{width: '100%'}}>Randomize</Btn>
            <InputText value="GrainSet1" theme={theme} w={172} />
            <div style={{display: 'flex', gap: 4}}>
              <Btn theme={theme} style={{flex: 1}}>Save</Btn>
              <Btn theme={theme} style={{flex: 1}}>Load</Btn>
            </div>
          </>}
          <div style={{ height: 6 }}></div>

          <Header theme={theme}>▼ RANDOMIZER</Header>
          <Separator theme={theme} />
          <Btn theme={theme} style={{width: '100%', background: theme.accent, color: '#fff', fontWeight: 'bold'}}>ULTRA RANDOM</Btn>
          <Btn theme={theme} style={{width: '100%'}}>FX Order</Btn>
          <div style={{display: 'flex', gap: 4}}>
            <Btn theme={theme} style={{flex: 1}}>Bypass</Btn>
            <div style={{flex: 1}}><Slider value={30} max={100} theme={theme} w="100%" fmt={v => v.toFixed(0) + '%'} /></div>
          </div>
          <div style={{display: 'flex', gap: 4, alignItems: 'center'}}>
            <Btn theme={theme} style={{width: 36}}>XY</Btn>
            <Checkbox checked={true} theme={theme} />
            <Btn theme={theme} style={{flex: 1}}>N (invert)</Btn>
          </div>
          <Btn theme={theme} style={{width: '100%'}}>Ranges</Btn>
          <div style={{display: 'flex', gap: 4}}>
            <div style={{flex: 1}}><Slider value={0.0} theme={theme} w="100%" /></div>
            <div style={{flex: 1}}><Slider value={1.0} theme={theme} w="100%" /></div>
          </div>
          <Btn theme={theme} style={{width: '100%'}}>Bases</Btn>
          <Slider value={0.3} theme={theme} w={172} />
          <Btn theme={theme} style={{width: '100%'}}>Parameters</Btn>
          <div style={{display: 'flex', gap: 4}}>
            <div style={{flex: 1}}><Slider value={3} min={1} max={300} theme={theme} w="100%" fmt={v => v.toFixed(0)} /></div>
            <div style={{flex: 1}}><Slider value={8} min={1} max={300} theme={theme} w="100%" fmt={v => v.toFixed(0)} /></div>
          </div>
        </div>

        {/* PRESETS */}
        <div style={{ width: 180, display: 'flex', flexDirection: 'column', gap: 4 }}>
          <Header theme={theme}>▼ PRESETS</Header>
          <Separator theme={theme} />
          <div style={{display: 'flex', gap: 4}}>
            <Btn theme={theme} style={{flex: 1}}>Save</Btn>
            <Btn theme={theme} style={{flex: 1}}>Save As</Btn>
          </div>
          <ComboBox value="Drum Bus Glitch" theme={theme} w={172} />
          <div style={{display: 'flex', gap: 4}}>
            <Btn theme={theme} style={{flex: 1}}>Rename</Btn>
            <Btn theme={theme} style={{flex: 1}}>Delete</Btn>
          </div>
          <div style={{ height: 4 }}></div>
          <Header theme={theme}>SNAPSHOTS</Header>
          <Separator theme={theme} />
          <InputText value="Snapshot4" theme={theme} w={172} />
          <Btn theme={theme} style={{width: '100%'}}>Save</Btn>
          <div style={{ height: 2 }}></div>
          {['Snapshot1', 'Snapshot2', 'Snapshot3'].map(n => (
            <div key={n} style={{display: 'flex', gap: 2}}>
              <Btn theme={theme} style={{flex: 1, justifyContent: 'flex-start'}}>{n}</Btn>
              <Btn theme={theme} w={22}>R</Btn>
              <Btn theme={theme} w={22} style={{color: '#cc4040'}}>X</Btn>
            </div>
          ))}
        </div>
      </div>

      {/* FX SETTINGS bottom */}
      <div style={{ borderTop: `1px solid ${theme.separator}`, padding: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 6 }}>
          <Header theme={theme}>▼ FX SETTINGS</Header>
          <span style={{ fontFamily: 'Tahoma', fontSize: 12, color: theme.text }}>
            | Selected: 14 | Drum Bus Glitch
          </span>
        </div>
        <Separator theme={theme} />
        <div style={{ display: 'flex', gap: 8 }}>
          <div style={{ width: 120, display: 'flex', flexDirection: 'column', gap: 4 }}>
            <Btn theme={theme} style={{width: '100%'}}>Add FX...</Btn>
            <Btn theme={theme} style={{width: '100%'}}>Show Filters</Btn>
            <Btn theme={theme} style={{width: '100%'}}>Show All FX</Btn>
            <Btn theme={theme} style={{width: '100%'}}>Close All FX</Btn>
            <div style={{ height: 4 }}></div>
            <Btn theme={theme} style={{width: '100%'}}>Collapse All</Btn>
            <Btn theme={theme} style={{width: '100%'}}>Expand All</Btn>
            <div style={{ height: 4 }}></div>
            <Btn theme={theme} style={{width: '100%'}}>All</Btn>
            <Btn theme={theme} style={{width: '100%'}}>All Cont</Btn>
            <Btn theme={theme} style={{width: '100%'}}>Clear</Btn>
          </div>
          <div style={{ flex: 1, overflow: 'hidden', display: 'flex', gap: 4 }}>
            <FXCard theme={theme} name="ReaEQ" enabled={true} selected={3}
              params={[
                {name: 'Band 1: Frequency', value: 0.32, selected: true, xy: 'X', range_min: 0.1, range_max: 0.7},
                {name: 'Band 1: Gain', value: 0.55, selected: true, xy: 'Y', range_min: 0.3, range_max: 0.8},
                {name: 'Band 1: Q', value: 0.42, selected: true, range_min: 0.2, range_max: 0.6},
                {name: 'Band 2: Frequency', value: 0.65, selected: false},
                {name: 'Band 2: Gain', value: 0.5},
                {name: 'Band 2: Q', value: 0.5},
                {name: 'Wet', value: 1.0},
              ]}
            />
            <FXCard theme={theme} name="ReaComp" enabled={true} selected={4}
              params={[
                {name: 'Threshold', value: 0.4, selected: true, xy: 'X', range_min: 0.2, range_max: 0.7},
                {name: 'Ratio', value: 0.6, selected: true, range_min: 0.3, range_max: 0.9},
                {name: 'Attack', value: 0.15, selected: true, inverted: true, range_min: 0, range_max: 0.4},
                {name: 'Release', value: 0.45, selected: true, xy: 'Y', range_min: 0.2, range_max: 0.7},
                {name: 'Knee', value: 0.5},
                {name: 'Wet', value: 1.0},
                {name: 'Auto Make-up', value: 0.0},
              ]}
            />
            <FXCard theme={theme} name="JS: Chorus" collapsed enabled={false} />
            <FXCard theme={theme} name="ReaDelay" enabled={true} selected={2}
              params={[
                {name: 'Length', value: 0.5, selected: true, xy: 'X', range_min: 0.1, range_max: 0.8},
                {name: 'Feedback', value: 0.4, selected: true, xy: 'Y', range_min: 0.0, range_max: 0.7},
                {name: 'Lowpass', value: 0.7},
                {name: 'Highpass', value: 0.2},
                {name: 'Wet', value: 0.6},
              ]}
            />
            <FXCard theme={theme} name="JS: Bitcrusher" collapsed />
          </div>
        </div>
      </div>
    </div>
  );
}

// ============================================================================
// IMGUI ACTUEL — reproduit le rendu ReaImGui (rounding, accent bleu vif, plus dense)
// ============================================================================
function ConstellationImGui() {
  const c = {
    bg: '#1e1e22', text: '#dcdcdc', dim: '#888', border: '#3a3a40',
    frame: '#2a2a30', button: '#3a3a44', accent: '#4d8cd9',
    titlebar: '#16161a',
  };
  const btn = (label, w, extra = {}) => (
    <button style={{
      height: 22, width: w, padding: '0 8px', background: c.button,
      border: `1px solid ${c.border}`, borderRadius: 4, color: c.text,
      fontFamily: 'sans-serif', fontSize: 12, cursor: 'pointer', ...extra,
    }}>{label}</button>
  );
  const slider = (val, w = 120, label = '') => (
    <div style={{display: 'flex', alignItems: 'center', gap: 4, marginBottom: 2}}>
      {label && <span style={{fontSize: 11, color: c.text, minWidth: 50}}>{label}</span>}
      <div style={{position: 'relative', height: 18, width: w, background: c.frame, borderRadius: 4, border: `1px solid ${c.border}`}}>
        <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: `${val*100}%`, background: c.accent, borderRadius: 4}}></div>
      </div>
    </div>
  );
  return (
    <div style={{
      width: 1140, background: c.bg, fontFamily: 'sans-serif', fontSize: 12,
      color: c.text, border: `1px solid ${c.border}`, borderRadius: 4,
      boxShadow: '0 8px 32px rgba(0,0,0,0.4)', overflow: 'hidden',
    }}>
      {/* OS-style titlebar */}
      <div style={{
        height: 28, background: c.titlebar, display: 'flex', alignItems: 'center',
        justifyContent: 'space-between', padding: '0 10px', color: c.dim, fontSize: 12,
      }}>
        <span>FX Constellation</span>
        <span>— □ ×</span>
      </div>
      <div style={{ padding: 10, display: 'flex', gap: 10 }}>
        <div>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>▼ XY PAD</div>
          <div style={{
            width: 298, height: 298, background: '#222', border: `1px solid #666`,
            position: 'relative', borderRadius: 4,
          }}>
            <div style={{position: 'absolute', left: 149, top: 0, bottom: 0, width: 1, background: '#444'}}></div>
            <div style={{position: 'absolute', top: 149, left: 0, right: 0, height: 1, background: '#444'}}></div>
            <div style={{position: 'absolute', left: 175, top: 130, width: 16, height: 16, borderRadius: '50%', background: '#fff'}}></div>
          </div>
          <div style={{fontFamily: 'monospace', fontSize: 12, marginTop: 6}}>Position: 0.62, 0.45</div>
        </div>
        <div style={{ width: 180 }}>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>▼ NAVIGATION</div>
          <div style={{display: 'flex', gap: 4, marginBottom: 4}}>
            {btn('Manual', 56, {background: c.accent})}
            {btn('Random Walk 🔒', 56, {fontSize: 10})}
            {btn('Figures 🔒', 56, {fontSize: 10})}
          </div>
          {slider(0.0, 172, 'Smooth')}
          {slider(0.2, 172, 'Speed')}
          {slider(1.0, 172, 'Range')}
          {slider(0.0, 172, 'Min')}
          {slider(1.0, 172, 'Max')}
          <div style={{marginTop: 8, display: 'flex', gap: 4}}>
            {btn('Morph 1', 84)}{btn('Morph 2', 84)}
          </div>
          {btn('Auto JSFX', 172, {marginTop: 4, width: 172})}
          {btn('Show Env', 172, {marginTop: 4, width: 172})}
        </div>
        <div style={{ width: 180 }}>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>▼ MODE</div>
          {btn('Single', 172, {width: 172, background: c.accent, marginBottom: 4})}
          {btn('Granular 🔒', 172, {width: 172})}
          <div style={{height: 8}}></div>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>▼ RANDOMIZER</div>
          {btn('ULTRA RANDOM', 172, {width: 172, background: c.accent, fontWeight: 'bold', marginBottom: 4})}
          {btn('FX Order', 172, {width: 172, marginBottom: 4})}
          {btn('Bypass', 172, {width: 172, marginBottom: 4})}
          {btn('Ranges', 172, {width: 172, marginBottom: 4})}
          {btn('Bases', 172, {width: 172, marginBottom: 4})}
          {btn('Parameters', 172, {width: 172})}
        </div>
        <div style={{ width: 180 }}>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>▼ PRESETS</div>
          <div style={{display: 'flex', gap: 4, marginBottom: 4}}>
            {btn('Save', 84)}{btn('Save As', 84)}
          </div>
          <div style={{
            height: 22, background: c.frame, border: `1px solid ${c.border}`,
            borderRadius: 4, padding: '0 6px', display: 'flex', alignItems: 'center',
            justifyContent: 'space-between', fontSize: 12, marginBottom: 4,
          }}><span>Drum Bus Glitch</span><span>▼</span></div>
          <div style={{display: 'flex', gap: 4}}>
            {btn('Rename', 84)}{btn('Delete', 84)}
          </div>
          <div style={{height: 8}}></div>
          <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 4}}>SNAPSHOTS</div>
          <div style={{height: 22, background: c.frame, border: `1px solid ${c.border}`, borderRadius: 4, marginBottom: 4, padding: '0 6px', display: 'flex', alignItems: 'center'}}>Snapshot4</div>
          {btn('Save', 172, {width: 172})}
          <div style={{height: 4}}></div>
          {['Snapshot1', 'Snapshot2', 'Snapshot3'].map(n => (
            <div key={n} style={{display: 'flex', gap: 2, marginBottom: 2}}>
              {btn(n, 124, {textAlign: 'left', justifyContent: 'flex-start', display: 'flex', alignItems: 'center'})}
              {btn('R', 22)}{btn('X', 22, {color: '#cc4040'})}
            </div>
          ))}
        </div>
      </div>
      <div style={{borderTop: `1px solid ${c.border}`, padding: 10}}>
        <div style={{fontSize: 14, fontWeight: 'bold', marginBottom: 6}}>▼ FX SETTINGS | Selected: 14 | Drum Bus Glitch</div>
        <div style={{display: 'flex', gap: 8}}>
          <div style={{width: 120, display: 'flex', flexDirection: 'column', gap: 4}}>
            {btn('Add FX...', '100%', {width: '100%'})}
            {btn('Show Filters', '100%', {width: '100%'})}
            {btn('Show All FX', '100%', {width: '100%'})}
            {btn('Close All FX', '100%', {width: '100%'})}
            {btn('Collapse All', '100%', {width: '100%'})}
            {btn('Expand All', '100%', {width: '100%'})}
            {btn('All', '100%', {width: '100%'})}
            {btn('Clear', '100%', {width: '100%'})}
          </div>
          <div style={{flex: 1, display: 'flex', gap: 4, overflow: 'hidden'}}>
            {['ReaEQ', 'ReaComp', 'ReaDelay'].map(n => (
              <div key={n} style={{
                width: 350, background: c.bg, border: `1px solid ${c.border}`, borderRadius: 4,
                padding: 8,
              }}>
                <div style={{fontSize: 12, fontWeight: 'bold', marginBottom: 4}}>{n}</div>
                <div style={{height: 1, background: c.border, marginBottom: 6}}></div>
                {[...Array(7)].map((_, i) => (
                  <div key={i} style={{display: 'flex', alignItems: 'center', gap: 4, marginBottom: 2}}>
                    <div style={{width: 14, height: 14, background: c.frame, border: `1px solid ${c.border}`, borderRadius: 3}}></div>
                    <span style={{flex: 1, fontSize: 11}}>Param {i+1}</span>
                    <div style={{width: 100, height: 14, background: c.frame, border: `1px solid ${c.border}`, borderRadius: 3, position: 'relative'}}>
                      <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: `${30 + i*7}%`, background: c.accent, borderRadius: 3}}></div>
                    </div>
                  </div>
                ))}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

// ============================================================================
// MAIN APP
// ============================================================================
function App() {
  const TWEAK_DEFAULS = /*EDITMODE-BEGIN*/{
    "themeName": "default_dark",
    "showLabels": true
  }/*EDITMODE-END*/;
  const [tweaks, setTweak] = useTweaks(TWEAK_DEFAULS);
  const theme = THEMES[tweaks.themeName] || THEMES.default_dark;

  return (
    <>
      <DesignCanvas defaultBg="#15151a">
        <DCSection id="port" title="CP_FXConstellation — port ReaImGui → CP_Toolkit">
          <DCArtboard id="before" label="AVANT — ReaImGui (actuel)" width={1180} height={920}>
            <div style={{padding: 20, background: '#0e0e12', minHeight: '100%'}}>
              <ConstellationImGui />
              <div style={{
                marginTop: 16, padding: 12, background: '#1a1a20', border: '1px solid #33333d',
                borderRadius: 4, color: '#aaa', fontFamily: 'system-ui', fontSize: 12,
                lineHeight: 1.5,
              }}>
                <strong style={{color: '#dcdcdc'}}>Stack actuel</strong><br/>
                ReaImGui (Dear ImGui binding) · style chargé via CP_ImGuiStyleLoader · accent bleu ImGui par défaut · rounding 4px · OS-window chrome.
                Tu construis la sidebar avec CollapsingHeader + SliderDouble + Combo + Button, et le XY pad au DrawList.
              </div>
            </div>
          </DCArtboard>

          <DCArtboard id="after" label="APRÈS — CP_Toolkit (port)" width={1180} height={920}>
            <div style={{padding: 20, background: '#0e0e12', minHeight: '100%'}}>
              <ConstellationToolkit theme={theme} themeName={tweaks.themeName} />
              <div style={{
                marginTop: 16, padding: 12, background: '#1a1a20', border: '1px solid #33333d',
                borderRadius: 4, color: '#aaa', fontFamily: 'system-ui', fontSize: 12,
                lineHeight: 1.5,
              }}>
                <strong style={{color: '#dcdcdc'}}>CP_Toolkit</strong><br/>
                Tahoma 12px / Consolas pour valeurs · rounding=0 (pixel-perfect gfx) · custom title bar (Theme.title_bar) · UI.CollapsingHeader / UI.SliderDouble / UI.Combo / UI.Button / UI.Canvas pour le XY pad.
                Theme switcher actif via Tweaks → utilisera ApplyPreset() au runtime dans le script.
              </div>
            </div>
          </DCArtboard>
        </DCSection>

        <DCSection id="themes" title="Variations de thème CP_Toolkit (le port suit le preset actif)">
          {Object.entries(THEMES).map(([key, t]) => (
            <DCArtboard key={key} id={`t-${key}`} label={key.replace('_', ' ').toUpperCase()} width={1180} height={780}>
              <div style={{padding: 20, background: '#0e0e12', minHeight: '100%'}}>
                <ConstellationToolkit theme={t} themeName={key} />
              </div>
            </DCArtboard>
          ))}
        </DCSection>
      </DesignCanvas>

      <TweaksPanel title="Tweaks">
        <TweakSection title="Theme actif (artboard 'APRÈS')">
          <TweakSelect
            label="Preset"
            value={tweaks.themeName}
            onChange={v => setTweak('themeName', v)}
            options={[
              { value: 'default_dark', label: 'Default Dark (REAPER-ish)' },
              { value: 'reaper_classic', label: 'REAPER Classic (verdâtre)' },
              { value: 'midnight', label: 'Midnight (bleu nuit)' },
              { value: 'light', label: 'Light' },
            ]}
          />
        </TweakSection>
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
