#include "cp_voice.h"
#include "cp_pool.h"

#include <cmath>
#include <cstring>
#include <limits>

namespace cp {

// Seuil sous lequel un gain est force a zero. Les denormaux coutent 100 a 400
// cycles sur un Athlon 64 ou un P4 — c'est le seul piege capable a lui seul de
// rendre le moteur inutilisable sur la cible. On les tue a la source plutot que
// de poser FTZ/DAZ globalement : REAPER regle deja le MXCSR de son fil audio, et
// le modifier depuis un module charge degraderait tous les autres plugins.
static const float kDenormalFloor = 1e-15f;

void Voice::reset() {
  state = kVoiceIdle;
  port = -1;
  clip = -1;
  pos = 0.0;
  start_at = 0;
  stop_at = (std::numeric_limits<frame_t>::max)();
  mode = kPlayOnce;
  rate = 1.0;
  gain = 1.0f;
  gain_target = 1.0f;
  pan = 0.0f;
  loop_start = 0;
  loop_end = 0;
  fade_in_len = 0;
  fade_in_pos = 0;
  fade_out_len = 0;
  fade_out_pos = 0;
  next_voice = -1;
  xfade_len = 0;
  started_at = -1;
  ended_at = -1;
  free_pending = false;
  publish();
}

// Hermite 4 points. Choisi contre le lineaire (audible sur des transitoires) et
// contre un sinc 64 taps (hors budget sur la machine cible). ~10 operations par
// echantillon et par canal, sans table, sans branchement.
static inline float hermite(float xm1, float x0, float x1, float x2, float t) {
  const float c = (x1 - xm1) * 0.5f;
  const float v = x0 - x1;
  const float w = c + v;
  const float a = w + v + (x2 - x0) * 0.5f;
  const float b = w + a;
  return ((((a * t) - b) * t + c) * t + x0);
}

// ---------------------------------------------------------------------------
// POURQUOI TOUT L'ETAT MUTABLE DESCEND EN VARIABLE LOCALE
//
// `out` est un `sample_t*` et `pos` un `double` membre : rien n'interdit
// formellement au premier de pointer sur le second. Le compilateur DOIT donc
// relire et reecrire chaque membre a chaque tour de boucle — position, fondus,
// gain, etat : une dizaine d'acces memoire par echantillon, la ou il n'en faut
// aucun. Descendre l'etat en local le lui prouve, et il garde tout en registre.
// C'est la seule optimisation de ce fichier qui se voit sur la machine cible ;
// les autres sont du bruit a cote.
// ---------------------------------------------------------------------------
void Voice::render(const Pool& pool, sample_t* out, int frames, int nch,
                   frame_t block_start, double engine_srate) {
  if (state == kVoiceIdle) return;

  const Clip* c = pool.get(clip);
  if (!c || !c->data || c->frames <= 0) {
    // LA MATIERE A DISPARU SOUS LA VOIX. Un clip decharge pendant qu'on le joue
    // cesse d'etre visible du fil audio des le bloc suivant : la voix n'a plus
    // rien a lire.
    //
    // Elle DOIT mourir ici. Repartir sans rien changer la laissait vivante pour
    // toujours — plus rien ne faisait avancer son fondu, donc elle n'atteignait
    // jamais l'etat eteint, donc son emplacement n'etait jamais rendu. Une
    // fenetre qui recharge ses clips en cours de jeu aurait epuise ses voix en
    // silence, et le symptome se serait manifeste une heure plus tard sous la
    // forme « il n'y a plus de voix ».
    //
    // On ne pose PAS ended_at : l'enchainement est un comportement musical, et
    // ceci est un chemin d'erreur. Le suivant ne doit pas partir sur une
    // disparition.
    state = kVoiceIdle;
    clip = -1;
    return;
  }

  // Ou commence-t-on dans ce bloc ? C'est ici, et nulle part ailleurs, que se
  // joue l'exactitude a l'echantillon : le rendez-vous n'est pas arrondi au
  // bloc, il est converti en decalage a l'interieur du bloc.
  int off = 0;
  if (state == kVoiceScheduled) {
    if (start_at >= block_start + frames) return;       // pas encore
    off = (int)(start_at > block_start ? (start_at - block_start) : 0);
    state = kVoicePlaying;
    started_at = block_start + off;   // la verite terrain de l'attaque
    if (fade_in_len > 0) fade_in_pos = 0;
  }

  // Coupure datee, elle aussi a l'interieur du bloc.
  int n = frames;
  if (stop_at < block_start + frames) {
    const frame_t rel = stop_at - block_start;
    n = (int)(rel < 0 ? 0 : rel);
    if (n < off) n = off;
  }

  // UN ARRET DATE DEMANDAIT UN FONDU ET N'EN OBTENAIT AUCUN.
  //
  // kCmdVoiceStop pose `stop_at` et `fade_out_len` sans passer la voix en
  // kVoiceStopping — c'est le rendu qui tronque a `stop_at`, et la branche de
  // fondu ci-dessous ne s'execute donc jamais : l'arret est une coupure nette,
  // au milieu de la forme d'onde. Tant que la matiere d'une case mourait
  // d'elle-meme avant la porte, ca ne s'entendait pas. Des qu'elle boucle, ca
  // clique a chaque frontiere de passe.
  //
  // On fait donc COMMENCER le fondu assez tot pour qu'il atteigne zero
  // exactement au rendez-vous, plutot que de le declencher au rendez-vous —
  // ce qui obligerait a rendre au-dela de lui. Le fondu peut avoir commence
  // dans un bloc precedent : `fop` est alors deja avance, et l'expression le
  // dit sans avoir a s'en souvenir. Cout : une comparaison par bloc, aucune
  // par echantillon — cette boucle ne doit rien apprendre de plus.
  if (state == kVoicePlaying && fade_out_len > 0) {
    const frame_t to_stop = stop_at - block_start;
    if (to_stop <= (frame_t)fade_out_len) {
      state = kVoiceStopping;
      const frame_t done = (frame_t)fade_out_len - (to_stop > 0 ? to_stop : 0);
      fade_out_pos = (int)(done > 0 ? done : 0);
    }
  }
  if (n <= off) {
    if (stop_at <= block_start) {
      state = kVoiceIdle;
      clip = -1;
      ended_at = stop_at;
    }
    return;
  }

  const frame_t src_end   = (loop_end > 0 && loop_end <= c->frames) ? loop_end : c->frames;
  const frame_t src_start = (loop_start >= 0 && loop_start < src_end) ? loop_start : 0;
  const frame_t span      = src_end - src_start;
  const int     cnch      = c->nch;
  const sample_t* const data = c->data;

  // Balance, pas panoramique a puissance constante. Un lanceur de clips joue du
  // materiau deja mixe : au centre, il doit passer a l'identique. Une loi a
  // puissance constante mettrait -3 dB sur tout ce qui n'est pas panoramique, ce
  // qui est faux ici et rend le rendu non comparable a la source.
  const float pnorm = (pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan));
  const float gl    = (pnorm > 0.0f) ? (1.0f - pnorm) : 1.0f;
  const float gr    = (pnorm < 0.0f) ? (1.0f + pnorm) : 1.0f;

