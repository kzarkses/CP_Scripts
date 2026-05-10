// Main app — design canvas with Dock + Window views, dialog overlay, tweaks

function App() {
  const TWEAK_DEFAULS = /*EDITMODE-BEGIN*/{
    "themeName": "teal",
    "showAddFX": false
  }/*EDITMODE-END*/;
  const [tweaks, setTweak] = useTweaks(TWEAK_DEFAULS);
  const theme = window.CP_THEMES[tweaks.themeName] || window.CP_THEMES.teal;
  const [dialog, setDialog] = React.useState(false);

  return (
    <>
      <DesignCanvas defaultBg="#0a0a0d">
        <DCSection id="port" title="CP_FXConstellation — port ReaImGui → CP_Toolkit (palette teal réelle)">
          <DCArtboard id="dock" label="Vue DOCK — REAPER bottom panel (réordonnable par drag)" width={1700} height={300}>
            <div style={{ width: '100%', height: 280, position: 'relative' }}>
              <DockView theme={theme} onAddFX={() => setDialog(true)} />
              <AddFXDialog theme={theme} open={dialog} onClose={() => setDialog(false)} />
            </div>
          </DCArtboard>

          <DCArtboard id="window" label="Vue WINDOW — XY pad central, sections autour" width={1140} height={760}>
            <div style={{ position: 'relative' }}>
              <WindowView theme={theme} onAddFX={() => setDialog(true)} />
              <AddFXDialog theme={theme} open={dialog} onClose={() => setDialog(false)} />
            </div>
          </DCArtboard>

          <DCArtboard id="addfx" label="Add FX dialog (sortie statique)" width={760} height={520}>
            <div style={{ position: 'relative', width: 720, height: 480, margin: '20px auto' }}>
              <AddFXDialogStatic theme={theme} />
            </div>
          </DCArtboard>
        </DCSection>

        <DCSection id="themes" title="Variations de thème (la vue Dock dans chaque preset)">
          {Object.entries(window.CP_THEMES).filter(([k]) => k !== tweaks.themeName).map(([key, t]) => (
            <DCArtboard key={key} id={`t-${key}`} label={t.name} width={1700} height={300}>
              <div style={{ width: '100%', height: 280 }}>
                <DockView theme={t} onAddFX={() => {}} />
              </div>
            </DCArtboard>
          ))}
        </DCSection>
      </DesignCanvas>

      <TweaksPanel title="Tweaks">
        <TweakSection title="Theme">
          <TweakSelect
            label="Preset"
            value={tweaks.themeName}
            onChange={v => setTweak('themeName', v)}
            options={Object.entries(window.CP_THEMES).map(([k, t]) => ({ value: k, label: t.name }))}
          />
        </TweakSection>
        <TweakSection title="Modal">
          <TweakButton onClick={() => setDialog(d => !d)}>Toggle Add FX dialog</TweakButton>
        </TweakSection>
      </TweaksPanel>
    </>
  );
}

// ── Static version of Add FX dialog for the third artboard ──────────────────
function AddFXDialogStatic({ theme }) {
  return (
    <div style={{
      width: '100%', height: '100%', background: theme.window_bg,
      border: `1px solid ${theme.border}`, display: 'flex', flexDirection: 'column',
      boxShadow: '0 12px 40px rgba(0,0,0,0.6)',
    }}>
      <AddFXDialogContent theme={theme} />
    </div>
  );
}

function AddFXDialogContent({ theme }) {
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
    <>
      <CPTitleBar title="Add FX — FX Browser" theme={theme} />
      <div style={{ padding: 8, display: 'flex', gap: 8, borderBottom: `1px solid ${theme.separator}` }}>
        <div style={{ flex: 1 }}><CPInput value="" hint="🔍 Search FX..." theme={theme} /></div>
        <CPBtn theme={theme}>Scan</CPBtn>
        <CPBtn theme={theme}>★ Favorite</CPBtn>
      </div>
      <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
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
        <div style={{ flex: 1, overflow: 'auto', padding: 4 }}>
          {fxList.map((fx, i) => (
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 8, padding: '4px 8px',
              fontFamily: cpFont, fontSize: 12, color: i === 3 ? '#1a1a1c' : theme.text,
              background: i === 3 ? theme.accent : 'transparent', cursor: 'pointer',
              fontWeight: i === 3 ? 'bold' : 'normal',
            }}>
              <span style={{ width: 50, color: i === 3 ? '#1a1a1c' : theme.text_dim, fontSize: 10 }}>{fx.cat}</span>
              <span style={{ flex: 1 }}>{fx.name}</span>
              <span style={{ color: i === 3 ? '#1a1a1c' : theme.text_dim, fontSize: 10 }}>★</span>
            </div>
          ))}
        </div>
      </div>
      <div style={{
        padding: 8, borderTop: `1px solid ${theme.separator}`,
        display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8,
      }}>
        <span style={{ fontFamily: cpFont, fontSize: 11, color: theme.text_dim }}>
          14 plugins · selected: kHs Chorus
        </span>
        <div style={{ display: 'flex', gap: 6 }}>
          <CPBtn theme={theme}>Cancel</CPBtn>
          <CPBtn theme={theme} accent>Add to Track</CPBtn>
        </div>
      </div>
    </>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
