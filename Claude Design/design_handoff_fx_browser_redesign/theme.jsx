// CP_Toolkit-inspired theme tokens. Mirrors UI.GetTheme() colors+sizes.
// All values come from theme — never hardcoded inside layout components.
const CP_THEME = {
  colors: {
    bg:        '#1e1e1f',  // window background
    surface:   '#252526',  // panel background
    surface2:  '#2d2d2f',  // raised (hover, selected bg)
    border:    '#363638',  // dividers
    borderSoft:'#2a2a2c',
    text:      '#d4d4d4',
    textDim:   '#8a8a8c',
    textMute:  '#5d5d60',
    accent:    '#7aa2c4',  // muted blue accent
    accentDim: '#4a6680',
    danger:    '#c47a7a',
    warn:      '#c4a87a',
    ok:        '#7ac490',
    bypass:    '#c4a87a',  // bypass state color (amber)
    drag:      '#7aa2c4',
  },
  sizes: {
    rowH:        22,
    rowHSmall:   18,
    rowHLarge:   26,
    chipH:       20,
    inputH:      24,
    btnH:        24,
    iconBtn:     24,
    pad:         6,
    padSmall:    4,
    padLarge:    10,
    gap:         4,
    gapLarge:    8,
    radius:      2,
    fontSm:      10,
    fontBase:    11,
    fontLg:      13,
    paneMinH:    120,
    splitterW:   3,
  },
  fonts: {
    ui:   "'Inter', 'Segoe UI', system-ui, sans-serif",
    mono: "'JetBrains Mono', 'Consolas', monospace",
  },
};

window.CP_THEME = CP_THEME;
