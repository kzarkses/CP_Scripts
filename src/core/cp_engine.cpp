#include "cp_engine.h"

#include <cstring>
#include <limits>

namespace cp {

Engine::Engine()
    : srate_(48000.0), clock_(0), blocks_(0), dropped_(0), clock_external_(false),
      clock_master_(-1), last_master_frames_(0) {
  for (int i = 0; i < kMaxVoices; ++i) {
    voices_[i].reset();
    voices_[i].gen = 1;
    owned_[i] = false;
  }
}

void Engine::init(double srate) {
  srate_ = (srate > 1.0) ? srate : 48000.0;
  clock_.store(0, std::memory_order_release);
  blocks_.store(0, std::memory_order_release);
  dropped_.store(0, std::memory_order_relaxed);
  clock_external_ = false;
  clock_master_ = -1;
  last_master_frames_ = 0;
  for (int p = 0; p < kMaxPorts; ++p) {
    ports_[p].cmds.clear();
    ports_[p].gain = ports_[p].gain_target = 1.0f;
    ports_[p].last_clock = -1;
    ports_[p].consumed = 0;
  }
}

void Engine::set_srate(double srate) {
  // Le taux est une ENTREE PAR BLOC, pas une constante d'initialisation : REAPER
  // peut changer de peripherique sous nos pieds. Les longueurs deja calculees en
  // frames (fondus) restent valides en frames, ce qui est le comportement
  // attendu — un fondu de 10 ms devient 10 ms au nouveau taux au prochain calcul.
  if (srate > 1.0) srate_ = srate;
}

// ---------------------------------------------------------------------------
// Fil principal
// ---------------------------------------------------------------------------

voice_h Engine::voice_alloc(int port) {
  if (port < 0 || port >= kMaxPorts) return kNullVoice;
  ports_[port].used = true;
  for (int i = 0; i < kMaxVoices; ++i) {
    if (owned_[i]) continue;
    if (voices_[i].state != kVoiceIdle) continue;
    voices_[i].reset();
    voices_[i].port = port;
    voices_[i].gen = (uint16_t)(voices_[i].gen + 1);
    if (voices_[i].gen == 0) voices_[i].gen = 1;
    owned_[i] = true;
    return make_handle(i, voices_[i].gen);
  }
  return kNullVoice;
}

bool Engine::voice_valid(voice_h h) const {
  if (h == kNullVoice) return false;
  const int i = handle_index(h);
  if (i < 0 || i >= kMaxVoices) return false;
  return owned_[i] && voices_[i].gen == handle_gen(h);
}

int Engine::voice_port(voice_h h) const {
  if (!voice_valid(h)) return -1;
  return voices_[handle_index(h)].port;
}

void Engine::voice_release(voice_h h) {
  if (!voice_valid(h)) return;
  const int i = handle_index(h);

  // La generation est incrementee ICI, pas seulement a l'allocation. Sans ca,
  // une commande envoyee sur un handle deja libere passe le controle de
  // generation et atteint la voix — bug trouve par le harnais. Dans ce depot les
  // scripts meurent et redemarrent en permanence : c'est un scenario reel, pas
  // une hypothese.
  voices_[i].gen = (uint16_t)(voices_[i].gen + 1);
  if (voices_[i].gen == 0) voices_[i].gen = 1;

  // On ne touche pas l'etat de la voix ici : le fil audio peut etre en train de
  // la rendre. On demande une extinction douce, avec le handle NEUF pour que la
  // commande soit acceptee alors que toutes les anciennes seront rejetees.
  Cmd c;
  std::memset(&c, 0, sizeof(c));
  c.type = kCmdVoiceStop;
  c.voice = make_handle(i, voices_[i].gen);
  c.at = kNow;
  c.a = 0.005; // 5 ms, pas de clic
  post(voices_[i].port, c);
  owned_[i] = false;
}

bool Engine::post(int port, const Cmd& c) {
  if (port < 0 || port >= kMaxPorts) return false;
  if (!ports_[port].cmds.push(c)) {
    dropped_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  return true;
}

bool Engine::voice_query(voice_h h, double* pos_frames, int* state) const {
  if (h == kNullVoice) return false;
  const int i = handle_index(h);
  if (i < 0 || i >= kMaxVoices) return false;
  if (voices_[i].gen != handle_gen(h)) return false;
  if (pos_frames) *pos_frames = voices_[i].pos;
  if (state) *state = voices_[i].state;
  return true;
}

void Engine::panic() {
  for (int p = 0; p < kMaxPorts; ++p) {
    if (!ports_[p].used) continue;
    Cmd c;
    std::memset(&c, 0, sizeof(c));
    c.type = kCmdPanic;
    c.at = kNow;
    post(p, c);
  }
}

int Engine::active_voices() const {
  int n = 0;
  for (int i = 0; i < kMaxVoices; ++i)
    if (voices_[i].state != kVoiceIdle) ++n;
  return n;
}

// ---------------------------------------------------------------------------
// Fil audio
// ---------------------------------------------------------------------------

void Engine::tick(int frames) {
  if (frames <= 0) return;
  clock_external_ = true;
  clock_.fetch_add((frame_t)frames, std::memory_order_acq_rel);
  blocks_.fetch_add(1, std::memory_order_acq_rel);
}

void Engine::apply(const Cmd& c, frame_t block_start) {
  const int i = handle_index((voice_h)c.voice);

  if (c.type == kCmdPanic) {
    for (int v = 0; v < kMaxVoices; ++v) {
      if (voices_[v].state == kVoiceIdle) continue;
      voices_[v].state = kVoiceStopping;
      voices_[v].fade_out_len = (int)(0.005 * srate_);
      voices_[v].fade_out_pos = 0;
    }
    return;
  }

  if (c.type == kCmdPortGain) {
    const int p = (int)c.u1;
    if (p >= 0 && p < kMaxPorts) ports_[p].gain_target = (float)c.a;
    return;
  }

  if (i < 0 || i >= kMaxVoices) return;
  Voice& v = voices_[i];
  if (v.gen != handle_gen((voice_h)c.voice)) return; // handle perime : on ignore

  const frame_t at = (c.at == kNow) ? block_start : c.at;

  switch (c.type) {
    case kCmdVoicePlay: {
      v.clip = (int)c.u0;
      v.mode = (int)c.u1;
      v.rate = (c.a > 0.0) ? c.a : 1.0;
      v.gain = v.gain_target = (float)c.b;
      v.pos = (double)v.loop_start;
      v.start_at = at;
      v.stop_at = (std::numeric_limits<frame_t>::max)();
      v.ended_at = -1;
      v.fade_in_pos = 0;
      v.fade_out_pos = 0;
      v.state = kVoiceScheduled;
      break;
    }
    case kCmdVoiceStop: {
      const int fade = (int)(c.a * srate_);
      if (c.at == kNow && fade > 0) {
        // Arret immediat en douceur.
        v.state = kVoiceStopping;
        v.fade_out_len = fade;
        v.fade_out_pos = 0;
      } else {
        // Arret DATE : c'est le cas musical (fin de boucle, frontiere de
        // mesure). Il doit tomber exactement sur le frame demande.
        v.stop_at = at;
        v.fade_out_len = fade;
      }
      break;
    }
    case kCmdVoiceSet: {
      switch (c.u0) {
        case kParamRate:      v.rate = (c.a > 0.0) ? c.a : v.rate; break;
        case kParamGain:      v.gain_target = (float)c.a; break;
        case kParamPan:       v.pan = (float)c.a; break;
        case kParamLoopStart: v.loop_start = (frame_t)c.a; break;
        case kParamLoopEnd:   v.loop_end = (frame_t)c.a; break;
        case kParamFadeIn:    v.fade_in_len = (int)(c.a * srate_); break;
        case kParamFadeOut:   v.fade_out_len = (int)(c.a * srate_); break;
        default: break;
      }
      break;
    }
    case kCmdVoiceQueue: {
      const voice_h nh = (voice_h)c.u0;
      const int ni = handle_index(nh);
      if (ni >= 0 && ni < kMaxVoices && voices_[ni].gen == handle_gen(nh)) {
        v.next_voice = ni;
        v.xfade_len = (int)(c.a * srate_);
      }
      break;
    }
    default: break;
  }
}

void Engine::drain(int port, frame_t block_start) {
  Cmd c;
  // Borne dure : on ne draine jamais indefiniment dans le fil audio. 256 par
  // bloc a 64 echantillons = 192 000 commandes/s, trois ordres de grandeur
  // au-dessus de ce qu'une interface peut produire.
  int guard = 256;
  while (guard-- > 0 && ports_[port].cmds.pop(c)) apply(c, block_start);
}

void Engine::render_port(int port, sample_t* out, int frames, int nch) {
  if (port < 0 || port >= kMaxPorts || !out || frames <= 0 || nch < 1) return;
  PortState& ps = ports_[port];
  ps.used = true;

  // --- ou sommes-nous ? -----------------------------------------------------
  // clock_ est le nombre d'echantillons DEJA delivres. Le premier echantillon
  // de ce bloc porte donc l'index clock_ + ce que ce port a deja consomme dans
  // le bloc courant. Aucun arrondi : c'est ici que se gagne l'exactitude a
  // l'echantillon, et c'est ici que le harnais l'a prise en defaut.
  if (!clock_external_) {
    // Aucun hook materiel disponible : un port fait office d'horloge. Il avance
    // l'horloge du bloc PRECEDENT, en entrant — jamais du bloc courant, sinon
    // tout part un bloc trop tot.
    if (clock_master_ < 0) clock_master_ = port;
    if (port == clock_master_) {
      if (last_master_frames_ > 0) {
        clock_.fetch_add((frame_t)last_master_frames_, std::memory_order_acq_rel);
        blocks_.fetch_add(1, std::memory_order_acq_rel);
      }
      last_master_frames_ = frames;
    }
  }
  const frame_t clk = clock_.load(std::memory_order_acquire);
  if (ps.last_clock != clk) {
    ps.last_clock = clk;
    ps.consumed = 0;
  }
  const frame_t block_start = clk + ps.consumed;
  ps.consumed += frames;

  // --- commandes ------------------------------------------------------------
  drain(port, block_start);

  // --- silence de depart ----------------------------------------------------
  std::memset(out, 0, (size_t)frames * nch * sizeof(sample_t));

  // --- phase 1 : les voix vivantes ------------------------------------------
  // Chaque voix est rendue EXACTEMENT une fois par bloc. C'est une invariante,
  // pas une convention : la rendre deux fois la fait avancer a double vitesse,
  // ce qui s'entend comme un decalage et se cherche comme un probleme d'horloge.
  for (int i = 0; i < kMaxVoices; ++i) {
    Voice& v = voices_[i];
    if (v.port != port || v.state == kVoiceIdle) continue;
    v.render(pool_, out, frames, nch, block_start, srate_);
  }

  // --- phase 2 : les enchainements ------------------------------------------
  // Une voix qui s'est eteinte DANS ce bloc donne son frame exact d'extinction a
  // sa suivante. Celle-ci n'a rien produit en phase 1 (son rendez-vous etait
  // encore dans le futur lointain), elle est donc rendue ici, une seule fois.
  // C'est ce qui rend le legato exact a l'echantillon plutot qu'au bloc — la
  // fenetre est de 1,33 ms a 64 echantillons, que Lua ne peut pas tenir.
  for (int i = 0; i < kMaxVoices; ++i) {
    Voice& v = voices_[i];
    if (v.port != port || v.ended_at < 0) continue;
    const int ni = v.next_voice;
    v.next_voice = -1;
    const frame_t ended = v.ended_at;
    v.ended_at = -1;
    if (ni < 0 || ni >= kMaxVoices) continue;

    Voice& nv = voices_[ni];
    if (nv.state != kVoiceScheduled && nv.state != kVoiceIdle) continue;
    if (nv.clip < 0) continue;

    // xfade_len avance le depart de la suivante. Un VRAI fondu croise
    // demanderait que la sortante continue de sonner pendant le recouvrement :
    // ce n'est pas fait en v1, et c'est ecrit ici plutot que sous-entendu.
    nv.start_at = ended - (frame_t)v.xfade_len;
    if (nv.start_at < block_start) nv.start_at = block_start;
    nv.state = kVoiceScheduled;
    nv.ended_at = -1;
    nv.render(pool_, out, frames, nch, block_start, srate_);
  }

  // --- gain du port ---------------------------------------------------------
  if (ps.gain != ps.gain_target || ps.gain != 1.0f) {
    float g = ps.gain;
    const float step = (ps.gain_target - ps.gain) / (float)frames;
    for (int i = 0; i < frames; ++i) {
      g += step;
      sample_t* o = out + (size_t)i * nch;
      for (int ch = 0; ch < nch; ++ch) o[ch] *= g;
    }
    ps.gain = ps.gain_target;
  }
}

} // namespace cp