  // Le clip est stocke au taux ou il a ete decode. Si l'appareil change de taux
  // en cours de route, cette matiere ne bouge pas — c'est la LECTURE qui doit
  // s'adapter, sinon la hauteur change. Defaut trouve en changeant de taux
  // d'echantillonnage pendant que le moteur jouait : « le son reprend, mais
  // avec le pitch change ». Le taux de sortie est une entree PAR BLOC, jamais
  // une constante d'initialisation.
  const double sr_ratio = (engine_srate > 1.0 && c->srate > 1.0)
                        ? (c->srate / engine_srate) : 1.0;
  const double step  = rate * sr_ratio;
  const bool   unity = (step > 0.99999999 && step < 1.00000001);
  const bool   looping = (mode == kPlayLoop && span > 0);

  // --- l'etat mutable descend en registre ------------------------------------
  double    p   = pos;
  int       st  = state;
  int       fip = fade_in_pos;
  int       fop = fade_out_pos;
  float     g   = gain;
  const int fil = fade_in_len;
  const int fol = fade_out_len;

  // Rampe de gain sur le bloc : un saut de gain sec s'entend, et une rampe par
  // bloc coute une addition par echantillon.
  const float gstep = (n > off) ? (gain_target - g) / (float)(n - off) : 0.0f;

