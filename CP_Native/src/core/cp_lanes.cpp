#include "cp_lanes.h"

#include <cmath>

namespace cp {

// ---------------------------------------------------------------------------
// Lane
// ---------------------------------------------------------------------------
Lane::Lane() { reset(); }

void Lane::reset() {
  // NE TOUCHE PAS a buf[] : les pointeurs appartiennent a Lanes::init, et un
  // reset qui les effacerait ferait lire le fil audio a l'adresse zero.
  port.store(-1, std::memory_order_relaxed);
  channel.store(0, std::memory_order_relaxed);
  bars.store(1.0, std::memory_order_relaxed);
  muted.store(0, std::memory_order_relaxed);
  tag.store(0.0, std::memory_order_relaxed);
  phase_off.store(0.0, std::memory_order_relaxed);
  play_from.store(-1.0, std::memory_order_relaxed);
  loop_a.store(0.0, std::memory_order_relaxed);
  loop_b.store(-1.0, std::memory_order_relaxed);   // pas d'accolade
  nbuf.store(0, std::memory_order_relaxed);
  ncount[0].store(0, std::memory_order_relaxed);
  ncount[1].store(0, std::memory_order_relaxed);
  for (int i = 0; i < 128; ++i) sounding[i] = 0;
  rec_start = 0.0;
  mode.store(kLaneEmpty, std::memory_order_relaxed);
  pending.store(kPendNone, std::memory_order_relaxed);
  pend_target.store(0.0, std::memory_order_relaxed);
  phase.store(0.0, std::memory_order_relaxed);
  len_beats.store(4.0, std::memory_order_relaxed);
  span_a.store(0.0, std::memory_order_relaxed);
  span_len.store(4.0, std::memory_order_relaxed);
  rec_gen.store(0, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Lanes
// ---------------------------------------------------------------------------
Lanes::Lanes()
    : note_store_(nullptr), freerun_(1), launch_q_(0.0), audio_run_(0), pub_beat_(0.0),
      pub_active_(0), dropped_(0), srate_(48000.0), free_beat_(0.0),
      prev_active_(0), prev_freerun_(-1), last_pb_(0.0) {}

Lanes::~Lanes() { delete[] note_store_; note_store_ = nullptr; }

void Lanes::init(double srate) {
  srate_ = (srate > 1.0) ? srate : 48000.0;
  // LA SEULE allocation de ce module, et elle a lieu ici — hors du fil audio,
  // une fois pour la vie du moteur.
  if (!note_store_) {
    note_store_ = new LaneNote[(size_t)kMaxLanes * 2 * kMaxLaneNotes];
  }
  std::memset(note_store_, 0,
              (size_t)kMaxLanes * 2 * kMaxLaneNotes * sizeof(LaneNote));
  for (int i = 0; i < kMaxLanes; ++i) {
    lanes_[i].buf[0] = note_store_ + (size_t)(i * 2 + 0) * kMaxLaneNotes;
    lanes_[i].buf[1] = note_store_ + (size_t)(i * 2 + 1) * kMaxLaneNotes;
    lanes_[i].reset();
  }
  for (int p = 0; p < kMaxPorts; ++p) pmidi_[p].count = 0;
  cmds_.clear();
  free_beat_ = 0.0;
  prev_active_ = 0;
  prev_freerun_ = -1;
  last_pb_ = 0.0;
  pub_beat_.store(0.0, std::memory_order_relaxed);
  pub_active_.store(0, std::memory_order_relaxed);
  dropped_.store(0, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Fil principal
// ---------------------------------------------------------------------------
void Lanes::publish_transport(double tempo, double beat, int playing,
                              double ts_num, frame_t at_frame, double rate) {
  // Sequence impaire = ecriture en cours. Le lecteur qui tombe dessus garde sa
  // derniere version coherente plutot que d'attendre : un bloc de retard sur le
  // tempo est sans consequence, un fil audio qui patiente ne l'est pas.
  const uint32_t s = tr_.seq.load(std::memory_order_relaxed);
  tr_.seq.store(s + 1, std::memory_order_release);
  tr_.tempo    = (tempo > 1.0) ? tempo : 120.0;
  tr_.beat     = beat;
  tr_.ts_num   = (ts_num >= 1.0) ? ts_num : 4.0;
  tr_.rate     = (rate > 0.0001) ? rate : 1.0;
  tr_.playing  = playing;
  tr_.at_frame = at_frame;
  tr_.seq.store(s + 2, std::memory_order_release);
}

bool Lanes::post(int lane, int cmd, double arg) {
  LaneCmd c;
  c.lane = lane;
  c.cmd  = cmd;
  c.arg  = arg;
  if (!cmds_.push(c)) {
    dropped_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  return true;
}

LaneNote* Lanes::write_buf(int li) {
  if (li < 0 || li >= kMaxLanes) return nullptr;
  const int cur = lanes_[li].nbuf.load(std::memory_order_relaxed);
  return lanes_[li].buf[cur ^ 1];
}

void Lanes::publish_notes(int li, int count) {
  if (li < 0 || li >= kMaxLanes) return;
  if (count < 0) count = 0;
  if (count > kMaxLaneNotes) count = kMaxLaneNotes;
  Lane& L = lanes_[li];
  const int cur  = L.nbuf.load(std::memory_order_relaxed);
  const int next = cur ^ 1;
  L.ncount[next].store(count, std::memory_order_relaxed);
  // Le compte AVANT l'indice : le fil audio ne doit jamais voir un tampon
  // publie dont le compte appartient encore a l'autre.
  L.nbuf.store(next, std::memory_order_release);
}

int Lanes::note_count(int li) const {
  if (li < 0 || li >= kMaxLanes) return 0;
  const Lane& L = lanes_[li];
  const int cur = L.nbuf.load(std::memory_order_acquire);
  return L.ncount[cur].load(std::memory_order_relaxed);
}

const LaneNote* Lanes::read_buf(int li) const {
  if (li < 0 || li >= kMaxLanes) return nullptr;
  const Lane& L = lanes_[li];
  return L.buf[L.nbuf.load(std::memory_order_acquire)];
}

// ---------------------------------------------------------------------------
// Fil audio — les outils
// ---------------------------------------------------------------------------
double Lanes::lane_len_beats(int li, double ts_num) const {
  double b = lanes_[li].bars.load(std::memory_order_relaxed);
  if (b < 0.125) b = 0.125;
  return b * ((ts_num >= 1.0) ? ts_num : 4.0);
}

// UNE ACCOLADE QUI NE TIENT PLUS DANS LA CASE NE DOIT PAS LA FAIRE TAIRE.
//
// C'est le seul cas ou cette fonction fait autre chose que recopier deux
// champs, et c'est celui qui arrive : on pose une accolade sur les mesures 3 et
// 4, puis on raccourcit la boucle a une mesure. Refuser, ou rendre une zone
// vide, rendrait la case muette sans qu'aucun geste ne l'ait demande — le pire
// des defauts, celui qu'on attribue au moteur. On RAMENE donc l'accolade dans
// la case, et si ce qu'il en reste n'est plus une duree musicale on revient a
// la case entiere.
//
// Le plancher est la double-croche : en dessous, une boucle n'est plus une
// boucle mais un bourdonnement, et une longueur nulle diviserait par zero deux
// lignes plus loin.
void Lanes::lane_span(int li, double ts_num, double* a, double* len) const {
  const double Lb = lane_len_beats(li, ts_num);
  const Lane& L = lanes_[li];
  double ba = L.loop_a.load(std::memory_order_relaxed);
  double bb = L.loop_b.load(std::memory_order_relaxed);
  if (ba < 0.0) ba = 0.0;
  if (bb > Lb)  bb = Lb;
  if (!(bb > ba + 0.25)) { *a = 0.0; *len = Lb; return; }
  *a = ba;
  *len = bb - ba;
}

// LA FENETRE DE TOLERANCE — une fraction du quantize, et pas une constante.
//
// Elle valait 0,05 beat, en dur. A 120 BPM cela fait 25 ms, et UNE MAIN HUMAINE
// EST EN RETARD DE 40 A 120 ms : le clic qui « visait » la frontiere tombait
// derriere elle et partait une mesure plus tard. Le musicien voyait sa case
// attendre alors qu'il avait joue juste — ou plutot, juste a l'echelle de ce
// qu'un doigt sait faire.
//
// Un huitieme de Q est la meme idee, exprimee dans l'unite qui compte : a
// Q: Bar et 120 BPM, 250 ms ; a Q: Beat, 62 ms ; a Q: 1/4 de beat, 15 ms. La
// tolerance suit donc la finesse demandee — serrer le quantize resserre la
// fenetre, ce qui est exactement ce qu'on veut dire en le serrant. C'est le
// « tolerant trigger sync » de FL, et la fraction est la sienne.
//
// Le plafond de 0,25 beat existe pour le cas ou quelqu'un met Q a 32 mesures :
// une fenetre de seize mesures ferait partir « tout de suite » un lancement
// qu'on voulait a la fin.
static inline double launch_tolerance(double q) {
  double t = q * 0.125;
  if (t > 0.25) t = 0.25;
  return t;
}

// OU TOMBE UN DEPART. Deux reponses, et seulement deux :
//   pas d'horloge -> kWaitClock : il en attend une. Un depart sans temps fort
//                    n'est pas un depart ; on lui donnera une vraie frontiere
//                    des qu'une horloge existera.
//   une horloge   -> la prochaine frontiere de quantize. Une position dans la
//                    fenetre de tolerance APRES une frontiere compte comme
//                    etant DESSUS, pour qu'un lancement arrive en retard
//                    appartienne encore a celle qu'il visait.
//
// Ce que cela ne fait PAS : traiter le premier bloc de l'horloge comme une
// frontiere. Le transport de REAPER demarre la ou le curseur trainait, et la
// grille de mesures existe qu'il roule ou non. Appuyer sur lecture entre deux
// mesures ne fait pas de cet instant une barre de mesure.
double Lanes::launch_target(double pb, bool active) const {
  if (!active) return kWaitClock;
  const double q = launch_q();
  if (q <= 0.001) return pb;
  const double ph = pb - std::floor(pb / q) * q;
  return (ph < launch_tolerance(q)) ? (pb - ph) : (pb - ph + q);
}

// OU TOMBE UN ARRET. La meme frontiere tant qu'une horloge tourne — un clip
// finit sa mesure — mais MAINTENANT quand il n'y en a pas : rien ne sonne,
// donc il ne reste rien a finir et attendre ne ferait qu'echouer la lane.
double Lanes::stop_target(double pb, bool active) const {
  const double q = launch_q();
  if (!active || q <= 0.001) return pb;
  const double ph = pb - std::floor(pb / q) * q;
  return (ph < launch_tolerance(q)) ? (pb - ph) : (pb - ph + q);
}

void Lanes::emit(int port, frame_t at, unsigned char s, unsigned char d1,
                 unsigned char d2) {
  if (port < 0 || port >= kMaxPorts) return;
  PortMidi& q = pmidi_[port];
  if (q.count >= kPortMidiCap) return;   // sature : on perd, on ne bloque pas
  q.at[q.count] = at;
  q.msg[q.count][0] = s;
  q.msg[q.count][1] = d1;
  q.msg[q.count][2] = d2;
  ++q.count;
}

// Relacher tout ce que cette lane tient. Le seul endroit qui coupe une note de
// lecture, pour qu'aucun chemin ne puisse en oublier une.
void Lanes::flush_lane(int li, frame_t at) {
  Lane& L = lanes_[li];
  const int port = L.port.load(std::memory_order_relaxed);
  const int ch   = L.channel.load(std::memory_order_relaxed) & 0x0F;
  for (int p = 0; p < 128; ++p) {
    if (L.sounding[p] > 0) {
      emit(port, at, (unsigned char)(0x80 + ch), (unsigned char)p, 0);
      L.sounding[p] = 0;
    }
  }
}

void Lanes::all_notes_off() {
  for (int i = 0; i < kMaxLanes; ++i) flush_lane(i, 0);
}

// ---------------------------------------------------------------------------
// Les commandes. On draine TOUT ce qui a ete ecrit depuis le dernier bloc, et
// dans l'ordre : un geste n'est jamais une commande. Echanger un clip en fait
// deux (arreter cette moitie, lancer l'autre) et une SCENE en fait une paire
// par colonne. Distillees une par bloc, elles pourraient tomber de part et
// d'autre d'une frontiere de quantize — la moitie d'une scene partant une
// mesure avant l'autre n'est pas un quantize, c'est un bug poli.
// ---------------------------------------------------------------------------
// « Elle part a CE beat, et on la veut a CETTE phase. » Le decalage est donc
// la difference, ramenee dans la boucle. Une seule ligne de calcul, mais elle
// doit vivre la ou la frontiere est CHOISIE : c'est le seul endroit du systeme
// qui connaisse `at_beat` avant que le premier echantillon ne sorte.
void Lanes::take_play_from(int li, double at_beat, double ts_num) {
  Lane& L = lanes_[li];
  const double want = L.play_from.load(std::memory_order_relaxed);
  if (want < 0.0) return;
  L.play_from.store(-1.0, std::memory_order_relaxed);
  double sa, Ls;
  lane_span(li, ts_num, &sa, &Ls);
  if (Ls <= 0.0) return;
  // `want` est en coordonnees de CASE — c'est la que Lua a clique. La phase,
  // elle, court dans l'accolade : on retire donc son debut avant de reduire.
  double off = (want - sa) - at_beat;
  off -= std::floor(off / Ls) * Ls;
  L.phase_off.store(off, std::memory_order_relaxed);
}

void Lanes::drain_cmds(double pb, bool active, double ts_num, frame_t at) {
  LaneCmd c;
  while (cmds_.pop(c)) {
    const int li = c.lane;

    if (c.cmd == kLcPanic || c.cmd == kLcClearAll) {
      for (int i = 0; i < kMaxLanes; ++i) {
        Lane& L = lanes_[i];
        if (c.cmd == kLcClearAll) {
          L.mode.store(kLaneEmpty, std::memory_order_relaxed);
        } else {
          const int m = L.mode.load(std::memory_order_relaxed);
          if (m == kLanePlaying || m == kLaneOverdub) {
            L.mode.store(kLaneStopped, std::memory_order_relaxed);
          }
        }
        L.pending.store(kPendNone, std::memory_order_relaxed);
        flush_lane(i, at);
      }
      continue;
    }

    if (li < 0 || li >= kMaxLanes) continue;
    Lane& L = lanes_[li];
    const int  m   = L.mode.load(std::memory_order_relaxed);
    const int  pnd = L.pending.load(std::memory_order_relaxed);

    switch (c.cmd) {
      case kLcRec: {
        // Renvoyer REC pendant qu'il est en file l'annule (bascule).
        if (pnd == kPendRec) { L.pending.store(kPendNone, std::memory_order_relaxed); break; }
        if (!active) {
          // Horloge arretee : rien ne peut etre capture, donc vider ici
          // detruirait la boucle existante pour rien. On ARME : les notes
          // restent, et la capture commence des que l'horloge tourne.
          L.mode.store(kLaneArmed, std::memory_order_relaxed);
          break;
        }
        const double tq = launch_target(pb, active);
        if (tq < kWaitTest || tq > pb + 0.0005) {
          L.pending.store(kPendRec, std::memory_order_relaxed);
          L.pend_target.store(tq, std::memory_order_relaxed);
        } else {
          flush_lane(li, at);
          L.rec_start = tq;
          L.mode.store(kLaneRec, std::memory_order_relaxed);
          L.rec_gen.fetch_add(1, std::memory_order_relaxed);
        }
        break;
      }

      case kLcStopRec: {
        if (pnd == kPendRec || pnd == kPendOverdub) {
          L.pending.store(kPendNone, std::memory_order_relaxed);
        }
        if (m == kLaneRec || m == kLaneOverdub) {
          const double tq = stop_target(pb, active);
          if (tq > pb + 0.0005) {
            L.pending.store(kPendStopRec, std::memory_order_relaxed);
            L.pend_target.store(tq, std::memory_order_relaxed);
          } else {
            L.mode.store(kLanePlaying, std::memory_order_relaxed);
          }
        } else if (m == kLaneArmed) {
          // annuler un armement : retomber sur ce que la lane tient deja
          L.mode.store(note_count(li) > 0 ? kLanePlaying : kLaneEmpty,
                       std::memory_order_relaxed);
        }
        break;
      }

      case kLcPlay: {
        if (pnd == kPendStop) {
          L.pending.store(kPendNone, std::memory_order_relaxed);  // garder le clip
          break;
        }
        if (m == kLaneStopped) {
          // Sans horloge ceci met en file plutot que de partir : un clip qui
          // « joue » contre un transport arrete est un clip qui ment — il ne
          // sonne rien, et il entrerait la ou le transport tombera plus tard.
          const double tq = launch_target(pb, active);
          if (tq < kWaitTest || tq > pb + 0.0005) {
            L.pending.store(kPendPlay, std::memory_order_relaxed);
            L.pend_target.store(tq, std::memory_order_relaxed);
          } else {
            take_play_from(li, pb, ts_num);
            L.mode.store(kLanePlaying, std::memory_order_relaxed);
          }
        }
        break;
      }

      case kLcStop: {
        if (pnd == kPendPlay || pnd == kPendRec || pnd == kPendOverdub) {
          L.pending.store(kPendNone, std::memory_order_relaxed);
          break;
        }
        if (m == kLanePlaying || m == kLaneOverdub) {
          const double tq = stop_target(pb, active);
          if (tq > pb + 0.0005) {
            L.pending.store(kPendStop, std::memory_order_relaxed);
            L.pend_target.store(tq, std::memory_order_relaxed);
          } else {
            L.mode.store(kLaneStopped, std::memory_order_relaxed);
            flush_lane(li, at);
          }
        }
        break;
      }

      case kLcOverdub: {
        if (pnd == kPendOverdub) { L.pending.store(kPendNone, std::memory_order_relaxed); break; }
        if (m == kLaneOverdub) {
          const double tq = stop_target(pb, active);
          if (tq > pb + 0.0005) {
            L.pending.store(kPendStopRec, std::memory_order_relaxed);
            L.pend_target.store(tq, std::memory_order_relaxed);
          } else {
            L.mode.store(kLanePlaying, std::memory_order_relaxed);
          }
        } else {
          // Entrer : NI vidage NI coupure des notes que la porte tient — une
          // lane qui joue glisse dans l'overdub sans se redeclencher. Entrer
          // est un DEPART, donc sans horloge il attend comme tout depart.
          const double tq = launch_target(pb, active);
          if (tq < kWaitTest || tq > pb + 0.0005) {
            L.pending.store(kPendOverdub, std::memory_order_relaxed);
            L.pend_target.store(tq, std::memory_order_relaxed);
          } else {
            L.mode.store(kLaneOverdub, std::memory_order_relaxed);
          }
        }
        break;
      }

      case kLcClear: {
        L.mode.store(kLaneEmpty, std::memory_order_relaxed);
        L.pending.store(kPendNone, std::memory_order_relaxed);
        flush_lane(li, at);
        break;
      }

      case kLcSetMode: {
        // Rappel de session : poser l'etat sans passer par une frontiere. Une
        // lane qu'on repose sur « arretee » ne doit rien laisser sonner.
        const int want = (int)c.arg;
        L.pending.store(kPendNone, std::memory_order_relaxed);
        if (want != kLanePlaying && want != kLaneOverdub) flush_lane(li, at);
        L.mode.store(want, std::memory_order_relaxed);
        break;
      }

      default: break;
    }
  }
}

// ---------------------------------------------------------------------------
// Les lancements en file, et l'arret automatique d'une prise apres une boucle.
// Tout ici tombe AVANT la porte, pour qu'une lane qui commence a jouer sur ce
// bloc joue des ce bloc.
// ---------------------------------------------------------------------------
void Lanes::run_pendings(double pb, bool active, double ts_num, frame_t at,
                         double block_beats) {
  if (!active) return;
  for (int li = 0; li < kMaxLanes; ++li) {
    Lane& L = lanes_[li];
    int m = L.mode.load(std::memory_order_relaxed);

    // arme -> enregistre. Avec un quantize, l'armement se convertit en une
    // prise en file a la prochaine frontiere plutot que de partir au premier
    // bloc : le transport qui roule en milieu de mesure ne fait pas de cet
    // instant une barre.
    if (m == kLaneArmed && L.pending.load(std::memory_order_relaxed) == kPendNone) {
      const double tq = launch_target(pb, active);
      if (tq > pb + 0.0005) {
        L.pending.store(kPendRec, std::memory_order_relaxed);
        L.pend_target.store(tq, std::memory_order_relaxed);
      } else {
        flush_lane(li, at);
        L.rec_start = tq;
        L.mode.store(kLaneRec, std::memory_order_relaxed);
        L.rec_gen.fetch_add(1, std::memory_order_relaxed);
        m = kLaneRec;
      }
    }

    int pnd = L.pending.load(std::memory_order_relaxed);
    if (pnd != kPendNone) {
      // Elle attendait UNE HORLOGE, et en voici une : on lui donne une vraie
      // frontiere maintenant. Pas cet instant — cet instant n'est une
      // frontiere que si le transport a demarre dessus.
      if (L.pend_target.load(std::memory_order_relaxed) < kWaitTest) {
        L.pend_target.store(launch_target(pb, active), std::memory_order_relaxed);
      }
      const double tgt = L.pend_target.load(std::memory_order_relaxed);
      // DEUX HORIZONS, ET ILS NE SONT PAS LE MEME.
      //
      // Ce qui COMMENCE se resout sur le bloc qui CONTIENT sa frontiere, pas
      // sur le premier bloc qui l'a depassee. La porte, elle, reconcilie deja
      // sur la phase de FIN de bloc : lui livrer une lane qui vient seulement
      // de passer a « joue » au bloc SUIVANT lui faisait manquer la frontiere
      // de quelques centaines d'echantillons, et la premiere note du lancement
      // sortait au debut de ce bloc-la. Mesure au harnais : 5,3 ms sur un bloc
      // de 2048, et jusqu'a un bloc entier selon ou tombe la frontiere. Avec le
      // meme horizon que la porte, elle tombe SUR son echantillon.
      //
      // Ce qui S'ARRETE garde l'ancien horizon, et ce n'est pas une omission :
      // un arret resolu sur le bloc qui contient sa frontiere couperait tout ce
      // bloc, donc jusqu'a une taille de tampon AVANT la frontiere. Un arret
      // quantifie promet exactement le contraire — le clip finit sa mesure. En
      // retard vaut mieux qu'en avance, pour lui seul.
      const bool starts = (pnd == kPendPlay || pnd == kPendRec
                           || pnd == kPendOverdub);
      const double horizon = starts ? (pb + block_beats) : pb;
      if (horizon >= tgt - 0.0005) {
        switch (pnd) {
          case kPendPlay:
            if (m == kLaneStopped) {
              // `tgt`, PAS `pb` : la frontiere est celle que le moteur a
              // choisie, et c'est contre elle que le decalage doit etre exact.
              // Contre `pb` on serait faux de la fraction de beat qui separe le
              // debut du bloc de la frontiere — audible sur une boucle courte.
              take_play_from(li, tgt, ts_num);
              L.mode.store(kLanePlaying, std::memory_order_relaxed);
            }
            break;
          case kPendStop:
            if (m == kLanePlaying || m == kLaneOverdub) {
              L.mode.store(kLaneStopped, std::memory_order_relaxed);
              flush_lane(li, at);
            }
            break;
          case kPendRec:
            flush_lane(li, at);
            L.rec_start = tgt;
            L.mode.store(kLaneRec, std::memory_order_relaxed);
            L.rec_gen.fetch_add(1, std::memory_order_relaxed);
            break;
          case kPendStopRec:
            if (m == kLaneRec || m == kLaneOverdub) {
              L.mode.store(kLanePlaying, std::memory_order_relaxed);
            }
            break;
          case kPendOverdub:
            L.mode.store(kLaneOverdub, std::memory_order_relaxed);
            break;
          default: break;
        }
        L.pending.store(kPendNone, std::memory_order_relaxed);
      }
    }

    // Une prise se ferme d'elle-meme apres une boucle entiere (le REC a un
    // clic). Un stop-rec en file devient sans objet des que la prise s'est
    // fermee toute seule.
    if (L.mode.load(std::memory_order_relaxed) == kLaneRec) {
      const double Lb = lane_len_beats(li, ts_num);
      if ((pb - L.rec_start) >= Lb) {
        L.mode.store(kLanePlaying, std::memory_order_relaxed);
        if (L.pending.load(std::memory_order_relaxed) == kPendStopRec) {
          L.pending.store(kPendNone, std::memory_order_relaxed);
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// LA PORTE. A chaque bloc on reconcilie les notes qui SONNENT contre celles qui
// couvrent la phase courante. C'est le comportement de Live, et il est bien
// choisi : une edition prend effet au bloc suivant, et il n'y a jamais de note
// bloquee — parce qu'une note tenue est tenue par cette table, pas par un
// evenement qu'on aurait pu oublier d'emettre.
//
// Ce que le portage gagne sur le JSFX : les evenements sont dates au frame
// ABSOLU dans le bloc a venir, et non poses a l'offset zero. Une note qui
// commence au tiers du bloc commence au tiers du bloc.
// ---------------------------------------------------------------------------
// Le beat absolu, au plus tot a partir de `pb`, dont la phase dans une boucle
// de longueur Lb vaut `tp`. C'est la conversion « cette note commence a telle
// place dans la boucle » -> « a quel instant, cette fois-ci ».
static inline double phase_hit(double pb, double Lb, double tp) {
  const double p0 = pb - std::floor(pb / Lb) * Lb;
  double d = tp - p0;
  if (d < 0.0) d += Lb;
  return pb + d;
}

// OU DATER UNE TRANSITION DANS LE BLOC — ET CE QU'ON FAIT D'UNE TRANSITION
// DEJA PASSEE.
//
// `phase_hit` rend le PROCHAIN instant ou la phase vaut ce qu'on cherche. En
// regime etabli il tombe dans le bloc a venir, et on date la note a
// l'echantillon : c'est tout le gain de ce moteur sur le JSFX.
//
// Mais il existe des instants ou le point est DEJA PASSE quand on le demande :
// le premier bloc d'un lancement (la lane ne jouait pas, donc rien ne l'avait
// vu passer), un saut de phase, un changement d'accolade. `phase_hit` repart
// alors une boucle ENTIERE plus loin, et borner ce resultat a la FIN du bloc
// datait la note au plus tard possible.
//
// MESURE AU HARNAIS, et c'est elle qui a designe le coupable : sur un bloc de
// 2048, la premiere note d'un lancement quantifie sortait 48 ms apres son
// temps. Le raisonnement, lui, cherchait ailleurs depuis une heure.
//
// Une transition en retard part donc au DEBUT du bloc. C'est la meme regle que
// `drain_midi` applique deja aux evenements qu'elle trouve depasses — « mieux
// vaut une note d'un bloc en retard qu'une note muette » — et ici elle vaut
// mieux vaut un bloc de retard qu'un bloc et demi.
static inline frame_t hit_frame(double d, double bpf, double block_beats,
                                frame_t at, frame_t last) {
  if (bpf <= 0.0 || !(d <= block_beats)) return at;
  const frame_t f = at + (frame_t)(d / bpf + 0.5);
  return (f < at) ? at : ((f > last) ? last : f);
}

void Lanes::run_gate(double pb, bool active, double ts_num, frame_t at,
                     int frames, double block_beats) {
  if (!active) return;
  const double bpf = (frames > 0) ? (block_beats / (double)frames) : 0.0;

  for (int li = 0; li < kMaxLanes; ++li) {
    Lane& L = lanes_[li];
    const int m = L.mode.load(std::memory_order_relaxed);
    if (m != kLanePlaying && m != kLaneOverdub) continue;
    if (L.muted.load(std::memory_order_relaxed)) { flush_lane(li, at); continue; }

    const int port = L.port.load(std::memory_order_relaxed);
    if (port < 0) continue;
    const int ch = L.channel.load(std::memory_order_relaxed) & 0x0F;

    // LA ZONE DE LECTURE REMPLACE LA LONGUEUR PARTOUT DANS CETTE BOUCLE.
    // Sans accolade elle vaut (0, longueur de la case) et pas un calcul ne
    // change : c'est ce qui rend la fonctionnalite gratuite pour les lanes qui
    // ne s'en servent pas — c'est-a-dire presque toutes, presque toujours.
    double sa, Ls;
    lane_span(li, ts_num, &sa, &Ls);

    // LA PHASE DE REFERENCE EST CELLE DE LA FIN DU BLOC, pas de son debut.
    //
    // Le JSFX lisait la phase du debut et posait tout a l'offset zero : une
    // note tombant au tiers du bloc partait au debut de celui-ci, soit jusqu'a
    // une taille de tampon trop tot. En reconciliant sur la fin du bloc, chaque
    // transition est CONTENUE dans le bloc a venir, et on peut donc la dater a
    // l'echantillon au lieu de l'arrondir a sa frontiere.
    //
    // Degenerescence : un tampon plus long que la boucle elle-meme (une boucle
    // d'un demi-temps a 1024 echantillons) sauterait des notes entieres. Dans
    // ce cas seul on revient a la phase du debut, ce qui est exactement le
    // comportement du JSFX — moins juste, jamais faux.
    const bool  fine = (block_beats < Ls * 0.5);
    const double off  = L.phase_off.load(std::memory_order_relaxed);
    const double pref = (fine ? (pb + block_beats) : pb) + off;
    // LA LIGNE DE TEMPS SUR LAQUELLE LA PHASE COURT — celle du beat du projet
    // DECALEE du decalage de la lane.
    //
    // `phase_hit` repond a « quel est le prochain beat dont la phase vaut
    // ceci ». Lui donner `pb` nu revenait a poser la question sur une ligne qui
    // n'est pas celle de la lane des qu'un « pars d'ici » etait arme : la date
    // sous-bloc de chaque note tombait alors a cote, et comme elle est bornee
    // au bloc, la note partait a son debut ou a sa fin. Une gigue d'un bloc,
    // visible seulement avec un decalage, donc jamais reproduite.
    const double pbo = pb + off;

    const int  nb  = L.nbuf.load(std::memory_order_acquire);
    const int  nev = L.ncount[nb].load(std::memory_order_relaxed);
    const LaneNote* notes = L.buf[nb];

    // Ce que la phase demande. 128 entrees sur la pile : aucune allocation, et
    // la table tient dans deux lignes de cache.
    int16_t       desire[128];
    unsigned char dvel[128];
    for (int p = 0; p < 128; ++p) { desire[p] = 0; dvel[p] = 0; }

    const double pr = pref - std::floor(pref / Ls) * Ls;
    for (int k = 0; k < nev; ++k) {
      const LaneNote& n = notes[k];
      // Une note qui COMMENCE hors de la zone de lecture est hors du clip :
      // elle reste stockee (raccourcir une boucle, ou poser une accolade, ne
      // doit jamais detruire ce qu'on a ecrit — et rouvrir ramene la musique)
      // mais elle ne sonne pas. Le repli ci-dessous n'existe que pour qu'une
      // note qui TRAVERSE la frontiere garde sa queue ; l'appliquer a un debut
      // hors bornes repliait les mesures 2, 3 et 4 sur la premiere.
      const double ns = (double)n.start - sa;
      if (ns < 0.0 || ns >= Ls) continue;
      double d = pr - ns;
      d -= std::floor(d / Ls) * Ls;
      if (d < (double)n.len) {
        const int p = n.pitch & 0x7F;
        desire[p] = (int16_t)(k + 1);
        dvel[p]   = n.vel;
      }
    }

    const frame_t last = at + (frame_t)(frames > 0 ? frames - 1 : 0);
    for (int p = 0; p < 128; ++p) {
      const int16_t des = desire[p];
      const int16_t cur = L.sounding[p];
      if (des == cur) continue;

      if (cur > 0) {
        // La coupure tombe a la FIN de la note qui sonnait — calculee, pas
        // supposee : c'est la seule facon qu'une note dure ce qu'elle dit.
        frame_t off_at = at;
        if (fine && bpf > 0.0 && cur - 1 < nev) {
          const LaneNote& o = notes[cur - 1];
          double tp = ((double)o.start - sa) + (double)o.len;
          tp -= std::floor(tp / Ls) * Ls;
          off_at = hit_frame(phase_hit(pbo, Ls, tp) - pbo, bpf, block_beats,
                             at, last);
        }
        emit(port, off_at, (unsigned char)(0x80 + ch), (unsigned char)p, 0);
      }

      if (des > 0) {
        frame_t on_at = at;
        if (fine && bpf > 0.0) {
          const double tp = (double)notes[des - 1].start - sa;
          on_at = hit_frame(phase_hit(pbo, Ls, tp) - pbo, bpf, block_beats,
                            at, last);
        }
        emit(port, on_at, (unsigned char)(0x90 + ch), (unsigned char)p, dvel[p]);
      }
      L.sounding[p] = des;
    }
  }
}

// ---------------------------------------------------------------------------
// LE BLOC
// ---------------------------------------------------------------------------
void Lanes::tick(frame_t clock, int frames) {
  if (frames <= 0) return;

  // --- l'ancre, lue sans jamais attendre -------------------------------------
  {
    const uint32_t s0 = tr_.seq.load(std::memory_order_acquire);
    if ((s0 & 1u) == 0) {
      Transport t;
      t.tempo    = tr_.tempo;
      t.beat     = tr_.beat;
      t.ts_num   = tr_.ts_num;
      t.rate     = tr_.rate;
      t.playing  = tr_.playing;
      t.at_frame = tr_.at_frame;
      const uint32_t s1 = tr_.seq.load(std::memory_order_acquire);
      if (s1 == s0) {
        tr_cache_.tempo    = t.tempo;
        tr_cache_.beat     = t.beat;
        tr_cache_.ts_num   = t.ts_num;
        tr_cache_.rate     = t.rate;
        tr_cache_.playing  = t.playing;
        tr_cache_.at_frame = t.at_frame;
      }
    }
  }

  const double tempo  = (tr_cache_.tempo > 1.0) ? tr_cache_.tempo : 120.0;
  const double ts_num = (tr_cache_.ts_num >= 1.0) ? tr_cache_.ts_num : 4.0;
  const double prate  = (tr_cache_.rate > 0.0001) ? tr_cache_.rate : 1.0;
  const bool   freerun = (freerun_.load(std::memory_order_relaxed) != 0);
  const bool   playing = (tr_cache_.playing & 1) != 0;

  // DEUX LONGUEURS DE BLOC EN BEATS, ET ELLES NE SONT PAS LA MEME.
  //
  // L'horloge LIBRE est le transport de la session : elle bat au tempo, point.
  // La vitesse de lecture de REAPER est une propriete du transport de l'HOTE,
  // et il n'y a pas d'hote quand on tourne libre.
  //
  // En suivi, au contraire, la ligne de temps du projet defile `prate` fois
  // plus vite : le meme bloc d'echantillons couvre `prate` fois plus de beats.
  // Sans cette distinction, bouger la reglette de vitesse pendant qu'une case
  // joue laissait le moteur au tempo nominal et separait les deux
  // lineairement — ce qui ne s'entend pas comme un retard mais comme un
  // decrochage qui empire.
  const double free_bb  = (double)frames * tempo / (60.0 * srate_);
  const double block_beats = freerun ? free_bb : (free_bb * prate);

  // --- LA SESSION TOURNE-T-ELLE ? --------------------------------------------
  // Une lane qui sonne ou qui capture, ou une case audio que Lua joue. SONNE,
  // et pas seulement mise en file : un lancement qui attend une horloge ne doit
  // pas etre ce qui la demarre, ou l'attente deplacerait la frontiere meme
  // qu'elle attend.
  //
  // L'horloge libre est le transport de la session, donc elle n'avance que
  // tant qu'il y a une session a laquelle donner l'heure — tenue a zero sinon.
  // C'est ce qui fait tomber le premier lancement d'une session silencieuse sur
  // le beat 0 : immediat, en phase, et c'est lui qui demarre l'horloge. Tout ce
  // qu'on lance ensuite se quantize contre ce qui joue deja, seul moment ou un
  // quantize veut dire quelque chose.
  bool sbusy = (audio_run_.load(std::memory_order_relaxed) != 0);
  if (!sbusy) {
    for (int i = 0; i < kMaxLanes && !sbusy; ++i) {
      const int m = lanes_[i].mode.load(std::memory_order_relaxed);
      if (m == kLaneRec || m == kLanePlaying || m == kLaneOverdub) sbusy = true;
    }
  }
  free_beat_ = sbusy ? (free_beat_ + free_bb) : 0.0;

  double pb;
  if (freerun) {
    pb = free_beat_;
  } else {
    // Le beat du projet, avance par le compte d'echantillons du fil audio
    // depuis l'ancre. Le fil audio ne demande jamais l'heure ; il compte.
    const frame_t d = clock - tr_cache_.at_frame;
    pb = tr_cache_.beat + (double)d * tempo * prate / (60.0 * srate_);
  }
  const bool active = freerun || playing;

  // --- changement de source d'horloge ----------------------------------------
  // pb saute d'une base de temps a l'autre. On rancre chaque debut de prise et
  // chaque cible en attente du MEME saut, pour qu'une prise en vol garde sa
  // duree ecoulee et qu'un lancement en file garde sa distance a la frontiere.
  if (prev_freerun_ >= 0 && (freerun ? 1 : 0) != prev_freerun_) {
    const double pbd = pb - last_pb_;
    for (int i = 0; i < kMaxLanes; ++i) {
      lanes_[i].rec_start += pbd;
      if (lanes_[i].pending.load(std::memory_order_relaxed) != kPendNone) {
        const double t = lanes_[i].pend_target.load(std::memory_order_relaxed);
        if (t > kWaitTest) {
          lanes_[i].pend_target.store(t + pbd, std::memory_order_relaxed);
        }
      }
    }
  }
  prev_freerun_ = freerun ? 1 : 0;
  last_pb_ = pb;

  // --- front descendant de `active` ------------------------------------------
  // Le transport s'arrete (en mode Suivre). Une prise en cours se ferme sur ce
  // qu'elle a — Lua finalisera ses notes en voyant le mode changer — et tout ce
  // qui sonne est relache pour que rien ne reste tenu en aval.
  //
  // UNE CASE QUI SONNAIT REDEVIENT UNE CASE EN FILE, PAS UNE CASE ETEINTE.
  //
  // C'etait le defaut, et il tenait a une confusion entre deux choses qui se
  // ressemblent : « ce clip est allume » et « ce clip est en train de sonner ».
  // On avait garde le mode a « joue » pour que l'etat survive a l'arret — ce qui
  // etait la bonne intention — mais un mode « joue » au retour du transport
  // repart AU BLOC SUIVANT, sans passer par la file. Le clip ne rattrapait donc
  // jamais la frontiere de quantize, et se retrouvait a jouer contre
  // l'arrangement au lieu d'avec lui.
  //
  // « En file » dit les deux a la fois : la case reste allumee (elle se dessine
  // entouree, et non pleine) et elle repartira sur une frontiere. C'est ce que
  // fait Live, et c'est ce que l'oeil attend d'un contour qui clignote.
  //
  // ET LE DECALAGE DE PHASE TOMBE AVEC L'ARRET. Il avait ete calcule contre une
  // frontiere de lancement qui n'existe plus ; le garder ferait repartir la case
  // a cote de la grille, ce qui est exactement « ca ne sonne plus avec
  // l'arrangeur ». Le document le dit deja pour la reouverture d'un projet : un
  // decalage est un geste de JEU. Un arret de transport termine ce geste.
  if (!active && prev_active_) {
    for (int i = 0; i < kMaxLanes; ++i) {
      Lane& L = lanes_[i];
      const int m = L.mode.load(std::memory_order_relaxed);
      if (m == kLaneRec || m == kLaneOverdub) {
        L.mode.store(note_count(i) > 0 ? kLanePlaying : kLaneEmpty,
                     std::memory_order_relaxed);
      }
      if (L.mode.load(std::memory_order_relaxed) == kLanePlaying) {
        L.mode.store(kLaneStopped, std::memory_order_relaxed);
        L.pending.store(kPendPlay, std::memory_order_relaxed);
        // Le sentinel « j'attends une horloge » : `run_pendings` lui donnera
        // une vraie frontiere au premier bloc ou le transport roule de nouveau.
        L.pend_target.store(kWaitClock, std::memory_order_relaxed);
      } else {
        L.pending.store(kPendNone, std::memory_order_relaxed);
      }
      L.phase_off.store(0.0, std::memory_order_relaxed);
      L.play_from.store(-1.0, std::memory_order_relaxed);
      flush_lane(i, clock);
    }
  }
  prev_active_ = active ? 1 : 0;

  drain_cmds(pb, active, ts_num, clock);
  run_pendings(pb, active, ts_num, clock, block_beats);
  run_gate(pb, active, ts_num, clock, frames, block_beats);

  // --- publier ---------------------------------------------------------------
  pub_beat_.store(pb, std::memory_order_relaxed);
  pub_active_.store(active ? 1 : 0, std::memory_order_relaxed);
  for (int i = 0; i < kMaxLanes; ++i) {
    Lane& L = lanes_[i];
    const double Lb = lane_len_beats(i, ts_num);
    // Des notes dessinees dans une lane vide la promeuvent en « arretee »,
    // donc lancable ; les effacer toutes la redescend a vide.
    const int m = L.mode.load(std::memory_order_relaxed);
    const int n = note_count(i);
    if (m == kLaneEmpty && n > 0) L.mode.store(kLaneStopped, std::memory_order_relaxed);
    else if (m == kLaneStopped && n <= 0) L.mode.store(kLaneEmpty, std::memory_order_relaxed);
    // LE MEME DECALAGE QUE LE PORTAIL, ou le son et les notes se separeraient
    // d'exactement ce qu'on vient de poser. Une seule verite, lue deux fois.
    const double po = pb + L.phase_off.load(std::memory_order_relaxed);
    double sa, Ls;
    lane_span(i, ts_num, &sa, &Ls);
    // LA PHASE EST PUBLIEE EN COORDONNEES DE CASE, accolade comprise.
    //
    // Ce que le lecteur demande, c'est OU DANS LE CLIP on se trouve : le trait
    // de lecture de l'editeur, et l'endroit ou la voix audio doit entrer dans
    // la matiere. Republier une phase ramenee a zero au debut de l'accolade
    // aurait dessine le trait au debut de la case et fait entrer le son au
    // mauvais endroit — d'exactement le decalage de l'accolade, donc de
    // quelque chose qu'on venait soi-meme de poser.
    //
    // `lenbeats` reste la longueur de la CASE : c'est le contrat que tous les
    // lecteurs ont deja, et une accolade ne raccourcit pas le clip.
    L.phase.store(active ? (sa + (po - std::floor(po / Ls) * Ls)) : 0.0,
                  std::memory_order_relaxed);
    L.len_beats.store(Lb, std::memory_order_relaxed);
    L.span_a.store(sa, std::memory_order_relaxed);
    L.span_len.store(Ls, std::memory_order_relaxed);
  }
}

int Lanes::drain_midi(int port, frame_t from, frame_t to,
                      frame_t* out_at, unsigned char (*out_msg)[3], int cap) {
  if (port < 0 || port >= kMaxPorts || cap <= 0) return 0;
  PortMidi& q = pmidi_[port];
  int out = 0, keep = 0;
  for (int i = 0; i < q.count; ++i) {
    if (q.at[i] < to && out < cap) {
      // Un evenement en retard part au debut du bloc plutot que d'etre perdu :
      // mieux vaut une note d'un bloc en retard qu'une note muette.
      out_at[out] = (q.at[i] > from) ? q.at[i] : from;
      out_msg[out][0] = q.msg[i][0];
      out_msg[out][1] = q.msg[i][1];
      out_msg[out][2] = q.msg[i][2];
      ++out;
    } else {
      q.at[keep] = q.at[i];
      q.msg[keep][0] = q.msg[i][0];
      q.msg[keep][1] = q.msg[i][1];
      q.msg[keep][2] = q.msg[i][2];
      ++keep;
    }
  }
  q.count = keep;
  return out;
}

} // namespace cp
