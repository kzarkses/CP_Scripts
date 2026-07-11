// CP_Toolkit-style flat widgets. Theme-driven; no hardcoded values.
const Tc = window.CP_THEME;

// Inline-style builder for hover/state — small helper since CP widgets are flat
const cx = (...arr) => arr.filter(Boolean).join(' ');

// ── Button (text or icon-only)
const Btn = ({ icon, label, tone = 'ghost', size = 'md', onClick, title, active, danger, style, children }) => {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  const h = size === 'sm' ? Tc.sizes.rowHSmall : size === 'lg' ? Tc.sizes.rowHLarge : Tc.sizes.btnH;
  const bg = active ? Tc.colors.surface2 : (hover ? Tc.colors.surface2 : (tone === 'solid' ? Tc.colors.surface : 'transparent'));
  const fg = danger ? Tc.colors.danger : (active ? Tc.colors.text : Tc.colors.textDim);
  const bd = active ? Tc.colors.border : (tone === 'solid' ? Tc.colors.border : (hover ? Tc.colors.border : 'transparent'));
  return (
    <button
      onMouseEnter={() => setHover(true)} onMouseLeave={() => { setHover(false); setPress(false); }}
      onMouseDown={() => setPress(true)} onMouseUp={() => setPress(false)}
      onClick={onClick} title={title}
      style={{
        height: h, padding: icon && !label ? 0 : `0 ${Tc.sizes.pad}px`,
        minWidth: icon && !label ? h : undefined,
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: Tc.sizes.gap,
        background: press ? Tc.colors.bg : bg, color: fg,
        border: `1px solid ${bd}`, borderRadius: Tc.sizes.radius,
        font: `${Tc.sizes.fontBase}px ${Tc.fonts.ui}`, cursor: 'pointer', userSelect: 'none',
        transition: 'background 80ms, color 80ms, border-color 80ms',
        whiteSpace: 'nowrap', flexShrink: 0, ...style,
      }}>
      {icon && <Icon name={icon} />}
      {label && <span>{label}</span>}
      {children}
    </button>
  );
};

// ── Icon-only button (alias with sensible defaults)
const IconBtn = (p) => <Btn {...p} />;

// ── Input (search etc.)
const Input = ({ value, onChange, placeholder, leftIcon, rightSlot, style }) => {
  const [focus, setFocus] = React.useState(false);
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: Tc.sizes.gap,
      height: Tc.sizes.inputH, padding: `0 ${Tc.sizes.pad}px`,
      background: Tc.colors.bg, color: Tc.colors.text,
      border: `1px solid ${focus ? Tc.colors.accentDim : Tc.colors.border}`,
      borderRadius: Tc.sizes.radius, flex: 1, minWidth: 0, ...style,
    }}>
      {leftIcon && <Icon name={leftIcon} style={{ color: Tc.colors.textDim }} />}
      <input
        value={value} onChange={(e) => onChange?.(e.target.value)}
        onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
        placeholder={placeholder}
        style={{
          flex: 1, minWidth: 0, background: 'transparent', border: 'none', outline: 'none',
          color: Tc.colors.text, font: `${Tc.sizes.fontBase}px ${Tc.fonts.ui}`,
        }}
      />
      {rightSlot}
    </div>
  );
};

// ── Pill / Chip (compact filter)
const Pill = ({ icon, label, active, onClick, count, title, tone = 'default', style }) => {
  const [hover, setHover] = React.useState(false);
  const isAccent = tone === 'accent' && active;
  return (
    <button
      onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      title={title}
      style={{
        height: Tc.sizes.chipH, padding: `0 ${Tc.sizes.pad}px`,
        display: 'inline-flex', alignItems: 'center', gap: Tc.sizes.gap,
        background: active ? (isAccent ? Tc.colors.accentDim : Tc.colors.surface2) : (hover ? Tc.colors.surface2 : Tc.colors.surface),
        color: active ? Tc.colors.text : Tc.colors.textDim,
        border: `1px solid ${active ? (isAccent ? Tc.colors.accent : Tc.colors.border) : Tc.colors.borderSoft}`,
        borderRadius: Tc.sizes.radius,
        font: `${Tc.sizes.fontSm}px ${Tc.fonts.ui}`, fontWeight: 500, letterSpacing: 0.3,
        cursor: 'pointer', userSelect: 'none', whiteSpace: 'nowrap', flexShrink: 0,
        transition: 'background 80ms, color 80ms', ...style,
      }}>
      {icon && <Icon name={icon} size={10} />}
      {label && <span>{label}</span>}
      {count !== undefined && <span style={{ color: Tc.colors.textMute, marginLeft: 2 }}>{count}</span>}
    </button>
  );
};

