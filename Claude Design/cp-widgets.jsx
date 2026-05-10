// CP_Toolkit widget primitives — fidèles aux screenshots
// Tahoma 12, rounding=0, sliders avec carré teal qui glisse

const cpFont = '"Tahoma", "Geneva", "DejaVu Sans", sans-serif';
const cpMono = '"Consolas", "Courier New", monospace';

// ── Title bar (custom window chrome) ────────────────────────────────────────
function CPTitleBar({ title, theme, lockable, onSettings, dragHandle }) {
  return (
    <div style={{
      height: 28, background: theme.title_bar, borderBottom: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '0 8px', userSelect: 'none', cursor: dragHandle ? 'grab' : 'default',
    }}>
      <div style={{
        fontFamily: cpFont, fontSize: 12, fontWeight: 'bold',
        color: theme.title_text, display: 'flex', alignItems: 'center', gap: 8,
      }}>
        <span>{title}</span>
        {lockable && (
          <span style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            width: 18, height: 18, background: theme.button, color: theme.text,
            fontSize: 10, fontFamily: cpFont,
          }}>L</span>
        )}
      </div>
      <div style={{ display: 'flex', gap: 2 }}>
        <CPIconBtn theme={theme}>⚙</CPIconBtn>
        <CPIconBtn theme={theme} hoverColor={theme.close_btn}>×</CPIconBtn>
      </div>
    </div>
  );
}

function CPIconBtn({ children, theme, hoverColor }) {
  const [h, setH] = React.useState(false);
  return (
    <div onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)} style={{
      width: 22, height: 20, display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: h && hoverColor ? hoverColor : theme.title_text,
      background: h ? theme.button : 'transparent', cursor: 'pointer',
      fontSize: 14, fontFamily: cpFont,
    }}>{children}</div>
  );
}

// ── Section header (collapsing) ─────────────────────────────────────────────
function CPSectionHeader({ label, collapsed, onToggle, theme, extra, draggable }) {
  return (
    <div style={{
      height: 24, padding: '0 8px', background: theme.header,
      display: 'flex', alignItems: 'center', gap: 6, cursor: draggable ? 'grab' : 'pointer',
      borderBottom: `1px solid ${theme.separator}`,
      fontFamily: cpFont, fontSize: 12, fontWeight: 'bold', color: theme.text,
      userSelect: 'none',
    }} onClick={onToggle}>
      <span style={{ fontSize: 9, color: theme.text_dim, width: 10 }}>
        {collapsed ? '▶' : '▼'}
      </span>
      <span style={{ flex: 1, letterSpacing: 0.3 }}>{label}</span>
      {extra}
    </div>
  );
}

// ── Button — flat carré, accent quand actif ─────────────────────────────────
function CPBtn({ children, theme, w, h = 22, active, accent, danger, ghost, fontSize = 12, onClick, style: extra = {} }) {
  const [hover, setHover] = React.useState(false);
  let bg = ghost ? 'transparent' : theme.button;
  let color = theme.text;
  let border = `1px solid ${theme.border}`;
  if (accent || active) {
    bg = active && hover ? theme.accent_h : theme.accent;
    color = '#1a1a1c';
    border = `1px solid ${theme.accent_dim}`;
  } else if (hover) {
    bg = theme.button_h;
  }
  if (danger) color = theme.close_btn;
  return (
    <div onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        height: h, minWidth: w || 'auto', width: w,
        padding: '0 8px', background: bg, border, color,
        fontFamily: cpFont, fontSize, fontWeight: active ? 'bold' : 'normal',
        cursor: 'pointer', display: 'inline-flex', alignItems: 'center',
        justifyContent: 'center', boxSizing: 'border-box', userSelect: 'none',
        ...extra,
      }}>{children}</div>
  );
}

