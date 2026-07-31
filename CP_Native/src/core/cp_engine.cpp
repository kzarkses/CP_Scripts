#include "cp_engine.h"

#include <cstring>
#include <limits>

namespace cp {

Engine::Engine()
    : alloc_cursor_(0), srate_(48000.0), clock_(0), blocks_(0), dropped_(0),
      last_tick_(0), clock_external_(false), clock_master_(-1),
      last_master_frames_(0) {
  for (int i = 0; i < kMaxVoices; ++i) {
    voices_[i].reset();
    voices_[i].gen = 1;
    claim_[i].store((claim_t)1, std::memory_order_relaxed); // gen 1, libre
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
  alloc_cursor_ = 0;
  for (int i = 0; i < kMaxVoices; ++i) {
    voices_[i].reset();
    voices_[i].gen = 1;
    claim_[i].store((claim_t)1, std::memory_order_relaxed);
  }
  for (int p = 0; p < kMaxPorts; ++p) {
    ports_[p].cmds.clear();
    ports_[p].vcount = 0;
    ports_[p].gain = ports_[p].gain_target = 1.0f;
    ports_[p].last_clock = -1;
    ports_[p].consumed = 0;
    ports_[p].used = false;
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
//
// Aucune de ces fonctions n'ecrit dans une structure Voice. Elles manipulent le
// mot de propriete — un entier atomique — et postent une commande. C'est la
// difference entre « benin sur x86 » et « correct ».
// ---------------------------------------------------------------------------

voice_h Engine::voice_alloc(int port) {
  if (port < 0 || port >= kMaxPorts) return kNullVoice;

  // Plafond par port. Ce n'est pas une politique : c'est ce qui garantit que la
  // liste du fil audio ne peut pas deborder. On compte les emplacements
  // POSSEDES, dont l'ensemble contient toujours ceux que le fil audio a deja
  // pris en charge.
  int here = 0;
  for (int i = 0; i < kMaxVoices; ++i) {
    const claim_t c = claim_[i].load(std::memory_order_relaxed);
    if (claim_owned(c) && claim_port(c) == port) ++here;
  }
  if (here >= kMaxPortVoices) return kNullVoice;

  for (int k = 0; k < kMaxVoices; ++k) {
    const int i = (alloc_cursor_ + k) & (kMaxVoices - 1);
    const claim_t cur = claim_[i].load(std::memory_order_acquire);
    if (claim_owned(cur)) continue;   // encore entre les mains du fil audio

    uint16_t gen = (uint16_t)(claim_gen(cur) + 1);
    if (gen == 0) gen = 1;            // 0 est reserve a « vierge »

    // On PREND d'abord, on demande ensuite. Dans cet ordre, un emplacement ne
    // peut jamais etre pris deux fois, meme si la commande se perd.
    claim_[i].store(make_claim(gen, port), std::memory_order_release);

    Cmd c;
    std::memset(&c, 0, sizeof(c));
    c.type = kCmdVoiceAlloc;
    c.voice = make_handle(i, gen);
    c.at = kNow;
    c.u1 = (uint32_t)port;
    if (!post(port, c)) {
      // Anneau plein : on rend l'emplacement tout de suite. Le fil audio ne l'a
      // jamais vu — il n'entre dans sa liste que par cette commande.
      claim_[i].store((claim_t)gen, std::memory_order_release);
      return kNullVoice;
    }

    ports_[port].used = true;
    alloc_cursor_ = i + 1;
    return make_handle(i, gen);
  }
  return kNullVoice;
}

bool Engine::voice_valid(voice_h h) const {
  if (h == kNullVoice) return false;
  const int i = handle_index(h);
  if (i < 0 || i >= kMaxVoices) return false;
  const claim_t c = claim_[i].load(std::memory_order_acquire);
  return claim_owned(c) && claim_gen(c) == handle_gen(h);
}

frame_t Engine::voice_started_at(voice_h h) const {
  if (!voice_valid(h)) return -1;
  return (frame_t)voices_[handle_index(h)].pub_started.load(std::memory_order_relaxed);
}

int Engine::voice_port(voice_h h) const {
  if (h == kNullVoice) return -1;
  const int i = handle_index(h);
  if (i < 0 || i >= kMaxVoices) return -1;
  const claim_t c = claim_[i].load(std::memory_order_acquire);
  if (!claim_owned(c) || claim_gen(c) != handle_gen(h)) return -1;
  return claim_port(c);
}

void Engine::voice_release(voice_h h) {
  if (!voice_valid(h)) return;
  const int i = handle_index(h);
  const claim_t cur = claim_[i].load(std::memory_order_relaxed);
  const int port = claim_port(cur);

  uint16_t ngen = (uint16_t)(claim_gen(cur) + 1);
  if (ngen == 0) ngen = 1;

  // La generation avance ICI : toute commande ulterieure portant l'ancien handle
  // est refusee des la frontiere, sans meme traverser l'anneau. Sans ca, une
  // commande envoyee sur un handle deja libere atteint la voix — bug trouve par
  // le harnais. Dans ce depot les scripts meurent et redemarrent en permanence :
  // c'est un scenario reel, pas une hypothese.
  //
  // L'emplacement reste POSSEDE. Seul le fil audio peut le rendre, et seulement
  // quand il a fini de l'eteindre : c'est ce qui interdit qu'il soit realloue
  // pendant qu'il sonne encore.
  claim_[i].store(make_claim(ngen, port), std::memory_order_release);

  Cmd c;
  std::memset(&c, 0, sizeof(c));
  c.type = kCmdVoiceFree;
  c.voice = h;             // l'ANCIEN handle : c'est celui que la voix reconnait
  c.at = kNow;
  c.u0 = (uint32_t)ngen;   // la generation a installer cote fil audio
  c.a = 0.005;             // 5 ms, pas de clic
  post(port, c);
  // Si l'anneau etait plein, l'emplacement reste possede jusqu'au prochain
  // port_reset. C'est une fuite bornee, comptee par dropped_, et jamais un son
  // qui continue par surprise.
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
  const claim_t c = claim_[i].load(std::memory_order_acquire);
  if (!claim_owned(c) || claim_gen(c) != handle_gen(h)) return false;
  if (pos_frames) *pos_frames = voices_[i].pub_pos.load(std::memory_order_relaxed);
  if (state) *state = voices_[i].pub_state.load(std::memory_order_relaxed);
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
    if (voices_[i].pub_state.load(std::memory_order_relaxed) != kVoiceIdle) ++n;
  return n;
}

int Engine::owned_voices() const {
  int n = 0;
  for (int i = 0; i < kMaxVoices; ++i)
    if (claim_owned(claim_[i].load(std::memory_order_relaxed))) ++n;
  return n;
}

int Engine::port_voices(int port) const {
  if (port < 0 || port >= kMaxPorts) return 0;
  int n = 0;
  for (int i = 0; i < kMaxVoices; ++i) {
    const claim_t c = claim_[i].load(std::memory_order_relaxed);
    if (claim_owned(c) && claim_port(c) == port) ++n;
  }
  return n;
}

// ---------------------------------------------------------------------------
// Fil audio
// ---------------------------------------------------------------------------

void Engine::tick(int frames) {
  if (frames <= 0) return;
  clock_external_ = true;
  last_tick_.store(frames, std::memory_order_relaxed);
  clock_.fetch_add((frame_t)frames, std::memory_order_acq_rel);
  blocks_.fetch_add(1, std::memory_order_acq_rel);
}

void Engine::port_reset(int port) {
  if (port < 0 || port >= kMaxPorts) return;
  PortState& ps = ports_[port];
  ps.cmds.clear();
  ps.vcount = 0;
  ps.last_clock = -1;
  ps.consumed = 0;
  ps.gain = ps.gain_target = 1.0f;
  ps.used = false;
  for (int i = 0; i < kMaxVoices; ++i) {
    const claim_t cur = claim_[i].load(std::memory_order_relaxed);
    if (!claim_owned(cur) || claim_port(cur) != port) continue;
    uint16_t g = (uint16_t)(claim_gen(cur) + 1);
    if (g == 0) g = 1;
    voices_[i].reset();
    voices_[i].gen = g;
    claim_[i].store((claim_t)g, std::memory_order_release);   // libre
  }
}

void Engine::port_attach_voice(int port, int index) {
  PortState& ps = ports_[port];
  for (int k = 0; k < ps.vcount; ++k)
    if (ps.vlist[k] == (int16_t)index) return;       // deja la
  if (ps.vcount >= kMaxPortVoices) return;           // borne dure, jamais atteinte
  ps.vlist[ps.vcount++] = (int16_t)index;
}

void Engine::apply(int port, const Cmd& c, frame_t block_start) {
  if (c.type == kCmdPanic) {
    PortState& ps = ports_[port];
    for (int k = 0; k < ps.vcount; ++k) {
      Voice& pv = voices_[ps.vlist[k]];
      if (pv.state == kVoiceIdle) continue;
      pv.state = kVoiceStopping;
      pv.stop_at = (std::numeric_limits<frame_t>::max)();
      pv.fade_out_len = (int)(0.005 * srate_);
      pv.fade_out_pos = 0;
    }
    return;
  }

  if (c.type == kCmdPortGain) {
    const int p = (int)c.u1;
    if (p >= 0 && p < kMaxPorts) ports_[p].gain_target = (float)c.a;
    return;
  }

  const int i = handle_index((voice_h)c.voice);
  if (i < 0 || i >= kMaxVoices) return;
  Voice& v = voices_[i];

  if (c.type == kCmdVoiceAlloc) {
    // La prise de possession. Rien a verifier contre l'ancienne generation :
    // le mot de propriete a deja tranche cote fil principal, et cette commande
    // EST le moment ou l'emplacement change de main. C'est aussi le seul endroit
    // ou une voix est remise a zero pendant que le moteur tourne.
    v.reset();
    v.port = port;
    v.gen = handle_gen((voice_h)c.voice);
    v.publish();
    port_attach_voice(port, i);
    return;
  }

  if (v.gen != handle_gen((voice_h)c.voice)) return; // handle perime : on ignore

  if (c.type == kCmdVoiceFree) {
    // La voix change de generation immediatement : toute commande deja en vol
    // portant l'ancien handle sera refusee juste au-dessus.
    v.gen = (uint16_t)c.u0;
    v.free_pending = true;
    v.next_voice = -1;
    if (v.state != kVoiceIdle) {
      v.state = kVoiceStopping;
      v.stop_at = (std::numeric_limits<frame_t>::max)();
      v.fade_out_len = (int)(c.a * srate_);
      v.fade_out_pos = 0;
    }
    // L'emplacement sera rendu au fil principal quand la voix sera eteinte —
    // voir la phase 3 de render_port. Jamais avant.
    return;
  }

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
        // Deplacement de la tete de lecture. Postee APRES un play, elle en
        // devient le point de depart : l'anneau est FIFO, donc l'ordre
        // d'ecriture est l'ordre d'application, dans le meme bloc.
        case kParamPos:       v.pos = (c.a > 0.0) ? c.a : 0.0; break;
        // La boucle se change A LA VOLEE : un aperçu qu'on met en boucle
        // pendant qu'il sonne ne doit pas repartir du debut.
        case kParamLoop:      v.mode = (c.a != 0.0) ? kPlayLoop : kPlayOnce; break;
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
  int guard = kCmdRingCap;
  while (guard-- > 0 && ports_[port].cmds.pop(c)) apply(port, c, block_start);
}

frame_t Engine::render_port(int port, sample_t* out, int frames, int nch) {
  if (port < 0 || port >= kMaxPorts || !out || frames <= 0 || nch < 1) return -1;
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
  //
  // On ne parcourt que les voix de CE port. Le balayage des 256 emplacements
  // qu'il y avait ici coutait, par bloc et par port, plus de cache que le rendu
  // lui-meme.
  for (int k = 0; k < ps.vcount; ++k) {
    Voice& v = voices_[ps.vlist[k]];
    if (v.state == kVoiceIdle) continue;
    v.render(pool_, out, frames, nch, block_start, srate_);
  }

  // --- phase 2 : enchainements, publication, emplacements rendus -------------
  // Une voix qui s'est eteinte DANS ce bloc donne son frame exact d'extinction a
  // sa suivante. Celle-ci n'a rien produit en phase 1 (son rendez-vous etait
  // encore dans le futur lointain), elle est donc rendue ici, une seule fois.
  // C'est ce qui rend le legato exact a l'echantillon plutot qu'au bloc — la
  // fenetre est de 1,33 ms a 64 echantillons, que Lua ne peut pas tenir.
  for (int k = 0; k < ps.vcount; ) {
    const int i = ps.vlist[k];
    Voice& v = voices_[i];

    if (v.ended_at >= 0) {
      const int ni = v.next_voice;
      v.next_voice = -1;
      const frame_t ended = v.ended_at;
      v.ended_at = -1;
      if (ni >= 0 && ni < kMaxVoices) {
        Voice& nv = voices_[ni];
        if (nv.port == port && nv.clip >= 0 && !nv.free_pending &&
            (nv.state == kVoiceScheduled || nv.state == kVoiceIdle)) {
          // xfade_len avance le depart de la suivante. Un VRAI fondu croise
          // demanderait que la sortante continue de sonner pendant le
          // recouvrement : ce n'est pas fait en v1, et c'est ecrit ici plutot
          // que sous-entendu.
          nv.start_at = ended - (frame_t)v.xfade_len;
          if (nv.start_at < block_start) nv.start_at = block_start;
          nv.state = kVoiceScheduled;
          nv.ended_at = -1;
          nv.render(pool_, out, frames, nch, block_start, srate_);
        }
      }
    }

    v.publish();

    // L'emplacement n'est rendu au fil principal QUE lorsque la voix s'est tue.
    // C'est le point qui ferme la course : tant que ce bit reste pose, aucune
    // allocation ne peut tomber sur cet emplacement.
    if (v.free_pending && v.state == kVoiceIdle) {
      v.port = -1;
      v.clip = -1;
      v.free_pending = false;
      v.publish();
      ps.vlist[k] = ps.vlist[ps.vcount - 1];
      --ps.vcount;
      claim_[i].fetch_and(~kClaimOwned, std::memory_order_release);
      continue;   // l'element deplace occupe maintenant k
    }
    ++k;
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

  return block_start;
}

} // namespace cp