// ── Tab (custom user tab — looks like Pill but with close on hover)
const Tab = ({ label, active, onClick, onClose, count }) => {
  const [hover, setHover] = React.useState(false);
  return (
    <div
      onClick={onClick} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        height: Tc.sizes.chipH, padding: `0 ${hover ? 2 : Tc.sizes.pad}px 0 ${Tc.sizes.pad}px`,
        display: 'inline-flex', alignItems: 'center', gap: Tc.sizes.gap,
        background: active ? Tc.colors.surface2 : (hover ? Tc.colors.surface2 : Tc.colors.surface),
        color: active ? Tc.colors.text : Tc.colors.textDim,
        border: `1px solid ${active ? Tc.colors.border : Tc.colors.borderSoft}`,
        borderRadius: Tc.sizes.radius,
        font: `${Tc.sizes.fontSm}px ${Tc.fonts.ui}`, fontWeight: 500,
        cursor: 'pointer', userSelect: 'none', whiteSpace: 'nowrap', flexShrink: 0,
      }}>
      <span>{label}</span>
      {count !== undefined && <span style={{ color: Tc.colors.textMute }}>{count}</span>}
      {hover && (
        <span
          onClick={(e) => { e.stopPropagation(); onClose?.(); }}
          style={{ width: 14, height: 14, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', borderRadius: 2, color: Tc.colors.textMute }}
          onMouseEnter={(e) => e.currentTarget.style.color = Tc.colors.text}
          onMouseLeave={(e) => e.currentTarget.style.color = Tc.colors.textMute}>
          <Icon name="close" size={9} />
        </span>
      )}
    </div>
  );
};

// ── Checkbox (used inside ⚙ menu)
const Check = ({ label, checked, onChange }) => (
  <label
    onClick={() => onChange?.(!checked)}
    style={{
      display: 'flex', alignItems: 'center', gap: Tc.sizes.pad, height: Tc.sizes.rowH,
      padding: `0 ${Tc.sizes.pad}px`, color: Tc.colors.text,
      font: `${Tc.sizes.fontBase}px ${Tc.fonts.ui}`, cursor: 'pointer', userSelect: 'none',
    }}>
    <span style={{
      width: 12, height: 12, border: `1px solid ${Tc.colors.border}`,
      background: checked ? Tc.colors.accentDim : Tc.colors.bg,
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      borderRadius: 2, color: Tc.colors.text, flexShrink: 0,
    }}>
      {checked && <Icon name="check" size={9} />}
    </span>
    <span>{label}</span>
  </label>
);

// ── Slider (compact, monoline)
const Slider = ({ value, min = 1, max = 20, onChange, label, width = 90 }) => {
  const ref = React.useRef(null);
  const set = (e) => {
    const r = ref.current.getBoundingClientRect();
    const t = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
    onChange?.(Math.round(min + t * (max - min)));
  };
  const t = (value - min) / (max - min);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: Tc.sizes.gap, height: Tc.sizes.btnH }}>
      {label && <span style={{ color: Tc.colors.textDim, font: `${Tc.sizes.fontSm}px ${Tc.fonts.ui}`, whiteSpace: 'nowrap' }}>{label}</span>}
      <div
        ref={ref}
        onMouseDown={(e) => { set(e); const m = (ev) => set(ev); const u = () => { window.removeEventListener('mousemove', m); window.removeEventListener('mouseup', u); }; window.addEventListener('mousemove', m); window.addEventListener('mouseup', u); }}
        style={{
          width, height: 10, background: Tc.colors.bg, border: `1px solid ${Tc.colors.borderSoft}`,
          borderRadius: Tc.sizes.radius, position: 'relative', cursor: 'ew-resize', flexShrink: 0,
        }}>
        <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${t * 100}%`, background: Tc.colors.accentDim }} />
      </div>
      <span style={{ color: Tc.colors.text, font: `${Tc.sizes.fontSm}px ${Tc.fonts.mono}`, width: 16, textAlign: 'right' }}>{value}</span>
    </div>
  );
};

// ── Divider
const Sep = ({ vert, style }) => (
  <div style={{
    background: Tc.colors.borderSoft,
    width: vert ? 1 : '100%', height: vert ? '60%' : 1, alignSelf: vert ? 'center' : 'auto',
    flexShrink: 0, ...style,
  }} />
);

// ── Tooltip (CSS title-only, no JS)

window.CP = { Btn, IconBtn, Input, Pill, Tab, Check, Slider, Sep };