// ── Slider — barre fine + carré teal qui glisse (style observé) ─────────────
function CPSlider({ value, min = 0, max = 1, theme, w = '100%', label, fmt, h = 18 }) {
  const t = (value - min) / (max - min);
  const display = fmt ? fmt(value) : value.toFixed(3);
  const knobSize = 12;
  return (
    <div style={{
      position: 'relative', height: h, width: w,
      background: theme.frame_bg, border: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', boxSizing: 'border-box',
    }}>
      <div style={{
        position: 'absolute', left: `calc(${t * 100}% - ${knobSize/2}px)`,
        top: '50%', transform: 'translateY(-50%)',
        width: knobSize, height: knobSize, background: theme.accent,
      }}></div>
      <div style={{
        flex: 1, textAlign: 'center', fontFamily: cpMono, fontSize: 11,
        color: theme.text, position: 'relative', zIndex: 1, paddingLeft: 4, paddingRight: 4,
      }}>{display}</div>
    </div>
  );
}

// ── Combobox ────────────────────────────────────────────────────────────────
function CPCombo({ value, theme, w = '100%', h = 22 }) {
  return (
    <div style={{
      height: h, width: w, background: theme.frame_bg, border: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '0 6px', fontFamily: cpFont, fontSize: 12, color: theme.text,
      cursor: 'pointer', boxSizing: 'border-box',
    }}>
      <span>{value}</span>
      <span style={{ fontSize: 8, color: theme.text_dim }}>▼</span>
    </div>
  );
}

// ── InputText ───────────────────────────────────────────────────────────────
function CPInput({ value, hint, theme, w = '100%', h = 22 }) {
  return (
    <div style={{
      height: h, width: w, background: theme.frame_bg, border: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', padding: '0 6px',
      fontFamily: cpFont, fontSize: 12, color: value ? theme.text : theme.text_dim,
      boxSizing: 'border-box',
    }}>{value || hint || ''}</div>
  );
}

// ── Checkbox — carré teal rempli quand coché ────────────────────────────────
function CPCheck({ checked, theme, size = 14 }) {
  return (
    <div style={{
      width: size, height: size, background: checked ? theme.accent : theme.frame_bg,
      border: `1px solid ${checked ? theme.accent_dim : theme.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      flexShrink: 0,
    }}>
      {checked && <div style={{ width: size - 6, height: size - 6, background: theme.accent }}></div>}
    </div>
  );
}

// ── Pill — petit bouton carré pour P/X/Y/N ──────────────────────────────────
function CPPill({ label, active, theme, color, w = 18, h = 16 }) {
  return (
    <div style={{
      width: w, height: h, background: active ? (color || theme.accent) : theme.frame_bg,
      border: `1px solid ${active ? theme.accent_dim : theme.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontFamily: cpFont, fontSize: 10, fontWeight: 'bold',
      color: active ? '#1a1a1c' : theme.text_dim,
      flexShrink: 0,
    }}>{label}</div>
  );
}

// ── Vertical separator entre colonnes ───────────────────────────────────────
function CPVSep({ theme }) {
  return <div style={{ width: 1, background: theme.separator, flexShrink: 0 }}></div>;
}

// ── Section column wrapper ──────────────────────────────────────────────────
function CPSection({ title, theme, width, collapsed, onToggle, children, draggable, extra }) {
  return (
    <div style={{
      width, flexShrink: 0, display: 'flex', flexDirection: 'column',
      background: theme.window_bg, height: '100%',
    }}>
      <CPSectionHeader label={title} collapsed={collapsed} onToggle={onToggle}
        theme={theme} draggable={draggable} extra={extra} />
      {!collapsed && (
        <div style={{ padding: 8, display: 'flex', flexDirection: 'column', gap: 5, overflow: 'hidden' }}>
          {children}
        </div>
      )}
    </div>
  );
}

Object.assign(window, {
  CPTitleBar, CPSectionHeader, CPBtn, CPSlider, CPCombo, CPInput, CPCheck,
  CPPill, CPVSep, CPSection, CPIconBtn, cpFont, cpMono,
});