  frame_t ended_here = -1;   // -1 = la voix a survecu a ce bloc

  for (int i = off; i < n; ++i) {
    // --- fin de matiere ------------------------------------------------------
    if (p >= (double)src_end) {
      if (looping) {
        // Repli exact : on retire un nombre entier de spans, la phase
        // fractionnaire est preservee. C'est ce qui evite la derive d'un
        // echantillon par tour, invisible au debut et fatale au bout de dix
        // minutes.
        while (p >= (double)src_end) p -= (double)span;
      } else {
        st = kVoiceIdle;
        ended_here = block_start + i;
        break;
      }
    }

    // --- lecture interpolee --------------------------------------------------
    const frame_t i0 = (frame_t)p;
    float l, r;

    if (unity) {
      const sample_t* s = data + (size_t)i0 * cnch;
      l = s[0];
      r = (cnch > 1) ? s[1] : s[0];
    } else {
      const float t = (float)(p - (double)i0);
      frame_t im1 = i0 - 1, i1 = i0 + 1, i2 = i0 + 2;
      // Bornage par repli dans la zone de boucle : jamais de lecture hors du
      // tampon, et pas de branchement imprevisible dans la boucle chaude.
      if (im1 < src_start) im1 = looping ? src_end - 1 : src_start;
      if (i1 >= src_end)   i1  = looping ? src_start : src_end - 1;
      if (i2 >= src_end)   i2  = looping ? src_start : src_end - 1;

      const sample_t* pm1 = data + (size_t)im1 * cnch;
      const sample_t* p0  = data + (size_t)i0  * cnch;
      const sample_t* p1  = data + (size_t)i1  * cnch;
      const sample_t* p2  = data + (size_t)i2  * cnch;

      l = hermite(pm1[0], p0[0], p1[0], p2[0], t);
      r = (cnch > 1) ? hermite(pm1[1], p0[1], p1[1], p2[1], t) : l;
    }

    // --- enveloppes ----------------------------------------------------------
    float env = 1.0f;
    if (fil > 0 && fip < fil) {
      env *= (float)fip / (float)fil;
      ++fip;
    }
    if (st == kVoiceStopping) {
      if (fol > 0 && fop < fol) {
        env *= 1.0f - (float)fop / (float)fol;
        ++fop;
      } else {
        st = kVoiceIdle;
        ended_here = block_start + i;
        break;
      }
    }

    g += gstep;
    float gg = g * env;
    if (gg < kDenormalFloor && gg > -kDenormalFloor) gg = 0.0f;

    sample_t* o = out + (size_t)i * nch;
    o[0] += l * gg * gl;
    if (nch > 1) o[1] += r * gg * gr;

    p += step;
  }

  // --- l'etat remonte en memoire, une seule fois -----------------------------
  pos = p;
  fade_in_pos = fip;
  fade_out_pos = fop;
  state = st;
  gain = gain_target;
  if (ended_here >= 0) {
    clip = -1;
    ended_at = ended_here;
  }

  // Coupure nette datee : la voix s'eteint exactement au frame demande.
  if (stop_at < block_start + frames && state != kVoiceIdle && fade_out_len == 0) {
    state = kVoiceIdle;
    clip = -1;
    ended_at = stop_at;
  }
}

} // namespace cp
